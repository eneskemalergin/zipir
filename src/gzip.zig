//! Bounded gzip decompression through caller-owned readers and writers.

const std = @import("std");
const copy = @import("match.zig");
const crc = @import("crc.zig");

pub const Error = error{
    InputBufferTooSmall,
    Truncated,
    BadHeader,
    UnsupportedMethod,
    ReservedFlag,
    HeaderCrcMismatch,
    BadHuffman,
    BadSymbol,
    BadDistance,
    BadStored,
    BadBlock,
    IsizeMismatch,
    CrcMismatch,
    TrailingData,
    OutputLimitExceeded,
    ReadFailed,
    WriteFailed,
};

pub const Options = struct {
    max_output_bytes: u64 = std.math.maxInt(u64),
    trailing_data: enum { reject, leave } = .reject,
};

/// Reusable without initialization, including after errors. No allocation occurs during decode.
/// Reader, writer and workspace storage must not overlap. One active call per workspace.
pub const Decompressor = struct {
    lit_first: [1 << 11]Entry = undefined,
    dist_first: [1 << 9]Entry = undefined,
    // At widths 11/9 each occupied long prefix requires at most 16/64 entries.
    lit_spill: [288 * 16]Entry = undefined,
    dist_spill: [32 * 64]Entry = undefined,
    buffer: [RING + 131072]u8 = undefined,

    /// Reader capacity must be >=16; underlying reads may be shorter. Caller flushes writer.
    /// Output is provisional until success. Errors abort; a failed call cannot be resumed.
    pub fn decompress(self: *Decompressor, reader: *std.Io.Reader, writer: *std.Io.Writer, options: Options) Error!u64 {
        return inflate(self, reader, writer, options);
    }
};

const CLEN_ORDER = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
const LEN_EXTRA = [_]u4{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const DIST_EXTRA = [_]u4{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
const LEN_BASE = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const DIST_BASE = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };

const RING = 32768;

const Kind = enum(u4) { invalid = 0, lit, eob, len, dist, long };

const Entry = packed struct(u32) {
    nbits: u4,
    kind: Kind,
    extra: u8 = 0,
    payload: u16,
};

const FixedTables = struct {
    lit: [1 << 11]Entry,
    dist: [1 << 9]Entry,
};

const FIXED_TABLES: FixedTables = fixedTables();

fn fixedTables() FixedTables {
    @setEvalBranchQuota(100000);
    var tables: FixedTables = undefined;
    var lit_lens: [288]u4 = undefined;
    for (0..144) |i| lit_lens[i] = 8;
    for (144..256) |i| lit_lens[i] = 9;
    for (256..280) |i| lit_lens[i] = 7;
    for (280..288) |i| lit_lens[i] = 8;
    const dist_lens = [_]u4{5} ** 32;
    var no_spill: [0]Entry = .{};
    fillTwoLevel(&tables.lit, &no_spill, 11, &lit_lens, litKind, litPayload, true) catch unreachable;
    fillTwoLevel(&tables.dist, &no_spill, 9, &dist_lens, distKind, distPayload, true) catch unreachable;
    return tables;
}

const Br = struct {
    reader: *std.Io.Reader,
    src: []const u8 = &.{},
    i: usize = 0,
    bits: u64 = 0,
    nbits: u32 = 0,

    fn memcpy8Le(src: []const u8) u64 {
        var tmp: [8]u8 align(8) = undefined;
        @memcpy(&tmp, src[0..8]);
        return std.mem.readInt(u64, &tmp, .little);
    }

    fn window(self: *Br, minimum: usize) !bool {
        self.putBack();
        self.reader.toss(self.i);
        self.i = 0;
        self.src = self.reader.peekGreedy(minimum) catch |err| switch (err) {
            error.EndOfStream => self.reader.buffer[self.reader.seek..self.reader.end],
            error.ReadFailed => return error.ReadFailed,
        };
        return self.src.len >= minimum;
    }

    fn need(self: *Br, n: u32) !void {
        while (self.nbits < n) {
            if (self.i >= self.src.len) {
                _ = try self.window(8);
                if (self.nbits + self.src.len * 8 < n) return error.Truncated;
            }
            if (self.src.len - self.i >= 8 and self.nbits <= 56) {
                const room: u32 = (64 - self.nbits) / 8;
                const take: u32 = @min(room, 8);
                const w = memcpy8Le(self.src[self.i..]);
                const mask: u64 = if (take == 8)
                    ~@as(u64, 0)
                else
                    (@as(u64, 1) << @intCast(take * 8)) - 1;
                self.bits |= (w & mask) << @intCast(self.nbits);
                self.nbits += take * 8;
                self.i += take;
                continue;
            }
            var k: u8 = 0;
            while (k < 8 and self.nbits <= 56 and self.i < self.src.len) : (k += 1) {
                self.bits |= @as(u64, self.src[self.i]) << @intCast(self.nbits);
                self.nbits += 8;
                self.i += 1;
            }
        }
    }

    fn get(self: *Br, n: u32) !u32 {
        try self.need(n);
        const mask = (@as(u64, 1) << @intCast(n)) - 1;
        const v: u32 = @truncate(self.bits & mask);
        self.bits >>= @intCast(n);
        self.nbits -= n;
        return v;
    }

    fn consume(self: *Br, n: u32) void {
        self.bits >>= @intCast(n);
        self.nbits -= n;
    }

    fn alignByte(self: *Br) void {
        const drop = self.nbits % 8;
        if (drop == 0) return;
        self.bits >>= @intCast(drop);
        self.nbits -= drop;
    }

    fn putBack(self: *Br) void {
        const extra: usize = self.nbits / 8;
        std.debug.assert(extra <= self.i);
        self.i -= extra;
        self.nbits = self.nbits % 8;
        if (self.nbits == 0) {
            self.bits = 0;
        } else {
            self.bits &= (@as(u64, 1) << @intCast(self.nbits)) - 1;
        }
    }

    fn getBytes(self: *Br, n: usize) ![]const u8 {
        self.putBack();
        self.alignByte();
        if (n > self.src.len - self.i and !try self.window(n)) return error.Truncated;
        const s = self.src[self.i .. self.i + n];
        self.i += n;
        return s;
    }
};

fn bitReverse(code: u16, n: u4) u16 {
    if (n == 0) return 0;
    return @bitReverse(code) >> @intCast(16 - @as(u16, n));
}

fn buildCodes(lens: []const u4, codes: []u16, kind: enum { codes, symbols }) !void {
    var bl_count: [16]u16 = .{0} ** 16;
    for (lens) |L| {
        if (L != 0) bl_count[L] += 1;
    }
    var next_code: [16]u16 = .{0} ** 16;
    var code: u32 = 0;
    var left: i32 = 1;
    for (1..16) |Li| {
        const L: u4 = @intCast(Li);
        code = (code + bl_count[L - 1]) << 1;
        left = left * 2 - bl_count[L];
        if (left < 0) return error.BadHuffman;
        next_code[L] = @intCast(code & 0xffff);
    }
    if (left != 0) {
        var symbols: usize = 0;
        for (bl_count[1..]) |count| symbols += count;
        if (kind == .codes or (symbols != 0 and !(symbols == 1 and bl_count[1] == 1))) return error.BadHuffman;
    }
    for (lens, codes) |len, *c| {
        if (len == 0) {
            c.* = 0;
            continue;
        }
        c.* = next_code[len];
        next_code[len] +%= 1;
    }
}

fn fillFirst(table: []Entry, W: u4, lens: []const u4, kind_of: *const fn (usize) Kind, payload_of: *const fn (usize) u16, comptime predecoded: bool) !void {
    const tlen: usize = @as(usize, 1) << W;
    if (table.len != tlen) return error.BadHuffman;
    @memset(table, .{ .nbits = 0, .kind = .invalid, .payload = 0 });
    var codes: [288]u16 = undefined;
    try buildCodes(lens, codes[0..lens.len], .codes);
    const mask: u16 = @intCast(tlen - 1);
    for (lens, 0..) |len, s| {
        if (len == 0) continue;
        const rev = bitReverse(codes[s], len);
        if (len <= W) {
            var neu = Entry{
                .nbits = len,
                .kind = kind_of(s),
                .payload = payload_of(s),
            };
            if (predecoded) neu = predecode(neu);
            const step: usize = @as(usize, 1) << len;
            var i: usize = rev;
            while (i < tlen) : (i += step) {
                const old = table[i];
                if (old.kind != .invalid and (old.kind != neu.kind or old.nbits != neu.nbits or old.payload != neu.payload)) {
                    return error.BadHuffman;
                }
                table[i] = neu;
            }
        } else {
            const idx: usize = rev & mask;
            const old = table[idx];
            if (old.kind != .invalid and old.kind != .long) return error.BadHuffman;
            table[idx] = .{ .nbits = W, .kind = .long, .payload = 0 };
        }
    }
}

fn fillTwoLevel(table: []Entry, spill: []Entry, comptime W: u4, lens: []const u4, kind_of: *const fn (usize) Kind, payload_of: *const fn (usize) u16, comptime predecoded: bool) !void {
    @memset(table, .{ .nbits = 0, .kind = .invalid, .payload = 0 });
    var codes: [288]u16 = undefined;
    try buildCodes(lens, codes[0..lens.len], .symbols);
    const mask: u16 = @intCast(table.len - 1);
    for (lens, 0..) |len, symbol| {
        if (len == 0) continue;
        const rev = bitReverse(codes[symbol], len);
        if (len <= W) {
            var entry = Entry{ .nbits = len, .kind = kind_of(symbol), .payload = payload_of(symbol) };
            if (predecoded) entry = predecode(entry);
            var i: usize = rev;
            while (i < table.len) : (i += @as(usize, 1) << len) table[i] = entry;
        } else {
            const entry = &table[rev & mask];
            if (entry.kind != .invalid and entry.kind != .long) return error.BadHuffman;
            entry.* = .{ .nbits = W, .kind = .long, .extra = @max(entry.extra, len - W), .payload = 0 };
        }
    }
    var used: usize = 0;
    for (table) |*entry| {
        if (entry.kind != .long) continue;
        const size = @as(usize, 1) << @intCast(entry.extra);
        if (size > spill.len - used) return error.BadHuffman;
        entry.payload = @intCast(used);
        @memset(spill[used..][0..size], .{ .nbits = 0, .kind = .invalid, .payload = 0 });
        used += size;
    }
    for (lens, 0..) |len, symbol| {
        if (len <= W) continue;
        const rev = bitReverse(codes[symbol], len);
        const root = table[rev & mask];
        const size = @as(usize, 1) << @intCast(root.extra);
        var entry = Entry{ .nbits = len, .kind = kind_of(symbol), .payload = payload_of(symbol) };
        if (predecoded) entry = predecode(entry);
        var i: usize = rev >> W;
        while (i < size) : (i += @as(usize, 1) << (len - W)) spill[root.payload + i] = entry;
    }
}

inline fn lookupLong(root: Entry, spill: []const Entry, bits: u64, comptime W: u4) Entry {
    const mask = (@as(u64, 1) << @intCast(root.extra)) - 1;
    return spill[root.payload + @as(usize, @intCast((bits >> W) & mask))];
}

fn litKind(s: usize) Kind {
    if (s < 256) return .lit;
    if (s == 256) return .eob;
    return .len;
}

fn litPayload(s: usize) u16 {
    if (s < 256) return @intCast(s);
    if (s == 256) return 0;
    return @intCast(s - 257);
}

fn distKind(_: usize) Kind {
    return .dist;
}

fn distPayload(s: usize) u16 {
    return @intCast(s);
}

fn clenKind(_: usize) Kind {
    return .lit;
}

fn clenPayload(s: usize) u16 {
    return @intCast(s);
}

fn peekFirst(table: []const Entry, W: u4, bits: u64) Entry {
    const mask = (@as(u64, 1) << W) - 1;
    return table[@intCast(bits & mask)];
}

const Ctx = struct {
    br: *Br,
    work: *Decompressor,
    out: []u8,
    writer: *std.Io.Writer,
    out_pos: usize = RING,
    produced: u64 = 0,
    crc: u32 = 0xffffffff,
    crc_pos: usize = RING,
    member_start: u64 = 0,
    max_output_bytes: u64,

    fn position(self: *const Ctx) u64 {
        return self.produced + (self.out_pos - RING);
    }

    fn crcCatchup(self: *Ctx) void {
        if (self.crc_pos >= self.out_pos) return;
        self.crc = crc.update(self.crc, self.out[self.crc_pos..self.out_pos]);
        self.crc_pos = self.out_pos;
    }

    fn flush(self: *Ctx, comptime keep_history: bool) !void {
        const count = self.out_pos - RING;
        if (count == 0) return;
        self.crcCatchup();
        try self.writer.writeAll(self.out[RING..self.out_pos]);
        if (keep_history) {
            const history: usize = @intCast(@min(RING, self.position()));
            @memmove(self.out[RING - history .. RING], self.out[self.out_pos - history .. self.out_pos]);
        }
        self.produced += count;
        self.out_pos = RING;
        self.crc_pos = RING;
        self.out = self.work.buffer[0 .. RING + @as(usize, @intCast(@min(131072, self.max_output_bytes - self.produced)))];
        self.br.putBack();
    }

    fn room(self: *Ctx, comptime keep_history: bool) !void {
        if (self.out_pos < self.out.len) return;
        try self.flush(keep_history);
        if (self.out_pos == self.out.len) return error.OutputLimitExceeded;
    }

    fn emitByte(self: *Ctx, value: u8) !void {
        try self.room(true);
        self.out[self.out_pos] = value;
        self.out_pos += 1;
    }

    fn emitMatch(self: *Ctx, distance: usize, length: usize) !void {
        if (distance == 0 or distance > RING or distance > self.position() - self.member_start) return error.BadDistance;
        var left = length;
        while (left != 0) {
            try self.room(true);
            const n = @min(left, self.out.len - self.out_pos);
            if (distance == 1) {
                copy.dist1Broadcast32(self.out[self.out_pos..][0..n], self.out[self.out_pos - 1]);
            } else {
                copy.matchVec16(self.out, self.out_pos, distance, n);
            }
            self.out_pos += n;
            left -= n;
        }
    }

    fn emitSlice(self: *Ctx, bytes: []const u8, comptime keep_history: bool) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            try self.room(keep_history);
            const n = @min(bytes.len - off, self.out.len - self.out_pos);
            @memcpy(self.out[self.out_pos..][0..n], bytes[off..][0..n]);
            self.out_pos += n;
            off += n;
        }
    }
};

fn skipGzipHeader(br: *Br) !void {
    const header = try br.getBytes(10);
    if (header[0] != 0x1f or header[1] != 0x8b) return error.BadHeader;
    if (header[2] != 8) return error.UnsupportedMethod;
    const flags = header[3];
    if (flags & 0xe0 != 0) return error.ReservedFlag;
    var checksum = crc.update(0xffffffff, header);
    if (flags & 4 != 0) {
        const size_bytes = try br.getBytes(2);
        const size = std.mem.readInt(u16, size_bytes[0..2], .little);
        checksum = crc.update(checksum, size_bytes);
        var left: usize = size;
        while (left != 0) {
            if (br.i == br.src.len and !try br.window(1)) return error.Truncated;
            const n = @min(left, br.src.len - br.i);
            checksum = crc.update(checksum, try br.getBytes(n));
            left -= n;
        }
    }
    for ([_]u8{ 8, 16 }) |flag| {
        if (flags & flag == 0) continue;
        while (true) {
            if (br.i == br.src.len and !try br.window(1)) return error.Truncated;
            const remaining = br.src[br.i..];
            const zero = std.mem.indexOfScalar(u8, remaining, 0);
            const n = if (zero) |end| end + 1 else remaining.len;
            checksum = crc.update(checksum, try br.getBytes(n));
            if (zero != null) break;
        }
    }
    if (flags & 2 != 0) {
        const expected: u16 = @truncate(crc.finish(checksum));
        const field = try br.getBytes(2);
        if (std.mem.readInt(u16, field[0..2], .little) != expected) return error.HeaderCrcMismatch;
    }
}

fn decodeClen(br: *Br, clen_tab: []const Entry) !u8 {
    try br.need(7);
    const e = peekFirst(clen_tab, 7, br.bits);
    if (e.kind == .invalid or e.kind == .long) return error.BadHuffman;
    _ = try br.get(e.nbits);
    return @intCast(e.payload);
}

fn readDynLens(br: *Br, clen_tab: []const Entry, out: []u4) !void {
    var i: usize = 0;
    var prev: u4 = 0;
    while (i < out.len) {
        const s = try decodeClen(br, clen_tab);
        if (s <= 15) {
            const L: u4 = @intCast(s);
            out[i] = L;
            prev = L;
            i += 1;
        } else if (s == 16) {
            if (i == 0) return error.BadHuffman;
            const n = 3 + try br.get(2);
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                if (i >= out.len) return error.BadHuffman;
                out[i] = prev;
                i += 1;
            }
        } else if (s == 17) {
            prev = 0;
            const n = 3 + try br.get(3);
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                if (i >= out.len) return error.BadHuffman;
                out[i] = 0;
                i += 1;
            }
        } else if (s == 18) {
            prev = 0;
            const n = 11 + try br.get(7);
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                if (i >= out.len) return error.BadHuffman;
                out[i] = 0;
                i += 1;
            }
        } else return error.BadHuffman;
    }
}

fn predecode(entry: Entry) Entry {
    var e = entry;
    if (e.kind == .len and e.payload <= 28) {
        e.extra = LEN_EXTRA[e.payload];
        e.payload = LEN_BASE[e.payload];
    } else if (e.kind == .dist and e.payload <= 29) {
        e.extra = DIST_EXTRA[e.payload];
        e.payload = DIST_BASE[e.payload];
    } else if (e.kind == .len or e.kind == .dist) {
        e.kind = .invalid;
    }
    return e;
}

fn decodeFast(ctx: *Ctx, lit: []const Entry, dist: []const Entry) !bool {
    if (ctx.position() - ctx.member_start >= RING) return decodeFastImpl(ctx, lit, dist, true);
    return decodeFastImpl(ctx, lit, dist, false);
}

fn decodeFastImpl(ctx: *Ctx, lit: []const Entry, dist: []const Entry, comptime full_history: bool) !bool {
    const br = ctx.br;
    var bits = br.bits;
    var count = br.nbits;
    var index = br.i;
    var op = ctx.out_pos;
    const initial_op = op;
    const history = ctx.position() - ctx.member_start;
    const output = ctx.out;
    const input = br.src;
    defer {
        br.bits = bits;
        br.nbits = count;
        br.i = index;
        ctx.out_pos = op;
    }
    // A complete symbol consumes <=48 bits; wild copies require 288 owned bytes.
    while (output.len - op >= 288 and input.len - index >= 8) {
        const word = std.mem.readInt(u64, input[index..][0..8], .little);
        bits |= word << @intCast(count);
        index += 7 - (count >> 3);
        count |= 56;
        var e = lit[@intCast(bits & ((1 << 11) - 1))];
        if (e.kind == .long) e = lookupLong(e, &ctx.work.lit_spill, bits, 11);
        if (e.kind == .invalid or e.kind == .dist) return error.BadSymbol;
        bits >>= e.nbits;
        count -= e.nbits;
        if (e.kind == .eob) return true;
        if (e.kind == .lit) {
            output[op] = @truncate(e.payload);
            op += 1;
            continue;
        }
        if (e.kind != .len) return error.BadSymbol;
        const extra: u6 = @intCast(e.extra);
        const length: usize = e.payload + @as(usize, @intCast(bits & ((@as(u64, 1) << extra) - 1)));
        bits >>= extra;
        count -= extra;
        var d = dist[@intCast(bits & ((1 << 9) - 1))];
        if (d.kind == .long) d = lookupLong(d, &ctx.work.dist_spill, bits, 9);
        if (d.kind != .dist) return error.BadSymbol;
        bits >>= d.nbits;
        count -= d.nbits;
        const dx: u6 = @intCast(d.extra);
        const distance: usize = d.payload + @as(usize, @intCast(bits & ((@as(u64, 1) << dx) - 1)));
        bits >>= dx;
        count -= dx;
        if (!full_history and distance > history + (op - initial_op)) return error.BadDistance;
        if (distance >= 32) {
            var j: usize = 0;
            while (j < length) : (j += 32) {
                const chunk: @Vector(32, u8) = output[op + j - distance ..][0..32].*;
                output[op + j ..][0..32].* = chunk;
            }
        } else if (distance >= 16) {
            var j: usize = 0;
            while (j < length) : (j += 16) {
                const chunk: @Vector(16, u8) = output[op + j - distance ..][0..16].*;
                output[op + j ..][0..16].* = chunk;
            }
        } else if (distance == 1) {
            copy.dist1Broadcast32(output[op..][0..length], output[op - 1]);
        } else {
            copy.matchVec16(output, op, distance, length);
        }
        op += length;
    }
    return false;
}

fn decodeHuff(ctx: *Ctx, lit: []const Entry, dist: []const Entry) !void {
    const br = ctx.br;
    while (true) {
        if (br.src.len - br.i < 8) _ = try br.window(8);
        if (try @call(.never_inline, decodeFast, .{ ctx, lit, dist })) return;
        try br.need(15);
        var e = peekFirst(lit, 11, br.bits);
        if (e.kind == .long) e = lookupLong(e, &ctx.work.lit_spill, br.bits, 11);
        switch (e.kind) {
            .eob => {
                br.consume(e.nbits);
                return;
            },
            .lit => {
                br.consume(e.nbits);
                try ctx.emitByte(@truncate(e.payload));
            },
            .len => {
                br.consume(e.nbits);
                const add = if (e.extra != 0) try br.get(e.extra) else 0;
                const length: usize = e.payload + add;
                try br.need(15);
                var d = peekFirst(dist, 9, br.bits);
                if (d.kind == .long) d = lookupLong(d, &ctx.work.dist_spill, br.bits, 9);
                if (d.kind != .dist) return error.BadSymbol;
                br.consume(d.nbits);
                const dadd = if (d.extra != 0) try br.get(d.extra) else 0;
                try ctx.emitMatch(d.payload + @as(usize, dadd), length);
            },
            else => return error.BadSymbol,
        }
    }
}

fn inflateMember(ctx: *Ctx) !void {
    const start = ctx.position();
    ctx.member_start = start;
    ctx.crc = 0xffffffff;
    ctx.crc_pos = ctx.out_pos;
    try skipGzipHeader(ctx.br);
    var bfinal: u32 = 0;
    while (bfinal == 0) {
        bfinal = try ctx.br.get(1);
        const btype = try ctx.br.get(2);
        switch (btype) {
            0 => {
                ctx.br.alignByte();
                const len = try ctx.br.get(16);
                const nlen = try ctx.br.get(16);
                if (len != (~nlen & 0xffff)) return error.BadStored;
                var left: usize = len;
                while (left != 0) {
                    if (ctx.br.i == ctx.br.src.len and !try ctx.br.window(1)) return error.Truncated;
                    const n = @min(left, ctx.br.src.len - ctx.br.i);
                    const bytes = try ctx.br.getBytes(n);
                    if (bfinal != 0) try ctx.emitSlice(bytes, false) else try ctx.emitSlice(bytes, true);
                    left -= n;
                }
            },
            1 => try decodeHuff(ctx, &FIXED_TABLES.lit, &FIXED_TABLES.dist),
            2 => {
                const hlit = try ctx.br.get(5) + 257;
                const hdist = try ctx.br.get(5) + 1;
                const hclen = try ctx.br.get(4) + 4;
                if (hlit > 286 or hdist > 32 or hclen > 19) return error.BadHuffman;
                var clens: [19]u4 = .{0} ** 19;
                var ci: u32 = 0;
                while (ci < hclen) : (ci += 1) {
                    clens[CLEN_ORDER[ci]] = @intCast(try ctx.br.get(3));
                }
                var clen_first: [1 << 7]Entry = undefined;
                try fillFirst(clen_first[0..], 7, clens[0..19], clenKind, clenPayload, false);
                var all_lens: [318]u4 = .{0} ** 318;
                const ntot: usize = hlit + hdist;
                try readDynLens(ctx.br, clen_first[0..], all_lens[0..ntot]);
                var lit_lens: [288]u4 = .{0} ** 288;
                @memcpy(lit_lens[0..hlit], all_lens[0..hlit]);
                var dist_lens: [32]u4 = .{0} ** 32;
                @memcpy(dist_lens[0..hdist], all_lens[hlit..ntot]);
                if (lit_lens[256] == 0) return error.BadHuffman;
                try fillTwoLevel(&ctx.work.lit_first, &ctx.work.lit_spill, 11, &lit_lens, litKind, litPayload, true);
                try fillTwoLevel(&ctx.work.dist_first, &ctx.work.dist_spill, 9, &dist_lens, distKind, distPayload, true);
                try decodeHuff(ctx, &ctx.work.lit_first, &ctx.work.dist_first);
            },
            else => return error.BadBlock,
        }
    }
    ctx.crcCatchup();
    const footer = try ctx.br.getBytes(8);
    const trailer_crc = std.mem.readInt(u32, footer[0..4], .little);
    const trailer_size = std.mem.readInt(u32, footer[4..8], .little);
    const now = ctx.position();
    if (trailer_size != @as(u32, @truncate(now - start))) return error.IsizeMismatch;
    if (crc.finish(ctx.crc) != trailer_crc) return error.CrcMismatch;
}

fn inflate(work: *Decompressor, reader: *std.Io.Reader, writer: *std.Io.Writer, options: Options) Error!u64 {
    if (reader.buffer.len < 16) return error.InputBufferTooSmall;
    var br: Br = .{ .reader = reader };
    defer {
        br.putBack();
        reader.toss(br.i);
    }
    var ctx: Ctx = .{
        .br = &br,
        .work = work,
        .out = work.buffer[0 .. RING + @as(usize, @intCast(@min(131072, options.max_output_bytes)))],
        .writer = writer,
        .max_output_bytes = options.max_output_bytes,
    };
    var have_member = false;
    while (true) {
        _ = try br.window(2);
        if (br.src.len == 0 and have_member) break;
        if (br.src.len < 2 or br.src[0] != 0x1f or br.src[1] != 0x8b) {
            if (have_member) {
                if (options.trailing_data == .leave) break;
                return error.TrailingData;
            }
            if (br.src.len < 2) return error.Truncated;
            return error.BadHeader;
        }
        try inflateMember(&ctx);
        have_member = true;
        br.putBack();
        br.alignByte();
    }
    try ctx.flush(false);
    return ctx.produced;
}

test {
    _ = crc;
    _ = copy;
}

test "[edge] - [gzip]: decoded counters stop at the u64 output bound" {
    const decoder = try std.testing.allocator.create(Decompressor);
    defer std.testing.allocator.destroy(decoder);
    var reader = std.Io.Reader.fixed("");
    var br: Br = .{ .reader = &reader };
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var ctx: Ctx = .{
        .br = &br,
        .work = decoder,
        .out = decoder.buffer[0 .. RING + 1],
        .writer = &sink.writer,
        .produced = std.math.maxInt(u64) - 1,
        .member_start = std.math.maxInt(u64) - 1,
        .max_output_bytes = std.math.maxInt(u64),
    };
    try ctx.emitByte('A');
    try std.testing.expectEqual(std.math.maxInt(u64), ctx.position());
    try ctx.flush(false);
    try std.testing.expectEqual(std.math.maxInt(u64), ctx.produced);
    try std.testing.expectError(error.OutputLimitExceeded, ctx.emitByte('B'));
    try std.testing.expectEqual(@as(u64, 1), sink.fullCount());
}
