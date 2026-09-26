//! Raw DEFLATE (RFC 1951) engine shared by the containers: bit reader, Huffman tables, a streaming
//! decoder through a bounded history-plus-batch buffer, and the block encoder.

const std = @import("std");
const copy = @import("../kernel/copy.zig");

pub const Error = error{ Truncated, BadHuffman, BadSymbol, BadDistance, BadStored, BadBlock, OutputLimitExceeded, ReadFailed, WriteFailed };

pub const TrailingData = enum { reject, leave };

pub const DecompressOptions = struct {
    max_output_bytes: u64 = std.math.maxInt(u64),
    trailing_data: TrailingData = .reject,
};

pub const Limits = struct {
    max_output_bytes: u64 = std.math.maxInt(u64),
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
    for (lens) |code_len| {
        if (code_len != 0) bl_count[code_len] += 1;
    }
    var next_code: [16]u16 = .{0} ** 16;
    var code: u32 = 0;
    var left: i32 = 1;
    for (1..16) |bit_len| {
        const code_len: u4 = @intCast(bit_len);
        code = (code + bl_count[code_len - 1]) << 1;
        left = left * 2 - bl_count[code_len];
        if (left < 0) return error.BadHuffman;
        next_code[code_len] = @intCast(code & 0xffff);
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
    fillTwoLevel(&tables.lit, &no_spill, 10, &FIXED_LIT_LENS, litKind, litPayload, true) catch |err| @compileError(@errorName(err));
    fillTwoLevel(&tables.dist, &no_spill, 9, &FIXED_DIST_LENS, distKind, distPayload, true) catch |err| @compileError(@errorName(err));
    return tables;
}

// --- Bit reader ---

pub const BitReader = struct {
    reader: *std.Io.Reader,
    src: []const u8 = &.{},
    i: usize = 0,
    bits: u64 = 0,
    nbits: u32 = 0,
    tossed: u64 = 0,

    fn memcpy8Le(src: []const u8) u64 {
        var tmp: [8]u8 align(8) = undefined;
        @memcpy(&tmp, src[0..8]);
        return std.mem.readInt(u64, &tmp, .little);
    }

    pub fn window(self: *BitReader, minimum: usize) !bool {
        self.putBack();
        self.reader.toss(self.i);
        self.tossed += self.i;
        self.i = 0;
        self.src = self.reader.peekGreedy(minimum) catch |err| switch (err) {
            error.EndOfStream => self.reader.buffer[self.reader.seek..self.reader.end],
            error.ReadFailed => return error.ReadFailed,
        };
        return self.src.len >= minimum;
    }

    pub fn release(self: *BitReader) void {
        self.putBack();
        self.reader.toss(self.i);
        self.tossed += self.i;
        self.i = 0;
        self.src = &.{};
    }

    // Bytes taken from the reader since the bit reader started; exact when the reader is byte-aligned.
    pub fn consumed(self: *const BitReader) u64 {
        return self.tossed + self.i - self.nbits / 8;
    }

    fn need(self: *BitReader, n: u32) !void {
        try self.fill(n);
        if (self.nbits < n) return error.Truncated;
    }

    // Loads up to `n` bits; at the end of the input it loads what remains, so a caller that peeks
    // a code must check the code's length against `nbits`. Bits above `nbits` are zero.
    fn fill(self: *BitReader, n: u32) !void {
        while (self.nbits < n) {
            if (self.i >= self.src.len) {
                _ = try self.window(8);
                if (self.nbits + self.src.len * 8 < n) {
                    while (self.i < self.src.len) : (self.i += 1) {
                        self.bits |= @as(u64, self.src[self.i]) << @intCast(self.nbits);
                        self.nbits += 8;
                    }
                    return;
                }
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

    pub fn get(self: *BitReader, n: u32) !u32 {
        try self.need(n);
        const mask = (@as(u64, 1) << @intCast(n)) - 1;
        const v: u32 = @truncate(self.bits & mask);
        self.bits >>= @intCast(n);
        self.nbits -= n;
        return v;
    }

    fn consume(self: *BitReader, n: u32) void {
        self.bits >>= @intCast(n);
        self.nbits -= n;
    }

    pub fn alignByte(self: *BitReader) void {
        const drop = self.nbits % 8;
        if (drop == 0) return;
        self.bits >>= @intCast(drop);
        self.nbits -= drop;
    }

    pub fn putBack(self: *BitReader) void {
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

    pub fn getBytes(self: *BitReader, n: usize) ![]const u8 {
        self.putBack();
        self.alignByte();
        if (n > self.src.len - self.i and !try self.window(n)) return error.Truncated;
        const s = self.src[self.i .. self.i + n];
        self.i += n;
        return s;
    }
};

// --- Decoder ---

const BATCH = 131072;

const Tables = struct {
    lit_first: [1 << 10]Entry,
    dist_first: [1 << 9]Entry,
    // Complete residual trees need <=1536/292 entries at widths 10/9.
    lit_spill: [288 * 16]Entry,
    dist_spill: [32 * 64]Entry,
};

pub const Decoder = struct {
    tables: Tables = undefined,
    buffer: [RING + BATCH]u8 = undefined,

    pub fn session(self: *Decoder, comptime Check: type, writer: *std.Io.Writer, limits: Limits) Session(Check) {
        return .{
            .decoder = self,
            .out = self.buffer[0 .. RING + @as(usize, @intCast(@min(BATCH, limits.max_output_bytes)))],
            .writer = writer,
            .max_output_bytes = limits.max_output_bytes,
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(Decoder) == 196608);
}

pub fn Session(comptime Check: type) type {
    return struct {
        const Self = @This();

        br: ?*BitReader = null,
        check: ?*Check = null,
        decoder: *Decoder,
        out: []u8,
        writer: *std.Io.Writer,
        out_pos: usize = RING,
        produced: u64 = 0,
        check_pos: usize = RING,
        stream_start: u64 = 0,
        max_output_bytes: u64,
        // Output cap for each stream (a BGZF block holds at most 65536 bytes), applied with max_output_bytes.
        stream_limit: u64 = std.math.maxInt(u64),

        pub fn stream(self: *Self, br: *BitReader, check: *Check) Error!u64 {
            self.br = br;
            self.check = check;
            defer self.check = null;
            const start = self.position();
            self.stream_start = start;
            self.out = self.decoder.buffer[0..self.batchEnd()];
            self.check_pos = self.out_pos;
            var bfinal: u32 = 0;
            while (bfinal == 0) {
                bfinal = try br.get(1);
                const btype = try br.get(2);
                switch (btype) {
                    0 => {
                        br.alignByte();
                        const len = try br.get(16);
                        const nlen = try br.get(16);
                        if (len != (~nlen & 0xffff)) return error.BadStored;
                        var left: usize = len;
                        while (left != 0) {
                            if (br.i == br.src.len and !try br.window(1)) return error.Truncated;
                            const n = @min(left, br.src.len - br.i);
                            const bytes = try br.getBytes(n);
                            if (bfinal != 0) try self.emitSlice(bytes, false) else try self.emitSlice(bytes, true);
                            left -= n;
                        }
                    },
                    1 => try decodeHuff(Check, self, &FIXED_TABLES.lit, &FIXED_TABLES.dist),
                    2 => {
                        const hlit = try br.get(5) + 257;
                        const hdist = try br.get(5) + 1;
                        const hclen = try br.get(4) + 4;
                        if (hlit > 286 or hdist > 32 or hclen > 19) return error.BadHuffman;
                        var clens: [19]u4 = .{0} ** 19;
                        var ci: u32 = 0;
                        while (ci < hclen) : (ci += 1) {
                            clens[CLEN_ORDER[ci]] = @intCast(try br.get(3));
                        }
                        var clen_first: [1 << 7]Entry = undefined;
                        try fillFirst(clen_first[0..], 7, clens[0..19], clenKind, clenPayload, false);
                        var all_lens: [318]u4 = .{0} ** 318;
                        const total_lens: usize = hlit + hdist;
                        try readDynLens(br, clen_first[0..], all_lens[0..total_lens]);
                        var lit_lens: [288]u4 = .{0} ** 288;
                        @memcpy(lit_lens[0..hlit], all_lens[0..hlit]);
                        var dist_lens: [32]u4 = .{0} ** 32;
                        @memcpy(dist_lens[0..hdist], all_lens[hlit..total_lens]);
                        if (lit_lens[256] == 0) return error.BadHuffman;
                        try fillTwoLevel(&self.decoder.tables.lit_first, &self.decoder.tables.lit_spill, 10, &lit_lens, litKind, litPayload, true);
                        try fillTwoLevel(&self.decoder.tables.dist_first, &self.decoder.tables.dist_spill, 9, &dist_lens, distKind, distPayload, true);
                        try decodeHuff(Check, self, &self.decoder.tables.lit_first, &self.decoder.tables.dist_first);
                    },
                    else => return error.BadBlock,
                }
            }
            self.catchup();
            return self.position() - start;
        }

        pub fn finish(self: *Self) Error!u64 {
            try self.flush(false);
            return self.produced;
        }

        fn position(self: *const Self) u64 {
            return self.produced + (self.out_pos - RING);
        }

        fn batchEnd(self: *const Self) usize {
            const stream_room = (self.stream_start +| self.stream_limit) - self.produced;
            return RING + @as(usize, @intCast(@min(BATCH, self.max_output_bytes - self.produced, stream_room)));
        }

        fn catchup(self: *Self) void {
            if (self.check_pos >= self.out_pos) return;
            self.check.?.update(self.out[self.check_pos..self.out_pos]);
            self.check_pos = self.out_pos;
        }

        fn flush(self: *Self, comptime keep_history: bool) !void {
            const count = self.out_pos - RING;
            if (count == 0) return;
            self.catchup();
            try self.writer.writeAll(self.out[RING..self.out_pos]);
            if (keep_history) {
                const history: usize = @intCast(@min(RING, self.position()));
                @memmove(self.out[RING - history .. RING], self.out[self.out_pos - history .. self.out_pos]);
            }
            self.produced += count;
            self.out_pos = RING;
            self.check_pos = RING;
            self.out = self.decoder.buffer[0..self.batchEnd()];
            if (self.br) |br| br.putBack();
        }

        fn room(self: *Self, comptime keep_history: bool) !void {
            if (self.out_pos < self.out.len) return;
            try self.flush(keep_history);
            if (self.out_pos == self.out.len) return error.OutputLimitExceeded;
        }

        fn emitByte(self: *Self, value: u8) !void {
            try self.room(true);
            self.out[self.out_pos] = value;
            self.out_pos += 1;
        }

        fn emitMatch(self: *Self, distance: usize, length: usize) !void {
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

        fn emitSlice(self: *Self, bytes: []const u8, comptime keep_history: bool) !void {
            var off: usize = 0;
            while (off < bytes.len) {
                try self.room(keep_history);
                const n = @min(bytes.len - off, self.out.len - self.out_pos);
                if (comptime @hasDecl(Check, "copyUpdate")) {
                    self.catchup();
                    self.check.?.copyUpdate(bytes[off..][0..n], self.out[self.out_pos..][0..n]);
                    self.out_pos += n;
                    self.check_pos = self.out_pos;
                } else {
                    @memcpy(self.out[self.out_pos..][0..n], bytes[off..][0..n]);
                    self.out_pos += n;
                }
                off += n;
            }
        }
    };
}

fn fillFirst(table: []Entry, width: u4, lens: []const u4, kind_of: *const fn (usize) Kind, payload_of: *const fn (usize) u16, comptime predecoded: bool) !void {
    const table_len: usize = @as(usize, 1) << width;
    if (table.len != table_len) return error.BadHuffman;
    @memset(table, .{ .nbits = 0, .kind = .invalid, .payload = 0 });
    var codes: [288]u16 = undefined;
    try buildCodes(lens, codes[0..lens.len], .codes);
    const mask: u16 = @intCast(table_len - 1);
    for (lens, 0..) |len, s| {
        if (len == 0) continue;
        const rev = bitReverse(codes[s], len);
        if (len <= width) {
            var entry = Entry{
                .nbits = len,
                .kind = kind_of(s),
                .payload = payload_of(s),
            };
            if (predecoded) entry = predecode(entry);
            const step: usize = @as(usize, 1) << len;
            var i: usize = rev;
            while (i < table_len) : (i += step) {
                const old = table[i];
                if (old.kind != .invalid and (old.kind != entry.kind or old.nbits != entry.nbits or old.payload != entry.payload)) {
                    return error.BadHuffman;
                }
                table[i] = entry;
            }
        } else {
            const idx: usize = rev & mask;
            const old = table[idx];
            if (old.kind != .invalid and old.kind != .long) return error.BadHuffman;
            table[idx] = .{ .nbits = width, .kind = .long, .payload = 0 };
        }
    }
}

/// Builds a root table of `1 << width` entries plus spill subtables for longer codes, in the order and with
/// the method of libdeflate: symbols sorted by code length, each code written once at its bit-reversed
/// position, and the root doubled by copying whenever the length grows. A complete code fills every entry,
/// so nothing is cleared first. On error the root is all invalid.
fn fillTwoLevel(table: []Entry, spill: []Entry, comptime width: u4, lens: []const u4, comptime kind_of: fn (usize) Kind, comptime payload_of: fn (usize) u16, comptime predecoded: bool) !void {
    const invalid: Entry = .{ .nbits = 0, .kind = .invalid, .payload = 0 };
    std.debug.assert(table.len == @as(usize, 1) << width);
    errdefer @memset(table, invalid);
    // Index 16 stays 0 so the length scans below can read one past 15.
    var count: [17]u16 = @splat(0);
    for (lens) |len| count[len] += 1;
    var left: i32 = 1;
    for (1..16) |len| {
        left = left * 2 - count[len];
        if (left < 0) return error.BadHuffman;
    }
    const symbols = lens.len - count[0];
    if (left != 0) {
        // Incomplete: only no codes or one 1-bit code, which decodes on even prefixes.
        if (symbols != 0 and !(symbols == 1 and count[1] == 1)) return error.BadHuffman;
        @memset(table, invalid);
        if (symbols == 1) {
            const symbol = std.mem.indexOfScalar(u4, lens, 1).?;
            const entry = makeEntry(symbol, 1, kind_of, payload_of, predecoded);
            var i: usize = 0;
            while (i < table.len) : (i += 2) table[i] = entry;
        }
        return;
    }
    var offsets: [16]u16 = undefined;
    offsets[0] = 0;
    for (1..16) |len| offsets[len] = offsets[len - 1] + count[len - 1];
    var sorted: [288]u16 = undefined;
    for (lens, 0..) |len, symbol| {
        sorted[offsets[len]] = @intCast(symbol);
        offsets[len] += 1;
    }
    var next: usize = count[0];
    var len: usize = 1;
    while (count[len] == 0) len += 1;
    var remaining: usize = count[len];
    var codeword: usize = 0;
    var end: usize = @as(usize, 1) << @intCast(@min(len, width));
    // Root: codes of at most `width` bits.
    while (len <= width) {
        while (true) {
            table[codeword] = makeEntry(sorted[next], @intCast(len), kind_of, payload_of, predecoded);
            next += 1;
            if (codeword == end - 1) {
                // The all-ones codeword is the last code: double the root up to its full width.
                while (end < table.len) : (end <<= 1) @memcpy(table[end..][0..end], table[0..end]);
                return;
            }
            const bit = @as(usize, 1) << @intCast(std.math.log2_int(usize, codeword ^ (end - 1)));
            codeword = (codeword & (bit - 1)) | bit;
            remaining -= 1;
            if (remaining == 0) break;
        }
        while (true) {
            len += 1;
            if (len <= width) {
                @memcpy(table[end..][0..end], table[0..end]);
                end <<= 1;
            }
            remaining = count[len];
            if (remaining != 0) break;
        }
    }
    // Spill: one subtable per root prefix of the longer codes, in code order, sized by the codes under it.
    const root_mask = table.len - 1;
    var prefix: usize = std.math.maxInt(usize);
    var start: usize = 0;
    var used: usize = 0;
    while (true) {
        if (codeword & root_mask != prefix) {
            prefix = codeword & root_mask;
            start = used;
            var height: usize = len - width;
            var space: usize = remaining;
            while (space < @as(usize, 1) << @intCast(height)) {
                height += 1;
                space = (space << 1) + count[width + height];
            }
            used = start + (@as(usize, 1) << @intCast(height));
            if (used > spill.len) return error.BadHuffman;
            table[prefix] = .{ .nbits = width, .kind = .long, .extra = @intCast(height), .payload = @intCast(start) };
        }
        const entry = makeEntry(sorted[next], @intCast(len), kind_of, payload_of, predecoded);
        next += 1;
        const stride = @as(usize, 1) << @intCast(len - width);
        var i = start + (codeword >> width);
        while (i < used) : (i += stride) spill[i] = entry;
        if (codeword == (@as(usize, 1) << @intCast(len)) - 1) return;
        const bit = @as(usize, 1) << @intCast(std.math.log2_int(usize, codeword ^ ((@as(usize, 1) << @intCast(len)) - 1)));
        codeword = (codeword & (bit - 1)) | bit;
        remaining -= 1;
        while (remaining == 0) {
            len += 1;
            remaining = count[len];
        }
    }
}

inline fn makeEntry(symbol: usize, len: u4, comptime kind_of: fn (usize) Kind, comptime payload_of: fn (usize) u16, comptime predecoded: bool) Entry {
    const entry: Entry = .{ .nbits = len, .kind = kind_of(symbol), .payload = payload_of(symbol) };
    return if (predecoded) predecode(entry) else entry;
}

inline fn lookupLong(root: Entry, spill: []const Entry, bits: u64, comptime width: u4) Entry {
    const mask = (@as(u64, 1) << @intCast(root.extra)) - 1;
    return spill[root.payload + @as(usize, @intCast((bits >> width) & mask))];
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

fn peekFirst(table: []const Entry, width: u4, bits: u64) Entry {
    const mask = (@as(u64, 1) << width) - 1;
    return table[@intCast(bits & mask)];
}

fn decodeClen(br: *BitReader, clen_tab: []const Entry) !u8 {
    try br.fill(7);
    const e = peekFirst(clen_tab, 7, br.bits);
    if (e.kind == .invalid or e.kind == .long or e.nbits > br.nbits) return if (br.nbits < 7) error.Truncated else error.BadHuffman;
    br.consume(e.nbits);
    return @intCast(e.payload);
}

fn readDynLens(br: *BitReader, clen_tab: []const Entry, out: []u4) !void {
    var i: usize = 0;
    var prev: u4 = 0;
    while (i < out.len) {
        const s = try decodeClen(br, clen_tab);
        if (s <= 15) {
            const code_len: u4 = @intCast(s);
            out[i] = code_len;
            prev = code_len;
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

fn decodeFast(comptime Check: type, ctx: *Session(Check), lit: []const Entry, dist: []const Entry) !bool {
    if (ctx.position() - ctx.stream_start >= RING) return decodeFastImpl(Check, ctx, lit, dist, true);
    return decodeFastImpl(Check, ctx, lit, dist, false);
}

fn decodeFastImpl(comptime Check: type, ctx: *Session(Check), lit: []const Entry, dist: []const Entry, comptime full_history: bool) !bool {
    const br = ctx.br.?;
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
        if (e.kind == .long) e = lookupLong(e, &ctx.decoder.tables.lit_spill, bits, 10);
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
        if (d.kind == .long) d = lookupLong(d, &ctx.decoder.tables.dist_spill, bits, 9);
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

fn decodeHuff(comptime Check: type, ctx: *Session(Check), lit: []const Entry, dist: []const Entry) !void {
    const br = ctx.br.?;
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
        if (try @call(.never_inline, decodeFast, .{ Check, ctx, lit, dist })) return;
        // A stream may end at the end of the input (raw DEFLATE has no trailer), so fewer than 15 bits
        // can remain; a code that is invalid or longer than what remains is then a truncation.
        try br.fill(15);
        var e = peekFirst(lit, 10, br.bits);
        if (e.kind == .long) e = lookupLong(e, &ctx.decoder.tables.lit_spill, br.bits, 10);
        if (br.nbits < 15 and (e.kind == .invalid or e.nbits > br.nbits)) return error.Truncated;
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
                try br.fill(15);
                var d = peekFirst(dist, 9, br.bits);
                if (d.kind == .long) d = lookupLong(d, &ctx.decoder.tables.dist_spill, br.bits, 9);
                if (br.nbits < 15 and (d.kind != .dist or d.nbits > br.nbits)) return error.Truncated;
                if (d.kind != .dist) return error.BadSymbol;
                br.consume(d.nbits);
                const dadd = if (d.extra != 0) try br.get(d.extra) else 0;
                try ctx.emitMatch(d.payload + @as(usize, dadd), length);
            },
            else => return error.BadSymbol,
        }
    }
}

// --- Encoder ---

const ENCODE_HASH = 32768;

fn rebase(positions: []u16) void {
    const V = @Vector(16, u16);
    var p: usize = 0;
    while (p + 16 <= positions.len) : (p += 16) {
        const values: V = positions[p..][0..16].*;
        positions[p..][0..16].* = values -| @as(V, @splat(RING));
    }
    for (positions[p..]) |*value| value.* -|= RING;
}

fn matchLength(a: []const u8, b: []const u8) usize {
    var n: usize = 0;
    while (n + 32 <= a.len) : (n += 32) {
        const va: @Vector(32, u8) = a[n..][0..32].*;
        const vb: @Vector(32, u8) = b[n..][0..32].*;
        const different = va != vb;
        const mask: u32 = @bitCast(different);
        if (mask != 0) return n + @ctz(mask);
    }
    while (n < a.len and a[n] == b[n]) : (n += 1) {}
    return n;
}

fn distCode(d: usize) usize {
    if (d <= 4) return d - 1;
    const top = std.math.log2_int(usize, d - 1);
    return 2 * @as(usize, top) + (((d - 1) >> (top - 1)) & 1);
}

const BitWriter = struct {
    writer: *std.Io.Writer,
    value: u64 = 0,
    count: u32 = 0,

    fn put(self: *BitWriter, value: u32, n: u5) EncodeError!void {
        std.debug.assert(n <= 16 and (n == 0 or value < (@as(u32, 1) << n)));
        if (n == 0) return;
        if (self.count > 47) try self.drain();
        self.value |= @as(u64, value) << @intCast(self.count);
        self.count += n;
    }

    fn drain(self: *BitWriter) EncodeError!void {
        const n: usize = self.count / 8;
        if (n == 0) return;
        if (self.writer.buffer.len - self.writer.end >= 8) {
            // The wider store stays in unused capacity; only whole bytes become buffered.
            std.mem.writeInt(u64, self.writer.buffer[self.writer.end..][0..8], self.value, .little);
            self.writer.end += n;
        } else {
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, self.value, .little);
            try self.writer.writeAll(bytes[0..n]);
        }
        self.value >>= @intCast(n * 8);
        self.count &= 7;
    }

    inline fn add(self: *BitWriter, entry: u64) void {
        self.value |= (entry & 0xffffffff) << @intCast(self.count);
        self.count += @intCast(entry >> 32);
    }

    fn symbol(self: *BitWriter, tree: *const EncodeTree, s: usize) EncodeError!void {
        try self.put(tree.codes[s], @intCast(tree.lens[s]));
    }

    fn alignByte(self: *BitWriter) EncodeError!void {
        const remainder = self.count & 7;
        if (remainder != 0) try self.put(0, @intCast(8 - remainder));
        try self.drain();
    }
};

// Over-depth trees fall back to fixed or stored blocks.
const EncodeTree = struct {
    const Node = struct { weight: u32, parent: u16 = 0 };
    lens: [288]u4 = @splat(0),
    codes: [288]u16 = undefined,

    fn build(self: *EncodeTree, freq: []const u32, max_bits: u4) bool {
        var nodes: [576]Node = undefined;
        var heap: [288]u16 = undefined;
        var size: usize = 0;
        @memset(&self.lens, 0);
        for (freq, 0..) |f, i| {
            nodes[i] = .{ .weight = f };
            if (f == 0) continue;
            var j = size;
            size += 1;
            while (j != 0) {
                const parent = (j - 1) / 2;
                if (nodes[heap[parent]].weight <= f) break;
                heap[j] = heap[parent];
                j = parent;
            }
            heap[j] = @intCast(i);
        }
        if (size == 0) return false;
        var next: usize = freq.len;
        while (size > 1) {
            const a = heap[0];
            size -= 1;
            heap[0] = heap[size];
            sift(&heap, size, &nodes);
            const b = heap[0];
            nodes[next] = .{ .weight = nodes[a].weight + nodes[b].weight };
            nodes[a].parent = @intCast(next);
            nodes[b].parent = @intCast(next);
            heap[0] = @intCast(next);
            sift(&heap, size, &nodes);
            next += 1;
        }
        for (freq, 0..) |f, i| {
            if (f == 0) continue;
            var p = i;
            var depth: u8 = 0;
            while (nodes[p].parent != 0) {
                depth += 1;
                if (depth > max_bits) return self.limit(freq, &nodes, max_bits);
                p = nodes[p].parent;
            }
            self.lens[i] = @intCast(@max(1, depth));
        }
        return self.canonical();
    }

    // JPEG Annex K.3: each step lifts two deepest leaves and splits a shallower one, so the
    // Kraft sum stays 1 and a shallower leaf always exists while depth exceeds max_bits.
    noinline fn limit(self: *EncodeTree, freq: []const u32, nodes: *const [576]Node, max_bits: u4) bool {
        var depths: [288]u16 = @splat(0);
        var count: [288]u32 = @splat(0);
        var max_depth: usize = 0;
        var order: [288]u16 = undefined;
        var n: usize = 0;
        for (freq, 0..) |f, i| {
            if (f == 0) continue;
            var p = i;
            var depth: u16 = 0;
            while (nodes[p].parent != 0) : (p = nodes[p].parent) depth += 1;
            depths[i] = @max(1, depth);
            count[depths[i]] += 1;
            max_depth = @max(max_depth, depths[i]);
            order[n] = @intCast(i);
            n += 1;
        }
        var len = max_depth;
        while (len > max_bits) : (len -= 1) {
            while (count[len] > 0) {
                var j = len - 2;
                while (count[j] == 0) j -= 1;
                count[len] -= 2;
                count[len - 1] += 1;
                count[j + 1] += 2;
                count[j] -= 1;
            }
        }
        // Shallowest original depth, then highest frequency, receives the shortest new length.
        for (1..n) |i| {
            const x = order[i];
            var j = i;
            while (j > 0) : (j -= 1) {
                const y = order[j - 1];
                if (depths[x] > depths[y] or (depths[x] == depths[y] and freq[x] <= freq[y])) break;
                order[j] = y;
            }
            order[j] = x;
        }
        var k: usize = 0;
        for (1..@as(usize, max_bits) + 1) |l| {
            for (order[k..][0..count[l]]) |s| self.lens[s] = @intCast(l);
            k += count[l];
        }
        std.debug.assert(k == n);
        return self.canonical();
    }

    fn sift(heap: *[288]u16, size: usize, nodes: *const [576]Node) void {
        const value = heap[0];
        var p: usize = 0;
        while (p * 2 + 1 < size) {
            var child = p * 2 + 1;
            if (child + 1 < size and nodes[heap[child + 1]].weight < nodes[heap[child]].weight) child += 1;
            if (nodes[value].weight <= nodes[heap[child]].weight) break;
            heap[p] = heap[child];
            p = child;
        }
        heap[p] = value;
    }

    fn canonical(self: *EncodeTree) bool {
        buildCodes(&self.lens, &self.codes, .symbols) catch return false;
        for (self.lens, &self.codes) |n, *code| code.* = bitReverse(code.*, n);
        return true;
    }
};

const CodeRuns = struct {
    symbols: [316]u8 = undefined,
    extras: [316]u8 = undefined,
    widths: [316]u5 = undefined,
    freq: [19]u32 = @splat(0),
    count: usize = 0,

    fn add(self: *CodeRuns, s: u8, e: u8, w: u5) void {
        self.symbols[self.count] = s;
        self.extras[self.count] = e;
        self.widths[self.count] = w;
        self.freq[s] += 1;
        self.count += 1;
    }

    fn encode(self: *CodeRuns, lengths: []const u4) void {
        var p: usize = 0;
        while (p < lengths.len) {
            const value = lengths[p];
            var end = p + 1;
            while (end < lengths.len and lengths[end] == value) : (end += 1) {}
            var left = end - p;
            if (value != 0) {
                self.add(value, 0, 0);
                left -= 1;
            }
            while (left != 0) {
                if (value == 0 and left >= 11) {
                    const n = @min(left, 138);
                    self.add(18, @intCast(n - 11), 7);
                    left -= n;
                } else if (value == 0 and left >= 3) {
                    const n = @min(left, 10);
                    self.add(17, @intCast(n - 3), 3);
                    left -= n;
                } else if (value != 0 and left >= 3) {
                    const n = @min(left, 6);
                    self.add(16, @intCast(n - 3), 2);
                    left -= n;
                } else {
                    self.add(value, 0, 0);
                    left -= 1;
                }
            }
            p = end;
        }
    }
};

const LEN_CODE: [256]u8 = blk: {
    @setEvalBranchQuota(10000);
    var result: [256]u8 = undefined;
    for (&result, 0..) |*c, i| {
        var k: usize = 0;
        while (k + 1 < LEN_BASE.len and LEN_BASE[k + 1] <= i + 3) : (k += 1) {}
        c.* = @intCast(k);
    }
    break :blk result;
};
const FIXED_LIT: EncodeTree = blk: {
    @setEvalBranchQuota(10000);
    var tree: EncodeTree = .{};
    tree.lens = FIXED_LIT_LENS;
    if (!tree.canonical()) @compileError("invalid fixed Huffman tree");
    break :blk tree;
};
const FIXED_DIST: EncodeTree = blk: {
    @setEvalBranchQuota(10000);
    var tree: EncodeTree = .{};
    @memcpy(tree.lens[0..32], &FIXED_DIST_LENS);
    if (!tree.canonical()) @compileError("invalid fixed Huffman tree");
    break :blk tree;
};

pub const Level = enum(u4) { fast = 1, balanced = 5, dense = 9 };

pub const EncodeError = error{ ReadFailed, WriteFailed };

pub const CompressOptions = struct {
    level: Level = .balanced,
};

pub const Encoder = struct {
    window: [2 * RING]u8 = undefined,
    head: [ENCODE_HASH]u16 = undefined,
    previous: [RING]u16 = undefined,
    tokens: [RING + RING / 4 + 2]u8 = undefined,
    lit_freq: [286]u32 = undefined,
    dist_freq: [30]u32 = undefined,
    token_bytes: usize = undefined,

    pub fn encodeStream(self: *Encoder, comptime Check: type, reader: *std.Io.Reader, writer: *std.Io.Writer, check: *Check, level: Level) EncodeError!u64 {
        // `previous` is never cleared: with `head` clear, every position a chain reaches was inserted in this
        // stream, which wrote its `previous` slot; a slot reused by a later position is behind `lower` and
        // rejected before it is read. BGZF pays this once per 64 KiB block.
        // 64 KiB: `@memset` here would call compiler_rt's byte-per-iteration `memset` (see `copy.zero`).
        copy.zero(std.mem.asBytes(&self.head));
        var bits: BitWriter = .{ .writer = writer };
        var history: usize = 0;
        var size: u64 = 0;
        var lookahead: [1]u8 = undefined;
        var carried: usize = 0;
        var skip_search = false;
        while (true) {
            if (carried != 0) self.window[history] = lookahead[0];
            const n = carried + try reader.readSliceShort(self.window[history + carried ..][0 .. RING - carried]);
            carried = if (n == RING) try reader.readSliceShort(&lookahead) else 0;
            const last = carried == 0;
            const end = history + n;
            check.update(self.window[history..end]);
            size +%= n;
            // The previous block's final two positions lacked three-byte lookahead.
            if (history != 0) {
                var p = history - 2;
                while (p < history and p + 3 <= end) : (p += 1) {
                    if (level == .fast) self.insert(p, self.hash(p, end), false) else self.insert(p, self.hash(p, end), true);
                }
            }
            // Fast searches one head candidate, so its parse keeps no chain.
            if (level == .fast) self.parse(history, end, level, skip_search, false) else self.parse(history, end, level, skip_search, true);
            const stored = try self.emit(&bits, self.window[history..end], last);
            // Stored blocks are a bounded miss signal. Recheck after one skipped block.
            skip_search = stored and !skip_search and level != .fast;
            if (last) break;
            if (history != 0) {
                @memcpy(self.window[0..RING], self.window[RING..][0..RING]);
                rebase(&self.head);
                if (level != .fast) rebase(&self.previous);
            }
            history = RING;
        }
        try bits.alignByte();
        return size;
    }

    fn hash(self: *const Encoder, p: usize, end: usize) usize {
        // The final three-byte tail has no fourth byte for the hot-path key.
        const v = if (p + 4 <= end)
            std.mem.readInt(u32, self.window[p..][0..4], .little)
        else
            @as(u32, self.window[p]) | (@as(u32, self.window[p + 1]) << 8) | (@as(u32, self.window[p + 2]) << 16);
        return (v *% 0x1e35a7bd) >> 17;
    }

    fn insert(self: *Encoder, p: usize, h: usize, comptime chain: bool) void {
        if (chain) self.previous[p & (RING - 1)] = self.head[h];
        self.head[h] = @intCast(p + 1);
    }

    const Match = struct { len: usize = 2, dist: usize = 0 };

    fn find(self: *const Encoder, p: usize, end: usize, budget: usize, nice: usize, h: usize, comptime chain: bool) Match {
        var best: Match = .{};
        if (p + 3 > end) return best;
        const limit = @min(258, end - p);
        const lower = p -| RING;
        var entry = self.head[h];
        var attempts = budget;
        while (entry != 0 and attempts != 0) : (attempts -= 1) {
            const q: usize = entry - 1;
            if (q < lower or q >= p) break;
            // Only a candidate matching every byte up to best.len can win, so the four bytes ending there are
            // compared at once; the output is the same as checking the last one, but most losers stop here.
            const head_same = std.mem.readInt(u16, self.window[q..][0..2], .little) == std.mem.readInt(u16, self.window[p..][0..2], .little);
            const end_same = if (best.len >= 3)
                std.mem.readInt(u32, self.window[q + best.len - 3 ..][0..4], .little) == std.mem.readInt(u32, self.window[p + best.len - 3 ..][0..4], .little)
            else
                self.window[q + best.len] == self.window[p + best.len];
            if (head_same and end_same) {
                const len = matchLength(self.window[p..][0..limit], self.window[q..][0..limit]);
                if (len > best.len) {
                    best = .{ .len = len, .dist = p - q };
                    if (len >= nice or len == limit) break;
                }
            }
            if (!chain) break;
            const next = self.previous[q & (RING - 1)];
            if (next >= entry) break;
            entry = next;
        }
        return best;
    }

    fn hasEarlyMatch(self: *const Encoder, start: usize, end: usize) bool {
        const lower = start -| RING;
        const stop = @min(end, start + 1024);
        var p = start;
        while (p + 4 <= stop) : (p += 1) {
            const h = self.hash(p, end);
            const entry = self.head[h];
            if (entry == 0) continue;
            const q: usize = entry - 1;
            if (q < lower or q >= p) continue;
            if (std.mem.readInt(u32, self.window[p..][0..4], .little) ==
                std.mem.readInt(u32, self.window[q..][0..4], .little)) return true;
        }
        return false;
    }

    fn parse(self: *Encoder, start: usize, end: usize, level: Level, skip_search: bool, comptime chain: bool) void {
        @memset(&self.lit_freq, 0);
        @memset(&self.dist_freq, 0);
        self.lit_freq[256] = 1;
        self.token_bytes = 0;
        const budget: usize = switch (level) {
            .fast => 1,
            .balanced => 12,
            .dense => 128,
        };
        const nice: usize = switch (level) {
            .fast => 8,
            .balanced => 96,
            .dense => 128,
        };
        var p = start;
        var literal_start = start;
        var pending: Match = .{};
        var pending_hash: usize = 0;
        const search_disabled = skip_search and !self.hasEarlyMatch(start, end);
        while (p < end) {
            var m: Match = undefined;
            var m_hash: usize = undefined;
            if (pending.len >= 3) {
                m = pending;
                m_hash = pending_hash;
            } else if (search_disabled) {
                if (p + 3 <= end) m_hash = self.hash(p, end) else m_hash = 0;
                m = .{};
            } else if (p + 3 <= end) {
                m_hash = self.hash(p, end);
                m = self.find(p, end, budget, nice, m_hash, chain);
            } else {
                m = .{};
                m_hash = 0;
            }
            pending = .{};
            if (p + 3 <= end) self.insert(p, m_hash, chain);
            if (chain and m.len >= 3 and m.len < 16 and p + 3 < end) {
                pending_hash = self.hash(p + 1, end);
                const next = self.find(p + 1, end, @min(budget, 8), nice, pending_hash, chain);
                if (next.len > m.len) {
                    pending = next;
                    m.len = 2;
                }
            }
            if (m.len >= 3) {
                self.addLiterals(p - literal_start);
                std.mem.writeInt(u16, self.tokens[self.token_bytes..][0..2], @as(u16, @intCast(m.dist - 1)) | 0x8000, .little);
                self.tokens[self.token_bytes + 2] = @intCast(m.len - 3);
                self.token_bytes += 3;
                self.lit_freq[257 + @as(usize, LEN_CODE[m.len - 3])] += 1;
                self.dist_freq[distCode(m.dist)] += 1;
                const stop = p + m.len;
                p += 1;
                while (p < stop) : (p += 1) {
                    if (chain and p + 3 <= end) self.insert(p, self.hash(p, end), chain);
                }
                literal_start = p;
            } else {
                self.lit_freq[self.window[p]] += 1;
                p += 1;
            }
        }
        self.addLiterals(end - literal_start);
    }

    fn addLiterals(self: *Encoder, n: usize) void {
        if (n == 0) return;
        std.mem.writeInt(u16, self.tokens[self.token_bytes..][0..2], @intCast(n - 1), .little);
        self.token_bytes += 2;
    }

    fn cost(self: *const Encoder, lit: *const EncodeTree, dist: *const EncodeTree) u64 {
        var n: u64 = 0;
        for (self.lit_freq, 0..) |f, i| n += @as(u64, f) * (lit.lens[i] + @as(u8, if (i >= 257) LEN_EXTRA[i - 257] else 0));
        for (self.dist_freq, 0..) |f, i| n += @as(u64, f) * (dist.lens[i] + @as(u8, DIST_EXTRA[i]));
        return n;
    }

    fn emit(self: *const Encoder, bits: *BitWriter, raw: []const u8, last: bool) EncodeError!bool {
        var lit: EncodeTree = .{};
        var dist: EncodeTree = .{};
        var code: EncodeTree = .{};
        var run: CodeRuns = .{};
        var dynamic: u64 = std.math.maxInt(u64);
        var nl: usize = 286;
        var nd: usize = 30;
        var nc: usize = 19;
        var dist_freq = self.dist_freq;
        var sum: u32 = 0;
        for (dist_freq) |f| sum += f;
        if (sum == 0) dist_freq[0] = 1;
        if (lit.build(&self.lit_freq, 15) and dist.build(&dist_freq, 15)) {
            while (nl > 257 and lit.lens[nl - 1] == 0) nl -= 1;
            while (nd > 1 and dist.lens[nd - 1] == 0) nd -= 1;
            var lengths: [316]u4 = undefined;
            @memcpy(lengths[0..nl], lit.lens[0..nl]);
            @memcpy(lengths[nl..][0..nd], dist.lens[0..nd]);
            run.encode(lengths[0 .. nl + nd]);
            if (code.build(&run.freq, 7)) {
                while (nc > 4 and code.lens[CLEN_ORDER[nc - 1]] == 0) nc -= 1;
                dynamic = 3 + 5 + 5 + 4 + 3 * nc + self.cost(&lit, &dist);
                for (run.symbols[0..run.count], run.widths[0..run.count]) |s, w| dynamic += code.lens[s] + @as(u8, w);
            }
        }
        const fixed = 3 + self.cost(&FIXED_LIT, &FIXED_DIST);
        const stored = 3 + ((8 - ((@as(usize, bits.count) + 3) & 7)) & 7) + 32 + raw.len * 8;
        if (stored < fixed and stored <= dynamic) {
            try bits.put(@intFromBool(last), 3);
            try bits.alignByte();
            var header: [4]u8 = undefined;
            const len: u16 = @intCast(raw.len);
            std.mem.writeInt(u16, header[0..2], len, .little);
            std.mem.writeInt(u16, header[2..4], ~len, .little);
            try bits.writer.writeAll(&header);
            try bits.writer.writeAll(raw);
            return true;
        }
        if (dynamic < fixed) {
            try bits.put(4 | @as(u32, @intFromBool(last)), 3);
            try bits.put(@intCast(nl - 257), 5);
            try bits.put(@intCast(nd - 1), 5);
            try bits.put(@intCast(nc - 4), 4);
            for (CLEN_ORDER[0..nc]) |s| try bits.put(code.lens[s], 3);
            for (run.symbols[0..run.count], run.widths[0..run.count], run.extras[0..run.count]) |s, w, e| {
                try bits.symbol(&code, s);
                try bits.put(e, w);
            }
            try self.emitTokens(bits, raw, &lit, &dist);
        } else {
            try bits.put(2 | @as(u32, @intFromBool(last)), 3);
            try self.emitTokens(bits, raw, &FIXED_LIT, &FIXED_DIST);
        }
        try bits.drain();
        return false;
    }

    fn emitTokens(self: *const Encoder, bits: *BitWriter, raw: []const u8, lit: *const EncodeTree, dist: *const EncodeTree) EncodeError!void {
        var lit_tab: [256]u64 = undefined;
        for (&lit_tab, 0..) |*e, s| e.* = lit.codes[s] | (@as(u64, lit.lens[s]) << 32);
        var len_tab: [256]u64 = undefined;
        for (&len_tab, 0..) |*e, v| {
            const l = LEN_CODE[v];
            const code_len: u6 = lit.lens[257 + @as(usize, l)];
            const extra = @as(u64, v) + 3 - LEN_BASE[l];
            e.* = (lit.codes[257 + @as(usize, l)] | (extra << code_len)) | (@as(u64, code_len + LEN_EXTRA[l]) << 32);
        }
        var dist_tab: [30]u64 = undefined;
        for (&dist_tab, 0..) |*e, c| e.* = dist.codes[c] | (@as(u64, dist.lens[c]) << 32);
        try bits.drain();
        var t: usize = 0;
        var p: usize = 0;
        while (t < self.token_bytes) {
            const word = std.mem.readInt(u16, self.tokens[t..][0..2], .little);
            t += 2;
            if (word & 0x8000 == 0) {
                const end = p + @as(usize, word) + 1;
                while (p + 3 <= end) : (p += 3) {
                    bits.add(lit_tab[raw[p]]);
                    bits.add(lit_tab[raw[p + 1]]);
                    bits.add(lit_tab[raw[p + 2]]);
                    try bits.drain();
                }
                while (p < end) : (p += 1) bits.add(lit_tab[raw[p]]);
                try bits.drain();
            } else {
                const v = self.tokens[t];
                t += 1;
                const d = @as(usize, word & 0x7fff) + 1;
                const dc = distCode(d);
                bits.add(len_tab[v]);
                bits.add(dist_tab[dc]);
                bits.add(@as(u64, d - DIST_BASE[dc]) | (@as(u64, DIST_EXTRA[dc]) << 32));
                try bits.drain();
                p += @as(usize, v) + 3;
            }
        }
        std.debug.assert(p == raw.len);
        try bits.symbol(lit, 256);
    }
};

comptime {
    std.debug.assert(@sizeOf(Encoder) == 238848);
}

const TestCheck = struct {
    fn update(_: *TestCheck, _: []const u8) void {}
};

test {
    _ = copy;
}

test "[property] - [deflate tables]: rejected trees clear roots without changing adjacent entries" {
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

test "[property] - [deflate tables]: narrower roots preserve entries and bounded spill" {
    const Fill = struct {
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
        try Fill.check(width, &lens, &seen_heights, true);
        lens[alphabet - 1] = 1;
        try Fill.check(width, &lens, &seen_heights, true);
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
                if (count <= 17 or count % 16 == 0 or count == alphabet) try Fill.check(width, &lens, &seen_heights, count == alphabet);
            }
        }
        try std.testing.expectEqual((@as(u16, 1) << @as(u4, 16 - @as(u5, width))) - 2, seen_heights);
    }
}

test "[edge] - [deflate decoder]: decoded counters stop at the u64 output bound" {
    const decoder = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(decoder);
    var reader = std.Io.Reader.fixed("");
    var br: BitReader = .{ .reader = &reader };
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var check: TestCheck = .{};
    var ctx: Session(TestCheck) = .{
        .br = &br,
        .check = &check,
        .decoder = decoder,
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

test "[edge] - [deflate decoder]: streams whose last code ends at the end of input decode" {
    const decoder = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(decoder);
    const encoder = try std.testing.allocator.create(Encoder);
    defer std.testing.allocator.destroy(encoder);
    var plain: [3000]u8 = undefined;
    for (&plain, 0..) |*b, i| b.* = "ACGT"[(i * i + i / 7) % 4];
    var dynamic: [4000]u8 = undefined;
    var plain_reader = std.Io.Reader.fixed(&plain);
    var dynamic_writer = std.Io.Writer.fixed(&dynamic);
    var encode_check: TestCheck = .{};
    _ = try encoder.encodeStream(TestCheck, &plain_reader, &dynamic_writer, &encode_check, .balanced);
    const cases = .{ .{ "\x73\x04\x00", "A" }, .{ dynamic_writer.buffered(), &plain } };
    var output: [3000]u8 = undefined;
    inline for (cases) |case| {
        var reader = std.Io.Reader.fixed(case[0]);
        var br: BitReader = .{ .reader = &reader };
        var writer = std.Io.Writer.fixed(&output);
        var check: TestCheck = .{};
        var session = decoder.session(TestCheck, &writer, .{});
        try std.testing.expectEqual(@as(u64, case[1].len), try session.stream(&br, &check));
        _ = try session.finish();
        try std.testing.expectEqualSlices(u8, case[1], writer.buffered());
    }
}

test "[edge] - [deflate decoder]: a finished or failed stream keeps no pointer to the caller's check" {
    const decoder = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(decoder);
    var output: [8]u8 = undefined;
    for ([_][]const u8{ &.{ 0x01, 0x03, 0x00, 0xfc, 0xff, 'a', 'b', 'c' }, &.{ 0x01, 0x03, 0x00, 0xfc, 0xfe } }) |input| {
        var reader = std.Io.Reader.fixed(input);
        var br: BitReader = .{ .reader = &reader };
        var writer = std.Io.Writer.fixed(&output);
        var check: TestCheck = .{};
        var session = decoder.session(TestCheck, &writer, .{});
        if (input.len == 8) {
            try std.testing.expectEqual(@as(u64, 3), try session.stream(&br, &check));
        } else {
            try std.testing.expectError(error.BadStored, session.stream(&br, &check));
        }
        try std.testing.expectEqual(@as(?*TestCheck, null), session.check);
    }
}

test "[property] - [deflate decoder]: fast literals consume exact bits within output room" {
    const decoder = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(decoder);
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
            var br: BitReader = .{ .reader = &reader, .src = &input };
            var check: TestCheck = .{};
            var ctx: Session(TestCheck) = .{
                .br = &br,
                .check = &check,
                .decoder = decoder,
                .out = decoder.buffer[0 .. RING + room],
                .writer = &sink.writer,
                .max_output_bytes = std.math.maxInt(u64),
            };
            const ended = try decodeFastImpl(TestCheck, &ctx, &FIXED_TABLES.lit, &FIXED_TABLES.dist, false);
            const written = ctx.out_pos - RING;
            try std.testing.expect(written <= length and written <= room);
            if (ended) try std.testing.expectEqual(length, written);
            try std.testing.expectEqual(ends[if (ended) length + 1 else written], br.i * 8 - br.nbits);
            try std.testing.expectEqualSlices(u8, plain[0..written], decoder.buffer[RING..][0..written]);
            for (decoder.buffer[ctx.out_pos .. RING + 384]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
        }
    }
}

test "[edge] - [deflate decoder]: lookahead retains unread bits after a maximum-width match" {
    const decoder = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(decoder);
    const invalid: Entry = .{ .nbits = 0, .kind = .invalid, .payload = 0 };
    @memset(&decoder.tables.lit_first, invalid);
    @memset(&decoder.tables.dist_first, invalid);
    @memset(&decoder.tables.lit_spill, invalid);
    @memset(&decoder.tables.dist_spill, invalid);
    decoder.tables.lit_first[0] = .{ .nbits = 10, .kind = .long, .extra = 5, .payload = 0 };
    decoder.tables.lit_spill[0] = .{ .nbits = 15, .kind = .len, .extra = 5, .payload = 227 };
    decoder.tables.dist_first[0] = .{ .nbits = 9, .kind = .long, .extra = 6, .payload = 0 };
    decoder.tables.dist_spill[0] = .{ .nbits = 15, .kind = .dist, .extra = 13, .payload = 24577 };
    decoder.tables.lit_first[1] = .{ .nbits = 1, .kind = .eob, .payload = 0 };
    for (decoder.buffer[0..RING], 0..) |*byte, i| byte.* = @truncate(i * 73 + i / 256);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    for ([_]u4{ 10, 11 }) |literal_width| {
        const literal: Entry = .{ .nbits = literal_width, .kind = .lit, .payload = 'A' };
        decoder.tables.lit_first[512] = if (literal_width == 10) literal else .{ .nbits = 10, .kind = .long, .extra = 1, .payload = 32 };
        decoder.tables.lit_spill[33] = literal;
        const literal_code: u64 = if (literal_width == 10) 512 else 1536;
        const consumed: usize = 48 + @as(usize, literal_width) + 1;
        var input: [32]u8 = @splat(0);
        const token_bits: u64 = (@as(u64, 31) << 15) | (@as(u64, 8191) << 35);
        std.mem.writeInt(u64, input[0..8], token_bits | (literal_code << 48) | (@as(u64, 1) << @intCast(consumed - 1)), .little);
        var reader = std.Io.Reader.fixed(&input);
        var br: BitReader = .{ .reader = &reader, .src = &input };
        var check: TestCheck = .{};
        var ctx: Session(TestCheck) = .{
            .br = &br,
            .check = &check,
            .decoder = decoder,
            .out = &decoder.buffer,
            .writer = &sink.writer,
            .produced = RING,
            .max_output_bytes = std.math.maxInt(u64),
        };
        try std.testing.expect(try decodeFastImpl(TestCheck, &ctx, &decoder.tables.lit_first, &decoder.tables.dist_first, true));
        try std.testing.expectEqual(RING + 259, ctx.out_pos);
        try std.testing.expectEqual(consumed, br.i * 8 - br.nbits);
        try std.testing.expectEqualSlices(u8, decoder.buffer[0..258], decoder.buffer[RING..][0..258]);
        try std.testing.expectEqual(@as(u8, 'A'), decoder.buffer[RING + 258]);
    }
}

test "[edge] - [deflate encoder]: over-depth encoding trees are shortened to complete limited codes" {
    var tree: EncodeTree = .{};
    // Fibonacci weights give an unlimited Huffman depth of symbols - 1.
    var fib: [25]u32 = @splat(1);
    for (2..fib.len) |i| fib[i] = fib[i - 1] + fib[i - 2];
    for ([_]struct { symbols: usize, limit: u4 }{ .{ .symbols = 25, .limit = 15 }, .{ .symbols = 19, .limit = 7 } }) |case| {
        const freq = fib[0..case.symbols];
        try std.testing.expect(tree.build(freq, case.limit));
        var kraft: u32 = 0;
        for (freq, 0..) |f, i| {
            const len = tree.lens[i];
            try std.testing.expect(len >= 1 and len <= case.limit);
            kraft += @as(u32, 1) << @as(u5, case.limit - len);
            for (freq, 0..) |g, k| {
                if (f > g) try std.testing.expect(len <= tree.lens[k]);
            }
        }
        try std.testing.expectEqual(@as(u32, 1) << @as(u5, case.limit), kraft);
        for (tree.lens[case.symbols..]) |len| try std.testing.expectEqual(@as(u4, 0), len);
    }
    var freq: [25]u32 = @splat(0);
    freq[9] = 1;
    try std.testing.expect(tree.build(&freq, 15));
    try std.testing.expectEqual(@as(u4, 1), tree.lens[9]);
    try std.testing.expectEqual(@as(u16, 0), tree.codes[9]);
}

test "[edge] - [deflate encoder]: position rebasing preserves sentinels and every vector tail" {
    const values = [_]u16{ 0, 1, 32767, 32768, 32769, 65534, 65535 };
    var positions: [65]u16 = undefined;
    for (0..positions.len + 1) |n| {
        for (&positions, 0..) |*p, i| p.* = values[i % values.len];
        rebase(positions[0..n]);
        for (positions, 0..) |p, i| {
            const original = values[i % values.len];
            const expected = if (i >= n) original else if (original <= 32768) 0 else original - 32768;
            try std.testing.expectEqual(expected, p);
        }
    }
}

test "[property] - [deflate encoder]: output does not depend on stale chain entries" {
    // Repeats make long chains; more than two windows exercise rebasing.
    var input: [3 * RING + 1234]u8 = undefined;
    var state: u32 = 0x9e3779b9;
    for (&input, 0..) |*byte, i| {
        state = state *% 1664525 +% 1013904223;
        byte.* = if (i % 97 < 60) "ACGTNACGGT"[(state >> 24) % 10] else @truncate(state >> 16);
    }
    const clean = try std.testing.allocator.create(Encoder);
    defer std.testing.allocator.destroy(clean);
    const stale = try std.testing.allocator.create(Encoder);
    defer std.testing.allocator.destroy(stale);
    var expected: [4 * RING]u8 = undefined;
    var actual: [4 * RING]u8 = undefined;
    const NoCheck = struct {
        fn update(_: *@This(), _: []const u8) void {}
    };
    for ([_]Level{ .fast, .balanced, .dense }) |level| {
        @memset(&clean.head, 0);
        @memset(&clean.previous, 0);
        for (&stale.head, 0..) |*slot, i| slot.* = @truncate(i *% 2654435761 +% 99);
        for (&stale.previous, 0..) |*slot, i| slot.* = @truncate(i *% 40503 +% 17);
        // Two streams in a row on each workspace: the second starts with the first one's chains.
        for ([_]usize{ input.len, RING / 3 }) |len| {
            var want_reader = std.Io.Reader.fixed(input[0..len]);
            var want_writer = std.Io.Writer.fixed(&expected);
            var want_check: NoCheck = .{};
            _ = try clean.encodeStream(NoCheck, &want_reader, &want_writer, &want_check, level);
            var got_reader = std.Io.Reader.fixed(input[0..len]);
            var got_writer = std.Io.Writer.fixed(&actual);
            var got_check: NoCheck = .{};
            _ = try stale.encodeStream(NoCheck, &got_reader, &got_writer, &got_check, level);
            try std.testing.expectEqualSlices(u8, want_writer.buffered(), got_writer.buffered());
        }
    }
}

test "[property] - [deflate encoder]: bit output matches scalar packing at writer limits" {
    for (0..8) |tail| {
        const count = 129 + tail;
        var expected: [256]u8 = @splat(0);
        var bit: usize = 0;
        for (0..count) |i| {
            const width: u5 = @intCast(i % 17);
            const value = (@as(u32, 0xb17acced) *% @as(u32, @intCast(i + 1))) & ((@as(u32, 1) << width) - 1);
            for (0..width) |j| {
                expected[bit / 8] |= @as(u8, @intCast((value >> @intCast(j)) & 1)) << @intCast(bit % 8);
                bit += 1;
            }
        }
        const bytes = (bit + 7) / 8;
        for (0..10) |extra| {
            const capacity = bytes - 1 + extra;
            var storage: [288]u8 = @splat(0xa5);
            var writer = std.Io.Writer.fixed(storage[8..][0..capacity]);
            var bits: BitWriter = .{ .writer = &writer };
            var failed = false;
            for (0..count) |i| {
                const width: u5 = @intCast(i % 17);
                const value = (@as(u32, 0xb17acced) *% @as(u32, @intCast(i + 1))) & ((@as(u32, 1) << width) - 1);
                bits.put(value, width) catch {
                    failed = true;
                    break;
                };
            }
            if (!failed) bits.alignByte() catch {
                failed = true;
            };
            try std.testing.expectEqual(capacity < bytes, failed);
            try std.testing.expectEqualSlices(u8, expected[0..writer.end], writer.buffered());
            if (!failed) try std.testing.expectEqual(bytes, writer.end);
            try std.testing.expectEqualSlices(u8, &(@as([8]u8, @splat(0xa5))), storage[0..8]);
            for (storage[8 + capacity ..]) |value| try std.testing.expectEqual(@as(u8, 0xa5), value);
        }
    }
}
