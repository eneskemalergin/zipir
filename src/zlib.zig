//! Bounded zlib decompression through caller-owned readers and writers.

const std = @import("std");
const adler32 = @import("adler32.zig");
const copy = @import("match.zig");

pub const Error = error{
    InputBufferTooSmall,
    Truncated,
    BadHeader,
    UnsupportedMethod,
    WindowTooLarge,
    DictionaryUnsupported,
    BadHuffman,
    BadSymbol,
    BadDistance,
    BadStored,
    BadBlock,
    BadAdler,
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
    lit_first: [1 << 10]Entry = undefined,
    dist_first: [1 << 9]Entry = undefined,
    // Complete residual trees need <=1536/292 entries at widths 10/9.
    lit_spill: [288 * 16]Entry = undefined,
    dist_spill: [32 * 64]Entry = undefined,
    buffer: [RING + 131072]u8 = undefined,

    /// Reader capacity must be >=16; underlying reads may be shorter. Caller flushes writer.
    /// Output is provisional until success. Errors abort; a failed call cannot be resumed.
    pub fn decompress(self: *Decompressor, reader: *std.Io.Reader, writer: *std.Io.Writer, options: Options) Error!u64 {
        return inflate(self, reader, writer, options);
    }
};

// --- Huffman codes ---

const CLEN_ORDER = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
const LEN_EXTRA = [_]u4{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const DIST_EXTRA = [_]u4{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
const LEN_BASE = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const DIST_BASE = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };

const RING = 32768;

const FIXED_LIT_LENS: [288]u4 = blk: {
    var lengths: [288]u4 = undefined;
    @memset(lengths[0..144], 8);
    @memset(lengths[144..256], 9);
    @memset(lengths[256..280], 7);
    @memset(lengths[280..288], 8);
    break :blk lengths;
};
const FIXED_DIST_LENS = [_]u4{5} ** 32;

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

const Kind = enum(u4) { invalid = 0, lit, eob, len, dist, long };

const Entry = packed struct(u32) {
    nbits: u4,
    kind: Kind,
    extra: u8 = 0,
    payload: u16,
};

const FixedTables = struct {
    lit: [1 << 10]Entry,
    dist: [1 << 9]Entry,
};

const FIXED_TABLES: FixedTables = fixedTables();

fn fixedTables() FixedTables {
    @setEvalBranchQuota(100000);
    var tables: FixedTables = undefined;
    var no_spill: [0]Entry = .{};
    fillTwoLevel(&tables.lit, &no_spill, 10, &FIXED_LIT_LENS, litKind, litPayload, true) catch unreachable;
    fillTwoLevel(&tables.dist, &no_spill, 9, &FIXED_DIST_LENS, distKind, distPayload, true) catch unreachable;
    return tables;
}

// --- Decompression ---

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
    if (@inComptime()) {
        @memset(table, .{ .nbits = 0, .kind = .invalid, .payload = 0 });
    } else {
        const bytes = std.mem.sliceAsBytes(table);
        var offset: usize = 0;
        while (bytes.len - offset >= 32) : (offset += 32) {
            // Volatile keeps LLVM from restoring the byte-loop runtime memset.
            const block: *align(1) volatile @Vector(32, u8) = @ptrCast(bytes[offset..][0..32].ptr);
            block.* = @splat(0);
        }
        @memset(bytes[offset..], 0);
    }
    var codes: [288]u16 = undefined;
    try buildCodes(lens, codes[0..lens.len], .symbols);
    const mask: u16 = @intCast(table.len - 1);
    var has_long = false;
    for (lens, 0..) |len, symbol| {
        if (len == 0) continue;
        const rev = bitReverse(codes[symbol], len);
        if (len <= W) {
            var entry = Entry{ .nbits = len, .kind = kind_of(symbol), .payload = payload_of(symbol) };
            if (predecoded) entry = predecode(entry);
            var i: usize = rev;
            while (i < table.len) : (i += @as(usize, 1) << len) table[i] = entry;
        } else {
            has_long = true;
            const entry = &table[rev & mask];
            if (entry.kind != .invalid and entry.kind != .long) return error.BadHuffman;
            entry.* = .{ .nbits = W, .kind = .long, .extra = @max(entry.extra, len - W), .payload = 0 };
        }
    }
    if (!has_long) return;
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
    adler: adler32.Stream = .init(),
    adler_pos: usize = RING,
    stream_start: u64 = 0,
    max_output_bytes: u64,

    fn position(self: *const Ctx) u64 {
        return self.produced + (self.out_pos - RING);
    }

    fn adlerCatchup(self: *Ctx) void {
        if (self.adler_pos >= self.out_pos) return;
        self.adler.update(self.out[self.adler_pos..self.out_pos]);
        self.adler_pos = self.out_pos;
    }

    fn flush(self: *Ctx, comptime keep_history: bool) !void {
        const count = self.out_pos - RING;
        if (count == 0) return;
        self.adlerCatchup();
        try self.writer.writeAll(self.out[RING..self.out_pos]);
        if (keep_history) {
            const history: usize = @intCast(@min(RING, self.position()));
            @memmove(self.out[RING - history .. RING], self.out[self.out_pos - history .. self.out_pos]);
        }
        self.produced += count;
        self.out_pos = RING;
        self.adler_pos = RING;
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
        if (distance == 0 or distance > RING or distance > self.position() - self.stream_start) return error.BadDistance;
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

fn skipZlibHeader(br: *Br) !void {
    const header = try br.getBytes(2);
    const cmf = header[0];
    const flg = header[1];
    if (cmf & 0x0f != 8) return error.UnsupportedMethod;
    if (cmf >> 4 > 7) return error.WindowTooLarge;
    if ((@as(u16, cmf) << 8 | flg) % 31 != 0) return error.BadHeader;
    if (flg & 0x20 != 0) return error.DictionaryUnsupported;
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
    if (ctx.position() - ctx.stream_start >= RING) return decodeFastImpl(ctx, lit, dist, true);
    return decodeFastImpl(ctx, lit, dist, false);
}

fn decodeFastImpl(ctx: *Ctx, lit: []const Entry, dist: []const Entry, comptime full_history: bool) !bool {
    const br = ctx.br;
    var bits = br.bits;
    var count = br.nbits;
    var index = br.i;
    var op = ctx.out_pos;
    const initial_op = op;
    const history = ctx.position() - ctx.stream_start;
    const output = ctx.out;
    const input = br.src;
    defer {
        br.bits = bits;
        br.nbits = count;
        br.i = index;
        ctx.out_pos = op;
    }
    if (output.len - op < 289 or input.len - index < 8) return false;
    const first_word = std.mem.readInt(u64, input[index..][0..8], .little);
    var e = lit[@intCast((bits | (first_word << @intCast(count))) & ((1 << 10) - 1))];
    // Eight-byte reads leave >=16 physical bits after each <=48-bit token.
    // Wild copies require 289 owned bytes; prefetched entries do not consume bits.
    while (output.len - op >= 289 and input.len - index >= 8) {
        const word = std.mem.readInt(u64, input[index..][0..8], .little);
        bits |= word << @intCast(count);
        index += 7 - (count >> 3);
        count |= 56;
        if (e.kind == .long) e = lookupLong(e, &ctx.work.lit_spill, bits, 10);
        if (e.kind == .invalid or e.kind == .dist) return error.BadSymbol;
        bits >>= e.nbits;
        count -= e.nbits;
        if (e.kind == .eob) return true;
        if (e.kind == .lit) {
            output[op] = @truncate(e.payload);
            op += 1;
            e = lit[@intCast(bits & ((1 << 10) - 1))];
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
        const next = lit[@intCast(bits & ((1 << 10) - 1))];
        if (!full_history and distance > history + (op - initial_op)) return error.BadDistance;
        if (distance >= 32) {
            var j: usize = 0;
            while (j < length) : (j += 32) {
                const chunk: @Vector(32, u8) = output[op + j - distance ..][0..32].*;
                output[op + j ..][0..32].* = chunk;
            }
        } else if (full_history or history + (op - initial_op) >= 32) {
            copy.repeatSmall(output, op, distance, length);
        } else {
            copy.matchVec16(output, op, distance, length);
        }
        op += length;
        e = next;
    }
    return false;
}

fn decodeHuff(ctx: *Ctx, lit: []const Entry, dist: []const Entry) !void {
    const br = ctx.br;
    while (true) {
        if (br.src.len - br.i < 8) {
            if (br.nbits >= 10) {
                const buffered = peekFirst(lit, 10, br.bits);
                if (buffered.kind == .eob) {
                    br.consume(buffered.nbits);
                    return;
                }
            }
            _ = try br.window(8);
        }
        if (try @call(.never_inline, decodeFast, .{ ctx, lit, dist })) return;
        try br.need(15);
        var e = peekFirst(lit, 10, br.bits);
        if (e.kind == .long) e = lookupLong(e, &ctx.work.lit_spill, br.bits, 10);
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

fn inflateStream(ctx: *Ctx) !void {
    const start = ctx.position();
    ctx.stream_start = start;
    ctx.adler = .init();
    ctx.adler_pos = ctx.out_pos;
    try skipZlibHeader(ctx.br);
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
                try fillTwoLevel(&ctx.work.lit_first, &ctx.work.lit_spill, 10, &lit_lens, litKind, litPayload, true);
                try fillTwoLevel(&ctx.work.dist_first, &ctx.work.dist_spill, 9, &dist_lens, distKind, distPayload, true);
                try decodeHuff(ctx, &ctx.work.lit_first, &ctx.work.dist_first);
            },
            else => return error.BadBlock,
        }
    }
    ctx.adlerCatchup();
    const footer = try ctx.br.getBytes(4);
    const trailer_adler = std.mem.readInt(u32, footer[0..4], .big);
    if (ctx.adler.final() != trailer_adler) return error.BadAdler;
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
    try inflateStream(&ctx);
    br.putBack();
    br.alignByte();
    if (try br.window(1)) {
        if (options.trailing_data == .reject) return error.TrailingData;
    }
    try ctx.flush(false);
    return ctx.produced;
}

test {
    _ = copy;
}

test "[property] - [zlib tables]: rejected trees clear roots without changing adjacent entries" {
    const invalid: Entry = .{ .nbits = 0, .kind = .invalid, .payload = 0 };
    const sentinel: Entry = .{ .nbits = 15, .kind = .long, .extra = 0xa5, .payload = 0x5a5a };
    inline for (.{ @as(u4, 9), @as(u4, 10), @as(u4, 11) }) |width| {
        const count = 1 << width;
        var actual: [count + 16]Entry align(32) = undefined;
        var expected: [count + 16]Entry = undefined;
        for (0..8) |offset| {
            for ([_]Entry{ invalid, sentinel }) |previous| {
                @memset(&actual, sentinel);
                const root = actual[8 + offset ..][0..count];
                @memset(root, previous);
                expected = actual;
                @memset(expected[8 + offset ..][0..count], invalid);
                var spill: [0]Entry = .{};

                try std.testing.expectError(error.BadHuffman, fillTwoLevel(root, &spill, width, &.{ 1, 1, 1 }, litKind, litPayload, true));
                try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&expected), std.mem.sliceAsBytes(&actual));
            }
        }
    }
}

test "[property] - [zlib tables]: narrower roots preserve entries and bounded spill" {
    const Tables = struct {
        fn check(comptime width: u4, lens: []const u4, seen_heights: *u16, compare_widths: bool) !void {
            const capacity = if (width == 10) 1536 else 292;
            const sentinel: Entry = .{ .nbits = 15, .kind = .long, .extra = 0xa5, .payload = 0x5a5a };
            var root: [1 << width]Entry = @splat(sentinel);
            var spill: [if (width == 10) 4608 else 2048]Entry = @splat(sentinel);
            const kind = if (width == 10) litKind else distKind;
            const payload = if (width == 10) litPayload else distPayload;
            try fillTwoLevel(&root, &spill, width, lens, kind, payload, true);
            var used: usize = 0;
            for (root) |entry| {
                if (entry.kind == .long) used = @max(used, entry.payload + (@as(usize, 1) << @intCast(entry.extra)));
            }
            try std.testing.expect(used <= capacity);
            for (spill[used..]) |entry| try std.testing.expectEqual(@as(u32, @bitCast(sentinel)), @as(u32, @bitCast(entry)));

            var leaves: [1 << width]u16 = @splat(0);
            var heights: [1 << width]u4 = @splat(0);
            var slot: usize = 0;
            var symbols: usize = 0;
            for (1..16) |depth| {
                for (lens) |len| {
                    if (len != depth) continue;
                    if (len > width) {
                        const prefix = slot >> (15 - width);
                        leaves[prefix] += 1;
                        heights[prefix] = @max(heights[prefix], len - width);
                    }
                    slot += @as(usize, 1) << @intCast(15 - depth);
                    symbols += 1;
                }
            }
            var modeled: usize = 0;
            for (heights, leaves) |height, leaf_count| {
                if (height == 0) continue;
                seen_heights.* |= @as(u16, 1) << height;
                const slots = @as(usize, 1) << height;
                try std.testing.expect(leaf_count >= @as(usize, height) + 1);
                try std.testing.expect(slots * (16 - @as(usize, width)) <= @as(usize, leaf_count) * (@as(usize, 1) << (15 - width)));
                modeled += slots;
            }
            try std.testing.expectEqual(used, modeled);
            if (symbols > 1) try std.testing.expectEqual(@as(usize, 32768), slot);

            if (compare_widths) {
                var canonical: [32768]u16 = @splat(65535);
                var start: usize = 0;
                for (1..16) |depth| {
                    for (lens, 0..) |len, symbol| {
                        if (len != depth) continue;
                        const count = @as(usize, 1) << @intCast(15 - depth);
                        @memset(canonical[start..][0..count], @intCast(symbol));
                        start += count;
                    }
                }
                for (0..32768) |bits| {
                    const symbol = canonical[@bitReverse(@as(u16, @intCast(bits))) >> 1];
                    var expected: Entry = .{ .nbits = 0, .kind = .invalid, .payload = 0 };
                    if (symbol != 65535) {
                        expected.nbits = lens[symbol];
                        if (width == 9) {
                            expected.kind = if (symbol < 30) .dist else .invalid;
                            expected.payload = if (symbol < 30) DIST_BASE[symbol] else symbol;
                            expected.extra = if (symbol < 30) DIST_EXTRA[symbol] else 0;
                        } else if (symbol < 256) {
                            expected.kind = .lit;
                            expected.payload = symbol;
                        } else if (symbol == 256) {
                            expected.kind = .eob;
                        } else {
                            expected.kind = if (symbol <= 285) .len else .invalid;
                            expected.payload = if (symbol <= 285) LEN_BASE[symbol - 257] else symbol - 257;
                            expected.extra = if (symbol <= 285) LEN_EXTRA[symbol - 257] else 0;
                        }
                    }
                    var actual = root[bits & (root.len - 1)];
                    if (actual.kind == .long) actual = lookupLong(actual, &spill, bits, width);
                    try std.testing.expectEqual(@as(u32, @bitCast(expected)), @as(u32, @bitCast(actual)));
                }
            }

            if (width == 10 and compare_widths) {
                var original_root: [1 << 11]Entry = undefined;
                var original_spill: [4608]Entry = undefined;
                try fillTwoLevel(&original_root, &original_spill, 11, lens, litKind, litPayload, true);
                for (0..32768) |bits| {
                    var original = original_root[bits & 2047];
                    if (original.kind == .long) original = lookupLong(original, &original_spill, bits, 11);
                    var narrowed = root[bits & 1023];
                    if (narrowed.kind == .long) narrowed = lookupLong(narrowed, &spill, bits, 10);
                    try std.testing.expectEqual(@as(u32, @bitCast(original)), @as(u32, @bitCast(narrowed)));
                }
            }
            if (compare_widths) {
                if (used != 0) try std.testing.expectError(error.BadHuffman, fillTwoLevel(&root, spill[0 .. used - 1], width, lens, kind, payload, true));
                const previous_spill = spill;
                var short_lens: [if (width == 10) 288 else 32]u4 = @splat(0);
                for (0..2) |single| {
                    short_lens[0] = @intCast(single);
                    try fillTwoLevel(&root, &spill, width, &short_lens, kind, payload, true);
                    for (root, 0..) |entry, prefix| {
                        const expected: Entry = if (single != 0 and prefix & 1 == 0)
                            .{ .nbits = 1, .kind = if (width == 10) .lit else .dist, .payload = if (width == 10) 0 else 1 }
                        else
                            .{ .nbits = 0, .kind = .invalid, .payload = 0 };
                        try std.testing.expectEqual(@as(u32, @bitCast(expected)), @as(u32, @bitCast(entry)));
                    }
                    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&previous_spill), std.mem.sliceAsBytes(&spill));
                }
            }
        }
    };

    inline for (.{ @as(u4, 10), @as(u4, 9) }) |width| {
        const alphabet = if (width == 10) 288 else 32;
        var lens: [alphabet]u4 = @splat(0);
        var seen_heights: u16 = 0;
        try Tables.check(width, &lens, &seen_heights, true);
        lens[alphabet - 1] = 1;
        try Tables.check(width, &lens, &seen_heights, true);
        for (0..32) |trial| {
            @memset(&lens, 0);
            var random = std.Random.DefaultPrng.init(0x513 + trial);
            var count: usize = 1;
            while (count < alphabet) {
                var selected: usize = 0;
                if (trial < 2) {
                    for (lens[0..count], 0..) |len, i| {
                        if (len == 15) continue;
                        if (lens[selected] == 15 or (trial == 0 and len > lens[selected]) or (trial == 1 and len < lens[selected])) selected = i;
                    }
                } else {
                    selected = random.random().uintLessThan(usize, count);
                    while (lens[selected] == 15) selected = (selected + 1) % count;
                }
                try std.testing.expect(lens[selected] < 15);
                lens[selected] += 1;
                lens[count] = lens[selected];
                count += 1;
                if (count <= 17 or count % 16 == 0 or count == alphabet) try Tables.check(width, &lens, &seen_heights, count == alphabet);
            }
        }
        try std.testing.expectEqual((@as(u16, 1) << @as(u4, 16 - @as(u5, width))) - 2, seen_heights);
    }
}

test "[edge] - [zlib]: decoded counters stop at the u64 output bound" {
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
        .stream_start = std.math.maxInt(u64) - 1,
        .max_output_bytes = std.math.maxInt(u64),
    };
    try ctx.emitByte('A');
    try std.testing.expectEqual(std.math.maxInt(u64), ctx.position());
    try ctx.flush(false);
    try std.testing.expectEqual(std.math.maxInt(u64), ctx.produced);
    try std.testing.expectError(error.OutputLimitExceeded, ctx.emitByte('B'));
    try std.testing.expectEqual(@as(u64, 1), sink.fullCount());
}

test "[property] - [zlib]: fast literals consume exact bits within output room" {
    const decoder = try std.testing.allocator.create(Decompressor);
    defer std.testing.allocator.destroy(decoder);
    try std.testing.expectEqual(@as(usize, 196608), @sizeOf(Decompressor));
    var sink: std.Io.Writer.Discarding = .init(&.{});
    for (0..65) |length| {
        var input: [128]u8 = @splat(0);
        var plain: [64]u8 = undefined;
        var ends: [66]usize = undefined;
        ends[0] = 0;
        var position: usize = 0;
        for (0..length + 1) |i| {
            const symbol: u16 = if (i == length) 256 else @as(u8, @truncate(i * 37));
            if (i < length) plain[i] = @intCast(symbol);
            const width: usize = if (symbol == 256) 7 else if (symbol < 144) 8 else 9;
            const code: u16 = if (symbol == 256) 0 else if (symbol < 144) 0x30 + symbol else 0x190 + symbol - 144;
            for (0..width) |j| {
                const bit: u8 = @intCast((code >> @intCast(width - 1 - j)) & 1);
                input[position / 8] |= bit << @intCast(position % 8);
                position += 1;
            }
            ends[i + 1] = position;
        }
        for ([_]usize{ 0, 1, 2, 287, 288, 289, 290, 291, 320, 353 }) |room| {
            @memset(decoder.buffer[RING..][0..384], 0xa5);
            var reader = std.Io.Reader.fixed(&input);
            var br: Br = .{ .reader = &reader, .src = &input };
            var ctx: Ctx = .{
                .br = &br,
                .work = decoder,
                .out = decoder.buffer[0 .. RING + room],
                .writer = &sink.writer,
                .max_output_bytes = std.math.maxInt(u64),
            };
            const ended = try decodeFastImpl(&ctx, &FIXED_TABLES.lit, &FIXED_TABLES.dist, false);
            const written = ctx.out_pos - RING;
            try std.testing.expect(written <= length and written <= room);
            if (ended) try std.testing.expectEqual(length, written);
            try std.testing.expectEqual(ends[if (ended) length + 1 else written], br.i * 8 - br.nbits);
            try std.testing.expectEqualSlices(u8, plain[0..written], decoder.buffer[RING..][0..written]);
            for (decoder.buffer[ctx.out_pos .. RING + 384]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
        }
    }
}

test "[edge] - [zlib]: lookahead retains unread bits after a maximum-width match" {
    const decoder = try std.testing.allocator.create(Decompressor);
    defer std.testing.allocator.destroy(decoder);
    const invalid: Entry = .{ .nbits = 0, .kind = .invalid, .payload = 0 };
    @memset(&decoder.lit_first, invalid);
    @memset(&decoder.dist_first, invalid);
    @memset(&decoder.lit_spill, invalid);
    @memset(&decoder.dist_spill, invalid);
    decoder.lit_first[0] = .{ .nbits = 10, .kind = .long, .extra = 5, .payload = 0 };
    decoder.lit_spill[0] = .{ .nbits = 15, .kind = .len, .extra = 5, .payload = 227 };
    decoder.dist_first[0] = .{ .nbits = 9, .kind = .long, .extra = 6, .payload = 0 };
    decoder.dist_spill[0] = .{ .nbits = 15, .kind = .dist, .extra = 13, .payload = 24577 };
    decoder.lit_first[1] = .{ .nbits = 1, .kind = .eob, .payload = 0 };
    for (decoder.buffer[0..RING], 0..) |*byte, i| byte.* = @truncate(i * 73 + i / 256);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    for ([_]u4{ 10, 11 }) |literal_width| {
        const literal: Entry = .{ .nbits = literal_width, .kind = .lit, .payload = 'A' };
        decoder.lit_first[512] = if (literal_width == 10) literal else .{ .nbits = 10, .kind = .long, .extra = 1, .payload = 32 };
        decoder.lit_spill[33] = literal;
        const literal_code: u64 = if (literal_width == 10) 512 else 1536;
        const consumed: usize = 48 + @as(usize, literal_width) + 1;
        var input: [32]u8 = @splat(0);
        const token_bits: u64 = (@as(u64, 31) << 15) | (@as(u64, 8191) << 35);
        std.mem.writeInt(u64, input[0..8], token_bits | (literal_code << 48) | (@as(u64, 1) << @intCast(consumed - 1)), .little);
        var reader = std.Io.Reader.fixed(&input);
        var br: Br = .{ .reader = &reader, .src = &input };
        var ctx: Ctx = .{
            .br = &br,
            .work = decoder,
            .out = &decoder.buffer,
            .writer = &sink.writer,
            .produced = RING,
            .max_output_bytes = std.math.maxInt(u64),
        };
        try std.testing.expect(try decodeFastImpl(&ctx, &decoder.lit_first, &decoder.dist_first, true));
        try std.testing.expectEqual(RING + 259, ctx.out_pos);
        try std.testing.expectEqual(consumed, br.i * 8 - br.nbits);
        try std.testing.expectEqualSlices(u8, decoder.buffer[0..258], decoder.buffer[RING..][0..258]);
        try std.testing.expectEqual(@as(u8, 'A'), decoder.buffer[RING + 258]);
    }
}
