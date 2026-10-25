//! DEFLATE decoding (RFC 1951) into bounded output storage that pauses when full. The owner gives a `Session` its
//! tables and its storage, reads `storage[0..out_pos]`, then `rebase` keeps the unread bytes and 32 KiB of history
//! (`rebaseKeeping` any amount, such as none between independent BGZF blocks);
//! bits, block state, and a match cut short by full storage carry over to the next `run`, and new bytes are in the
//! check when `run` returns. Table entries, the table builder, and the decode loops follow libdeflate's decoder
//! (MIT; its notice is in `LICENSE`): an 11-bit literal/length root and an 8-bit distance root with subtables.

const std = @import("std");
const copy = @import("../kernel/copy.zig");
const codes = @import("codes.zig");
const encode = @import("encode.zig");

const CLEN_ORDER = codes.CLEN_ORDER;
const LEN_EXTRA = codes.LEN_EXTRA;
const DIST_EXTRA = codes.DIST_EXTRA;
const LEN_BASE = codes.LEN_BASE;
const DIST_BASE = codes.DIST_BASE;
const WINDOW = codes.WINDOW;
const FIXED_LIT_LENS = codes.FIXED_LIT_LENS;
const FIXED_DIST_LENS = codes.FIXED_DIST_LENS;
const bitReverse = codes.bitReverse;
const buildCodes = codes.buildCodes;

pub const DataError = error{ Truncated, BadHuffman, BadSymbol, BadDistance, BadStored, BadBlock, OutputLimitExceeded };

pub const DecodeError = DataError || error{ReadFailed};

const Kind = enum(u4) { invalid = 0, lit, eob, len, dist, long };

const Entry = packed struct(u32) {
    nbits: u8,
    kind: Kind,
    extra: u4 = 0,
    payload: u16,
};

const LIT_TABLEBITS = 11;
const DIST_TABLEBITS = 8;
const LIT_ENOUGH = 2342;
const DIST_ENOUGH = 402;

const LITERAL: u32 = 0x8000_0000;
const EXCEPTIONAL: u32 = 0x8000;
const SUBTABLE: u32 = 0x4000;
const END_OF_BLOCK: u32 = 0x2000;
const RESERVED: u32 = 0x1000;
const UNUSED: u32 = EXCEPTIONAL | RESERVED;

const lit_results: [288]u32 = blk: {
    var r: [288]u32 = undefined;
    for (0..256) |s| r[s] = LITERAL | (@as(u32, s) << 16);
    r[256] = EXCEPTIONAL | END_OF_BLOCK;
    for (0..29) |k| r[257 + k] = (@as(u32, LEN_BASE[k]) << 16) | LEN_EXTRA[k];
    r[286] = UNUSED;
    r[287] = UNUSED;
    break :blk r;
};

const dist_results: [32]u32 = blk: {
    var r: [32]u32 = undefined;
    for (0..30) |k| r[k] = (@as(u32, DIST_BASE[k]) << 16) | DIST_EXTRA[k];
    r[30] = UNUSED;
    r[31] = UNUSED;
    break :blk r;
};

const Huff = struct { lit: [*]const u32, dist: [*]const u32, lit_mask: u64 };

const FixedTables = struct {
    lit: [1 << 9]u32,
    dist: [1 << DIST_TABLEBITS]u32,
};

const FIXED_TABLES: FixedTables = fixedTables();

fn fixedTables() FixedTables {
    @setEvalBranchQuota(1000000);
    var tables: FixedTables = undefined;
    const lit_bits = buildTable(&tables.lit, &FIXED_LIT_LENS, &lit_results, 9, true) catch |err| @compileError(@errorName(err));
    std.debug.assert(lit_bits == 9);
    _ = buildTable(&tables.dist, &FIXED_DIST_LENS, &dist_results, DIST_TABLEBITS, false) catch |err| @compileError(@errorName(err));
    return tables;
}

const FIXED_HUFF: Huff = .{ .lit = &FIXED_TABLES.lit, .dist = &FIXED_TABLES.dist, .lit_mask = (1 << 9) - 1 };

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

    pub fn refill(self: *BitReader, minimum: usize) !bool {
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

    pub fn consumed(self: *const BitReader) u64 {
        return self.tossed + self.i - self.nbits / 8;
    }

    fn need(self: *BitReader, n: u32) !void {
        try self.fill(n);
        if (self.nbits < n) return error.Truncated;
    }

    fn fill(self: *BitReader, n: u32) !void {
        while (self.nbits < n) {
            if (self.i >= self.src.len) {
                _ = try self.refill(8);
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

    fn putBack(self: *BitReader) void {
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
        if (n > self.src.len - self.i and !try self.refill(n)) return error.Truncated;
        const s = self.src[self.i .. self.i + n];
        self.i += n;
        return s;
    }
};

const BATCH = 131072;

pub const FAST_ROOM = 2 + 258 + 5 * 8 - 1;

const FAST_READ = (63 + 2 * LIT_TABLEBITS + 20 + 28 + 7) / 8 + 8;

pub const Tables = struct {
    lit: [LIT_ENOUGH]u32,
    dist: [DIST_ENOUGH]u32,
    lit_bits: u32,
};

pub const Decoder = struct {
    tables: Tables = undefined,
    buffer: [WINDOW + BATCH]u8 = undefined,
};

comptime {
    std.debug.assert(@sizeOf(Decoder) == 174820);
}

pub const Stop = enum { end, full };

const Block = enum { header, stored, fixed, dynamic, end };

pub fn Session(comptime Check: type) type {
    return struct {
        const Self = @This();

        tables: *Tables,
        storage: []u8,
        br: *BitReader = undefined,
        check: *Check = undefined,
        out: []u8 = &.{},
        out_pos: usize = 0,
        base: u64 = 0,
        check_pos: usize = 0,
        stream_start: u64 = 0,
        max_output_bytes: u64,
        max_stream_bytes: u64 = std.math.maxInt(u64),
        block: Block = .end,
        final: bool = false,
        stored_left: usize = 0,
        match_distance: usize = 0,
        match_left: usize = 0,

        pub fn begin(self: *Self, br: *BitReader, check: *Check) void {
            self.br = br;
            self.check = check;
            self.stream_start = self.position();
            self.check_pos = self.out_pos;
            self.block = .header;
            self.final = false;
            self.match_left = 0;
            self.limit();
        }

        pub fn run(self: *Self) DecodeError!Stop {
            const stop = try self.decode();
            self.catchup();
            if (stop == .full) self.br.putBack();
            return stop;
        }

        pub fn rebase(self: *Self, keep_from: usize) usize {
            return self.rebaseKeeping(keep_from, WINDOW);
        }

        pub fn rebaseKeeping(self: *Self, keep_from: usize, history: usize) usize {
            const from = @min(keep_from, self.out_pos -| history);
            if (from != 0) {
                const kept = self.out_pos - from;
                @memmove(self.storage[0..kept], self.storage[from..self.out_pos]);
                self.base += from;
                self.out_pos = kept;
                self.check_pos -= from;
            }
            self.limit();
            return from;
        }

        pub fn position(self: *const Self) u64 {
            return self.base + self.out_pos;
        }

        fn limit(self: *Self) void {
            const at = self.position();
            const allowed = @min(self.max_output_bytes - at, (self.stream_start +| self.max_stream_bytes) - at);
            const room = self.storage.len - self.out_pos;
            self.out = self.storage[0 .. self.out_pos + @as(usize, @intCast(@min(room, allowed)))];
        }

        fn full(self: *const Self) DecodeError!Stop {
            if (self.out.len < self.storage.len) return error.OutputLimitExceeded;
            return .full;
        }

        fn decode(self: *Self) DecodeError!Stop {
            const br = self.br;
            if (self.match_left != 0 and !self.copyMatch()) return self.full();
            while (true) switch (self.block) {
                .header => {
                    if (self.final) {
                        self.block = .end;
                        return .end;
                    }
                    self.final = try br.get(1) != 0;
                    switch (try br.get(2)) {
                        0 => {
                            br.alignByte();
                            const len = try br.get(16);
                            const nlen = try br.get(16);
                            if (len != (~nlen & 0xffff)) return error.BadStored;
                            self.stored_left = len;
                            self.block = .stored;
                        },
                        1 => self.block = .fixed,
                        2 => {
                            try self.readTables();
                            self.block = .dynamic;
                        },
                        else => return error.BadBlock,
                    }
                },
                .stored => {
                    while (self.stored_left != 0) {
                        if (br.i == br.src.len and !try br.refill(1)) return error.Truncated;
                        if (self.out_pos == self.out.len) return self.full();
                        const n = @min(self.stored_left, br.src.len - br.i, self.out.len - self.out_pos);
                        self.put(try br.getBytes(n));
                        self.stored_left -= n;
                    }
                    self.block = .header;
                },
                .fixed => switch (try decodeHuff(Check, self, FIXED_HUFF)) {
                    .end => self.block = .header,
                    .full => return self.full(),
                },
                .dynamic => switch (try decodeHuff(Check, self, .{ .lit = &self.tables.lit, .dist = &self.tables.dist, .lit_mask = (@as(u64, 1) << @intCast(self.tables.lit_bits)) - 1 })) {
                    .end => self.block = .header,
                    .full => return self.full(),
                },
                .end => return .end,
            };
        }

        fn readTables(self: *Self) DecodeError!void {
            const br = self.br;
            const hlit = try br.get(5) + 257;
            const hdist = try br.get(5) + 1;
            const hclen = try br.get(4) + 4;
            if (hlit > 286 or hdist > 30 or hclen > 19) return error.BadHuffman;
            var clens: [19]u4 = .{0} ** 19;
            var ci: u32 = 0;
            while (ci < hclen) : (ci += 1) {
                clens[CLEN_ORDER[ci]] = @intCast(try br.get(3));
            }
            var clen_first: [1 << 7]Entry = undefined;
            try fillFirst(clen_first[0..], 7, clens[0..19]);
            var lens: [318]u4 = undefined;
            const total_lens: usize = hlit + hdist;
            try readDynLens(br, clen_first[0..], lens[0..total_lens]);
            if (lens[256] == 0) return error.BadHuffman;
            self.tables.lit_bits = try buildTable(&self.tables.lit, lens[0..hlit], &lit_results, LIT_TABLEBITS, true);
            _ = try buildTable(&self.tables.dist, lens[hlit..total_lens], &dist_results, DIST_TABLEBITS, false);
        }

        fn catchup(self: *Self) void {
            if (self.check_pos >= self.out_pos) return;
            self.check.update(self.out[self.check_pos..self.out_pos]);
            self.check_pos = self.out_pos;
        }

        fn put(self: *Self, bytes: []const u8) void {
            const dest = self.out[self.out_pos..][0..bytes.len];
            if (comptime @hasDecl(Check, "copyUpdate")) {
                self.catchup();
                self.check.copyUpdate(bytes, dest);
                self.out_pos += bytes.len;
                self.check_pos = self.out_pos;
            } else {
                @memcpy(dest, bytes);
                self.out_pos += bytes.len;
            }
        }

        fn startMatch(self: *Self, distance: usize, length: usize) DecodeError!bool {
            if (distance == 0 or distance > WINDOW or distance > self.position() - self.stream_start) return error.BadDistance;
            self.match_distance = distance;
            self.match_left = length;
            return self.copyMatch();
        }

        fn copyMatch(self: *Self) bool {
            const n = @min(self.match_left, self.out.len - self.out_pos);
            if (self.match_distance == 1) {
                copy.dist1Broadcast32(self.out[self.out_pos..][0..n], self.out[self.out_pos - 1]);
            } else {
                copy.matchVec16(self.out, self.out_pos, self.match_distance, n);
            }
            self.out_pos += n;
            self.match_left -= n;
            return self.match_left == 0;
        }
    };
}

fn fillFirst(table: []Entry, width: u4, lens: []const u4) !void {
    const table_len: usize = @as(usize, 1) << width;
    if (table.len != table_len) return error.BadHuffman;
    @memset(table, .{ .nbits = 0, .kind = .invalid, .payload = 0 });
    var assigned: [288]u16 = undefined;
    try buildCodes(lens, assigned[0..lens.len], .codes);
    const mask: u16 = @intCast(table_len - 1);
    for (lens, 0..) |len, s| {
        if (len == 0) continue;
        const rev = bitReverse(assigned[s], len);
        if (len <= width) {
            const entry = Entry{ .nbits = len, .kind = .lit, .payload = @intCast(s) };
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

fn buildTable(table: []u32, lens: []const u4, results: []const u32, max_table_bits: u32, comptime shrink: bool) error{BadHuffman}!u32 {
    var counts: [16]u32 = @splat(0);
    for (lens) |len| counts[len] += 1;
    var max_len: u32 = 15;
    while (max_len > 1 and counts[max_len] == 0) max_len -= 1;
    const table_bits = if (shrink) @min(max_table_bits, max_len) else max_table_bits;
    var offsets: [16]u32 = undefined;
    offsets[0] = 0;
    offsets[1] = counts[0];
    var used: u32 = 0;
    var len: u32 = 1;
    while (len < max_len) : (len += 1) {
        offsets[len + 1] = offsets[len] + counts[len];
        used = (used << 1) + counts[len];
    }
    used = (used << 1) + counts[len];
    if (used > (@as(u32, 1) << @intCast(max_len))) return error.BadHuffman;
    var sorted_buf: [288]u16 = undefined;
    for (lens, 0..) |l, symbol| {
        sorted_buf[offsets[l]] = @intCast(symbol);
        offsets[l] += 1;
    }
    var sorted: []const u16 = sorted_buf[counts[0]..];
    const size = @as(usize, 1) << @intCast(table_bits);
    if (used < (@as(u32, 1) << @intCast(max_len))) {
        if (used == 0) {
            @memset(table[0..size], UNUSED);
            return table_bits;
        }
        if (used != (@as(u32, 1) << @intCast(max_len - 1)) or counts[1] != 1) return error.BadHuffman;
        const entry = results[sorted[0]] + (1 << 8) + 1;
        var k: usize = 0;
        while (k < size) : (k += 2) {
            table[k] = entry;
            table[k + 1] = UNUSED;
        }
        return table_bits;
    }
    var codeword: u32 = 0;
    len = 1;
    var count = counts[len];
    while (count == 0) {
        len += 1;
        count = counts[len];
    }
    var end: u32 = @as(u32, 1) << @intCast(len);
    while (len <= table_bits) {
        while (true) {
            table[codeword] = results[sorted[0]] + (len << 8) + len;
            sorted = sorted[1..];
            if (codeword == end - 1) {
                while (len < table_bits) : (len += 1) {
                    @memcpy(table[end..][0..end], table[0..end]);
                    end <<= 1;
                }
                return table_bits;
            }
            const bit = @as(u32, 1) << @intCast(31 - @clz(codeword ^ (end - 1)));
            codeword = (codeword & (bit - 1)) | bit;
            count -= 1;
            if (count == 0) break;
        }
        while (true) {
            len += 1;
            if (len <= table_bits) {
                @memcpy(table[end..][0..end], table[0..end]);
                end <<= 1;
            }
            count = counts[len];
            if (count != 0) break;
        }
    }
    const root_mask = (@as(u32, 1) << @intCast(table_bits)) - 1;
    end = @as(u32, 1) << @intCast(table_bits);
    var prefix: u32 = std.math.maxInt(u32);
    var start: u32 = 0;
    while (true) {
        if (codeword & root_mask != prefix) {
            prefix = codeword & root_mask;
            start = end;
            var sub_bits = len - table_bits;
            var space = count;
            while (space < (@as(u32, 1) << @intCast(sub_bits))) {
                sub_bits += 1;
                space = (space << 1) + counts[table_bits + sub_bits];
            }
            end = start + (@as(u32, 1) << @intCast(sub_bits));
            if (end > table.len) return error.BadHuffman;
            table[prefix] = (start << 16) | EXCEPTIONAL | SUBTABLE | (sub_bits << 8) | table_bits;
        }
        const entry = results[sorted[0]] + ((len - table_bits) << 8) + (len - table_bits);
        sorted = sorted[1..];
        const stride = @as(u32, 1) << @intCast(len - table_bits);
        var k = start + (codeword >> @intCast(table_bits));
        while (k < end) : (k += stride) table[k] = entry;
        if (codeword == (@as(u32, 1) << @intCast(len)) - 1) return table_bits;
        const bit = @as(u32, 1) << @intCast(31 - @clz(codeword ^ ((@as(u32, 1) << @intCast(len)) - 1)));
        codeword = (codeword & (bit - 1)) | bit;
        count -= 1;
        while (count == 0) {
            len += 1;
            count = counts[len];
        }
    }
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
    var prev: u4 = 0;
    var i = try @call(.never_inline, readDynLensFast, .{ br, clen_tab, out, &prev });
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

fn readDynLensFast(br: *BitReader, clen_tab: []const Entry, out: []u4, prev: *u4) DecodeError!usize {
    const src = br.src;
    var bits = br.bits;
    var count = br.nbits;
    var at = br.i;
    var i: usize = 0;
    defer {
        br.bits = if (count < 64) bits & ((@as(u64, 1) << @intCast(count)) - 1) else bits;
        br.nbits = count;
        br.i = at;
    }
    while (i < out.len and src.len - at >= 8) {
        if (count < 56) {
            bits |= std.mem.readInt(u64, src[at..][0..8], .little) << @intCast(count);
            at += (63 - count) >> 3;
            count |= 56;
        }
        const e = clen_tab[@intCast(bits & ((1 << 7) - 1))];
        if (e.kind == .invalid or e.kind == .long) return error.BadHuffman;
        bits >>= @intCast(e.nbits);
        count -= e.nbits;
        if (e.payload <= 15) {
            out[i] = @intCast(e.payload);
            prev.* = @intCast(e.payload);
            i += 1;
            continue;
        }
        if (e.payload == 16 and i == 0) return error.BadHuffman;
        const extra: u5, const base: usize, const value: u4 = switch (e.payload) {
            16 => .{ 2, 3, prev.* },
            17 => .{ 3, 3, 0 },
            18 => .{ 7, 11, 0 },
            else => return error.BadHuffman,
        };
        const n = base + @as(usize, @intCast(bits & ((@as(u64, 1) << extra) - 1)));
        bits >>= extra;
        count -= extra;
        const fits = @min(n, out.len - i);
        @memset(out[i..][0..fits], value);
        i += fits;
        if (fits < n) return error.BadHuffman;
        prev.* = value;
    }
    return i;
}

inline fn varbits(word: u64, count: u32) u64 {
    return word & ((@as(u64, 1) << @as(u6, @truncate(count))) - 1);
}

inline fn subtableEntry(table: [*]const u32, entry: u32, bits: u64) u32 {
    return table[(entry >> 16) + @as(u32, @intCast(varbits(bits, (entry >> 8) & 0x3f)))];
}

fn decodeFast(comptime Check: type, ctx: *Session(Check), h: Huff) DecodeError!bool {
    if (ctx.position() - ctx.stream_start >= WINDOW) return decodeFastImpl(Check, ctx, h, true);
    return decodeFastImpl(Check, ctx, h, false);
}

fn decodeFastImpl(comptime Check: type, ctx: *Session(Check), h: Huff, comptime full_history: bool) DecodeError!bool {
    const br = ctx.br;
    const output = ctx.out;
    const input = br.src;
    if (output.len - ctx.out_pos < FAST_ROOM or input.len - br.i < FAST_READ or br.nbits >= 64) return false;
    var bitbuf = br.bits;
    var bitsleft: u32 = br.nbits;
    var in: [*]const u8 = input.ptr + br.i;
    const in_stop: [*]const u8 = input.ptr + (input.len - FAST_READ);
    var out: [*]u8 = output.ptr + ctx.out_pos;
    const out_start = out;
    const out_stop: [*]u8 = output.ptr + (output.len - FAST_ROOM);
    const history = ctx.position() - ctx.stream_start;
    const lit = h.lit;
    const dist = h.dist;
    const mask = h.lit_mask;
    defer {
        br.bits = bitbuf;
        br.nbits = bitsleft & 0xff;
        br.i = @intFromPtr(in) - @intFromPtr(input.ptr);
        ctx.out_pos = @intFromPtr(out) - @intFromPtr(output.ptr);
    }
    bitbuf |= std.mem.readInt(u64, in[0..8], .little) << @as(u6, @truncate(bitsleft));
    in += 7 - ((bitsleft >> 3) & 7);
    bitsleft |= 56;
    var entry = lit[@intCast(bitbuf & mask)];
    while (@intFromPtr(in) <= @intFromPtr(in_stop) and @intFromPtr(out) <= @intFromPtr(out_stop)) {
        var saved = bitbuf;
        bitbuf >>= @as(u6, @truncate(entry));
        bitsleft -%= entry;
        if (entry & LITERAL != 0) {
            var byte: u8 = @truncate(entry >> 16);
            entry = lit[@intCast(bitbuf & mask)];
            saved = bitbuf;
            bitbuf >>= @as(u6, @truncate(entry));
            bitsleft -%= entry;
            out[0] = byte;
            out += 1;
            if (entry & LITERAL != 0) {
                byte = @truncate(entry >> 16);
                entry = lit[@intCast(bitbuf & mask)];
                saved = bitbuf;
                bitbuf >>= @as(u6, @truncate(entry));
                bitsleft -%= entry;
                out[0] = byte;
                out += 1;
                if (entry & LITERAL != 0) {
                    byte = @truncate(entry >> 16);
                    entry = lit[@intCast(bitbuf & mask)];
                    bitbuf |= std.mem.readInt(u64, in[0..8], .little) << @as(u6, @truncate(bitsleft));
                    in += 7 - ((bitsleft >> 3) & 7);
                    bitsleft |= 56;
                    out[0] = byte;
                    out += 1;
                    continue;
                }
            }
        }
        if (entry & EXCEPTIONAL != 0) {
            if (entry & SUBTABLE == 0) {
                if (entry & END_OF_BLOCK != 0) return true;
                return error.BadSymbol;
            }
            entry = subtableEntry(lit, entry, bitbuf);
            saved = bitbuf;
            bitbuf >>= @as(u6, @truncate(entry));
            bitsleft -%= entry;
            if (entry & LITERAL != 0) {
                const byte: u8 = @truncate(entry >> 16);
                entry = lit[@intCast(bitbuf & mask)];
                bitbuf |= std.mem.readInt(u64, in[0..8], .little) << @as(u6, @truncate(bitsleft));
                in += 7 - ((bitsleft >> 3) & 7);
                bitsleft |= 56;
                out[0] = byte;
                out += 1;
                continue;
            }
            if (entry & EXCEPTIONAL != 0) {
                if (entry & END_OF_BLOCK != 0) return true;
                return error.BadSymbol;
            }
        }
        const length: usize = (entry >> 16) + @as(u32, @intCast(varbits(saved, entry) >> @as(u6, @truncate(entry >> 8))));
        entry = dist[@intCast(bitbuf & 0xff)];
        if (entry & EXCEPTIONAL != 0) {
            if (entry & SUBTABLE == 0) return error.BadSymbol;
            if (@as(u8, @truncate(bitsleft)) < 28 + LIT_TABLEBITS - 1) {
                bitbuf |= std.mem.readInt(u64, in[0..8], .little) << @as(u6, @truncate(bitsleft));
                in += 7 - ((bitsleft >> 3) & 7);
                bitsleft |= 56;
            }
            bitbuf >>= DIST_TABLEBITS;
            bitsleft -%= DIST_TABLEBITS;
            entry = subtableEntry(dist, entry, bitbuf);
            if (entry & EXCEPTIONAL != 0) return error.BadSymbol;
        } else if (@as(u8, @truncate(bitsleft)) < 21 + LIT_TABLEBITS - 1) {
            bitbuf |= std.mem.readInt(u64, in[0..8], .little) << @as(u6, @truncate(bitsleft));
            in += 7 - ((bitsleft >> 3) & 7);
            bitsleft |= 56;
        }
        saved = bitbuf;
        bitbuf >>= @as(u6, @truncate(entry));
        bitsleft -%= entry;
        const distance: usize = (entry >> 16) + @as(u32, @intCast(varbits(saved, entry) >> @as(u6, @truncate(entry >> 8))));
        if (!full_history and distance > history + (@intFromPtr(out) - @intFromPtr(out_start))) return error.BadDistance;
        var src = out - distance;
        var dst = out;
        out += length;
        entry = lit[@intCast(bitbuf & mask)];
        bitbuf |= std.mem.readInt(u64, in[0..8], .little) << @as(u6, @truncate(bitsleft));
        in += 7 - ((bitsleft >> 3) & 7);
        bitsleft |= 56;
        if (distance >= 8) {
            inline for (0..5) |_| {
                dst[0..8].* = src[0..8].*;
                src += 8;
                dst += 8;
            }
            while (@intFromPtr(dst) < @intFromPtr(out)) {
                inline for (0..5) |_| {
                    dst[0..8].* = src[0..8].*;
                    src += 8;
                    dst += 8;
                }
            }
        } else if (distance == 1) {
            const v: @Vector(8, u8) = @splat(src[0]);
            inline for (0..4) |_| {
                dst[0..8].* = v;
                dst += 8;
            }
            while (@intFromPtr(dst) < @intFromPtr(out)) {
                inline for (0..4) |_| {
                    dst[0..8].* = v;
                    dst += 8;
                }
            }
        } else {
            inline for (0..2) |_| {
                std.mem.writeInt(u64, dst[0..8], std.mem.readInt(u64, src[0..8], .little), .little);
                src += distance;
                dst += distance;
            }
            while (true) {
                inline for (0..2) |_| {
                    std.mem.writeInt(u64, dst[0..8], std.mem.readInt(u64, src[0..8], .little), .little);
                    src += distance;
                    dst += distance;
                }
                if (@intFromPtr(dst) >= @intFromPtr(out)) break;
            }
        }
    }
    return false;
}

const Code = struct { entry: u32, bits: u32, ok: bool };

fn lookupCareful(table: [*]const u32, mask: u64, main_bits: u32, bits: u64) Code {
    var entry = table[@intCast(bits & mask)];
    var used: u32 = 0;
    if (entry & SUBTABLE != 0) {
        used = main_bits;
        entry = subtableEntry(table, entry, bits >> @as(u6, @truncate(main_bits)));
    }
    if (entry & EXCEPTIONAL != 0 and entry & END_OF_BLOCK == 0) return .{ .entry = entry, .bits = 0, .ok = false };
    return .{ .entry = entry, .bits = used + ((entry >> 8) & 0xf), .ok = true };
}

fn decodeHuff(comptime Check: type, ctx: *Session(Check), h: Huff) DecodeError!Stop {
    const br = ctx.br;
    const lit_bits: u32 = @intCast(@popCount(h.lit_mask));
    var more = true;
    while (true) {
        if (more and br.src.len - br.i < 8) {
            if (br.nbits >= 1) {
                const code = lookupCareful(h.lit, h.lit_mask, lit_bits, br.bits);
                if (code.ok and code.entry & END_OF_BLOCK != 0 and code.bits <= br.nbits) {
                    br.consume(code.bits);
                    return .end;
                }
            }
            more = try br.refill(8);
        }
        if (try @call(.never_inline, decodeFast, .{ Check, ctx, h })) return .end;
        if (try @call(.never_inline, decodeTail, .{ Check, ctx, h })) return .end;
        try br.fill(15);
        const code = lookupCareful(h.lit, h.lit_mask, lit_bits, br.bits);
        if (br.nbits < 15 and (!code.ok or code.bits > br.nbits)) return error.Truncated;
        if (!code.ok) return error.BadSymbol;
        const entry = code.entry;
        if (entry & LITERAL != 0) {
            if (ctx.out_pos == ctx.out.len) return .full;
            br.consume(code.bits);
            ctx.out[ctx.out_pos] = @truncate(entry >> 16);
            ctx.out_pos += 1;
            continue;
        }
        if (entry & END_OF_BLOCK != 0) {
            br.consume(code.bits);
            return .end;
        }
        br.consume(code.bits);
        const extra = (entry & 0xff) - ((entry >> 8) & 0xf);
        const add = if (extra != 0) try br.get(extra) else 0;
        const length: usize = (entry >> 16) + add;
        try br.fill(15);
        const d = lookupCareful(h.dist, 0xff, DIST_TABLEBITS, br.bits);
        if (br.nbits < 15 and (!d.ok or d.bits > br.nbits)) return error.Truncated;
        if (!d.ok) return error.BadSymbol;
        br.consume(d.bits);
        const dextra = (d.entry & 0xff) - ((d.entry >> 8) & 0xf);
        const dadd = if (dextra != 0) try br.get(dextra) else 0;
        if (!try ctx.startMatch((d.entry >> 16) + @as(usize, dadd), length)) return .full;
    }
}

fn decodeTail(comptime Check: type, ctx: *Session(Check), h: Huff) DecodeError!bool {
    const br = ctx.br;
    const input = br.src;
    const output = ctx.out;
    if (input.len - br.i < 8 or br.nbits >= 64) return false;
    var bitbuf = br.bits;
    var bitsleft: u32 = br.nbits;
    var in = br.i;
    var out = ctx.out_pos;
    const start = out;
    const history = ctx.position() - ctx.stream_start;
    const lit_bits: u32 = @intCast(@popCount(h.lit_mask));
    defer {
        br.bits = bitbuf;
        br.nbits = bitsleft & 0xff;
        br.i = in;
        ctx.out_pos = out;
    }
    while (out < output.len and input.len - in >= 8) {
        bitbuf |= std.mem.readInt(u64, input[in..][0..8], .little) << @as(u6, @truncate(bitsleft));
        in += 7 - ((bitsleft >> 3) & 7);
        bitsleft |= 56;
        const symbol_bits = bitbuf;
        const symbol_left = bitsleft;
        const symbol_in = in;
        const code = lookupCareful(h.lit, h.lit_mask, lit_bits, bitbuf);
        if (!code.ok) return error.BadSymbol;
        const entry = code.entry;
        if (entry & LITERAL != 0) {
            bitbuf >>= @as(u6, @truncate(code.bits));
            bitsleft -%= code.bits;
            output[out] = @truncate(entry >> 16);
            out += 1;
            continue;
        }
        if (entry & END_OF_BLOCK != 0) {
            bitbuf >>= @as(u6, @truncate(code.bits));
            bitsleft -%= code.bits;
            return true;
        }
        const extra = (entry & 0xff) - ((entry >> 8) & 0xf);
        bitbuf >>= @as(u6, @truncate(code.bits));
        bitsleft -%= code.bits;
        const length: usize = (entry >> 16) + @as(u32, @intCast(varbits(bitbuf, extra)));
        bitbuf >>= @as(u6, @truncate(extra));
        bitsleft -%= extra;
        const d = lookupCareful(h.dist, 0xff, DIST_TABLEBITS, bitbuf);
        if (!d.ok) return error.BadSymbol;
        bitbuf >>= @as(u6, @truncate(d.bits));
        bitsleft -%= d.bits;
        const dextra = (d.entry & 0xff) - ((d.entry >> 8) & 0xf);
        const distance: usize = (d.entry >> 16) + @as(u32, @intCast(varbits(bitbuf, dextra)));
        bitbuf >>= @as(u6, @truncate(dextra));
        bitsleft -%= dextra;
        if (distance > history + (out - start)) return error.BadDistance;
        if (length > output.len - out) {
            bitbuf = symbol_bits;
            bitsleft = symbol_left;
            in = symbol_in;
            return false;
        }
        if (distance >= 8 and output.len - out >= length + 40) {
            var from = out - distance;
            var to = out;
            while (to < out + length) : ({
                from += 8;
                to += 8;
            }) output[to..][0..8].* = output[from..][0..8].*;
        } else {
            for (output[out..][0..length], out - distance..) |*byte, from| byte.* = output[from];
        }
        out += length;
    }
    return false;
}

const TestCheck = struct {
    pub fn update(_: *TestCheck, _: []const u8) void {}
};

test {
    _ = copy;
    _ = codes;
}

fn resolve(table: []const u32, table_bits: u32, bits: u64) struct { entry: u32, len: u32 } {
    var entry = table[@intCast(bits & ((@as(u64, 1) << @intCast(table_bits)) - 1))];
    var used: u32 = 0;
    if (entry & SUBTABLE != 0) {
        used = table_bits;
        entry = subtableEntry(table.ptr, entry, bits >> @intCast(table_bits));
    }
    return .{ .entry = entry, .len = used + ((entry >> 8) & 0xf) };
}

fn tableUse(table: []const u32, table_bits: u32) usize {
    var used: usize = @as(usize, 1) << @intCast(table_bits);
    for (table[0..used]) |entry| {
        if (entry & SUBTABLE != 0) used = @max(used, (entry >> 16) + (@as(usize, 1) << @intCast((entry >> 8) & 0xf)));
    }
    return used;
}

fn expectCanonical(table: []const u32, table_bits: u32, lens: []const u4, results: []const u32) !void {
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
        const got = resolve(table, table_bits, bits);
        if (symbol == 65535) {
            try std.testing.expectEqual(UNUSED, got.entry);
            continue;
        }
        try std.testing.expectEqual(@as(u32, lens[symbol]), got.len);
        try std.testing.expectEqual(results[symbol] & 0xffff_f000, got.entry & 0xffff_f000);
        try std.testing.expectEqual(results[symbol] & 0x1f, (got.entry & 0xff) - ((got.entry >> 8) & 0xf));
    }
}

test "[property] - [deflate tables]: rejected trees leave the table as it was" {
    const sentinel: u32 = 0x5a5a_a5a5;
    for ([_][]const u4{ &.{ 1, 1, 1 }, &.{ 2, 2, 2 }, &.{ 1, 2, 2, 2 }, &.{2} }) |lens| {
        var table: [LIT_ENOUGH]u32 = @splat(sentinel);
        try std.testing.expectError(error.BadHuffman, buildTable(&table, lens, &lit_results, LIT_TABLEBITS, true));
        for (table) |entry| try std.testing.expectEqual(sentinel, entry);
    }
}

test "[property] - [deflate tables]: every code resolves to its canonical symbol within the table bound" {
    inline for (.{ .{ 288, LIT_TABLEBITS, LIT_ENOUGH, true }, .{ 32, DIST_TABLEBITS, DIST_ENOUGH, false } }) |c| {
        const results: []const u32 = if (c[0] == 288) &lit_results else &dist_results;
        var lens: [c[0]]u4 = @splat(0);
        var table: [c[2]]u32 = undefined;
        for (0..2) |single| {
            @memset(&lens, 0);
            lens[0] = @intCast(single);
            const bits = try buildTable(&table, &lens, results, c[1], c[3]);
            for (table[0 .. @as(usize, 1) << @intCast(bits)], 0..) |entry, prefix| {
                const want: u32 = if (single != 0 and prefix & 1 == 0) results[0] + (1 << 8) + 1 else UNUSED;
                try std.testing.expectEqual(want, entry);
            }
        }
        for (0..32) |trial| {
            @memset(&lens, 0);
            var random = std.Random.DefaultPrng.init(0x513 + trial);
            lens[0] = 1;
            lens[1] = 1;
            var count: usize = 2;
            while (count < c[0]) {
                var selected: usize = 0;
                if (trial < 2) {
                    for (lens[0..count], 0..) |len, k| {
                        if (len == 15) continue;
                        if (lens[selected] == 15 or (trial == 0 and len > lens[selected]) or (trial == 1 and len < lens[selected])) selected = k;
                    }
                } else {
                    selected = random.random().uintLessThan(usize, count);
                    while (lens[selected] == 15) selected = (selected + 1) % count;
                }
                lens[selected] += 1;
                lens[count] = lens[selected];
                count += 1;
                if (count <= 17 or count % 32 == 0 or count == c[0]) {
                    const bits = try buildTable(&table, &lens, results, c[1], c[3]);
                    try std.testing.expect(tableUse(&table, bits) <= c[2]);
                    try expectCanonical(&table, bits, &lens, results);
                }
            }
        }
    }
}

test "[property] - [deflate tables]: the deepest complete codes stay within the table bound" {
    const Case = struct { lit: bool, alphabet: usize, short: []const u4, long: []const [2]u16 };
    const cases = [_]Case{
        .{ .lit = true, .alphabet = 286, .short = &.{ 1, 2, 3, 4 }, .long = &.{ .{ 11, 1 }, .{ 12, 229 }, .{ 13, 49 }, .{ 14, 1 }, .{ 15, 2 } } },
        .{ .lit = true, .alphabet = 286, .short = &.{ 1, 2, 3, 4 }, .long = &.{ .{ 11, 1 }, .{ 12, 237 }, .{ 13, 25 }, .{ 14, 17 }, .{ 15, 2 } } },
        .{ .lit = false, .alphabet = 32, .short = &.{ 1, 2, 3, 4, 5, 6 }, .long = &.{ .{ 10, 11 }, .{ 11, 9 }, .{ 12, 1 }, .{ 14, 3 }, .{ 15, 2 } } },
        .{ .lit = false, .alphabet = 32, .short = &.{ 1, 2, 3, 4, 5, 6, 7 }, .long = &.{ .{ 10, 3 }, .{ 11, 1 }, .{ 12, 17 }, .{ 13, 1 }, .{ 14, 1 }, .{ 15, 2 } } },
    };
    inline for (cases) |c| {
        var lens: [c.alphabet]u4 = @splat(0);
        var n: usize = 0;
        for (c.short) |len| {
            lens[n] = len;
            n += 1;
        }
        for (c.long) |group| for (0..group[1]) |_| {
            lens[n] = @intCast(group[0]);
            n += 1;
        };
        try std.testing.expectEqual(c.alphabet, n);
        var table: [if (c.lit) LIT_ENOUGH else DIST_ENOUGH]u32 = undefined;
        const results: []const u32 = if (c.lit) &lit_results else &dist_results;
        const bits = try buildTable(&table, &lens, results, if (c.lit) LIT_TABLEBITS else DIST_TABLEBITS, c.lit);
        try std.testing.expect(tableUse(&table, bits) <= table.len);
        try expectCanonical(&table, bits, &lens, results);
    }
}

test "[edge] - [deflate decoder]: decoded counters stop at the u64 output bound" {
    const decoder = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(decoder);
    var reader = std.Io.Reader.fixed("");
    var br: BitReader = .{ .reader = &reader };
    var check: TestCheck = .{};
    var ctx: Session(TestCheck) = .{
        .tables = &decoder.tables,
        .storage = &decoder.buffer,
        .base = std.math.maxInt(u64) - 1,
        .max_output_bytes = std.math.maxInt(u64),
    };
    ctx.begin(&br, &check);
    try std.testing.expectEqual(@as(usize, 1), ctx.out.len);
    ctx.put("A");
    try std.testing.expectEqual(std.math.maxInt(u64), ctx.position());
    _ = ctx.rebase(ctx.out_pos);
    try std.testing.expectEqual(std.math.maxInt(u64), ctx.position());
    try std.testing.expectError(error.OutputLimitExceeded, ctx.full());
}

const SumCheck = struct {
    bytes: u64 = 0,
    sum: u64 = 0,

    fn update(self: *SumCheck, data: []const u8) void {
        self.bytes += data.len;
        for (data, 0..) |b, i| self.sum +%= @as(u64, b) *% (self.bytes - data.len + i + 1);
    }
};

fn pumpSession(session: *Session(SumCheck), size: usize, expected: []const u8) !void {
    var seek: usize = 0;
    var got: usize = 0;
    var stop = try session.run();
    while (true) {
        if (seek == session.out_pos) {
            if (stop == .end) break;
            seek -= session.rebase(seek);
            stop = try session.run();
            continue;
        }
        const n = @min(size, session.out_pos - seek);
        try std.testing.expectEqualSlices(u8, expected[got..][0..n], session.storage[seek..][0..n]);
        got += n;
        seek += n;
        if (stop == .full and seek < session.out_pos) {
            seek -= session.rebase(seek);
            stop = try session.run();
        }
    }
    try std.testing.expectEqual(expected.len, got);
}

test "[property] - [deflate decoder]: paused decoding returns the stream at every read size" {
    const allocator = std.testing.allocator;
    const decoder = try allocator.create(Decoder);
    defer allocator.destroy(decoder);
    const encoder = try allocator.create(encode.Encoder);
    defer allocator.destroy(encoder);
    const plain = try allocator.alloc(u8, 420_000);
    defer allocator.free(plain);
    var random = std.Random.DefaultPrng.init(41);
    for (plain, 0..) |*b, i| b.* = switch ((i / 50_000) % 3) {
        0 => "ACGTTGCA\n"[(i * i / 3 + i / 11) % 9],
        1 => @truncate(i / 700),
        else => random.random().int(u8),
    };
    var expected: SumCheck = .{};
    expected.update(plain);
    const compressed = try allocator.alloc(u8, plain.len + plain.len / 8 + 1024);
    defer allocator.free(compressed);
    for ([_]encode.Preset{ .fast, .even, .dense }) |preset| {
        var writer = std.Io.Writer.fixed(compressed);
        var encode_check: TestCheck = .{};
        try encoder.encodeSlice(TestCheck, plain, &writer, &encode_check, preset, false);
        for ([_]usize{ 1, 7, 4093, 65536, 1 << 20 }) |size| {
            if (size == 1 and preset != .even) continue;
            var reader = std.Io.Reader.fixed(writer.buffered());
            var br: BitReader = .{ .reader = &reader };
            var check: SumCheck = .{};
            var session: Session(SumCheck) = .{ .tables = &decoder.tables, .storage = &decoder.buffer, .max_output_bytes = std.math.maxInt(u64) };
            session.begin(&br, &check);
            try pumpSession(&session, size, plain);
            try std.testing.expectEqual(@as(u64, plain.len), session.position());
            try std.testing.expectEqual(expected, check);
        }
        for ([_]u64{ plain.len, plain.len - 1 }) |max| {
            var reader = std.Io.Reader.fixed(writer.buffered());
            var br: BitReader = .{ .reader = &reader };
            var check: SumCheck = .{};
            var session: Session(SumCheck) = .{ .tables = &decoder.tables, .storage = &decoder.buffer, .max_output_bytes = max };
            session.begin(&br, &check);
            if (max == plain.len) {
                try pumpSession(&session, 65536, plain);
            } else {
                try std.testing.expectError(error.OutputLimitExceeded, pumpSession(&session, 65536, plain));
            }
        }
    }
}

test "[edge] - [deflate decoder]: streams whose last code ends at the end of input decode" {
    const decoder = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(decoder);
    const encoder = try std.testing.allocator.create(encode.Encoder);
    defer std.testing.allocator.destroy(encoder);
    var plain: [3000]u8 = undefined;
    for (&plain, 0..) |*b, i| b.* = "ACGT"[(i * i + i / 7) % 4];
    var dynamic: [4000]u8 = undefined;
    var dynamic_writer = std.Io.Writer.fixed(&dynamic);
    var encode_check: TestCheck = .{};
    try encoder.encodeSlice(TestCheck, &plain, &dynamic_writer, &encode_check, .even, false);
    const cases = .{ .{ "\x73\x04\x00", "A" }, .{ dynamic_writer.buffered(), &plain } };
    inline for (cases) |case| {
        var reader = std.Io.Reader.fixed(case[0]);
        var br: BitReader = .{ .reader = &reader };
        var check: TestCheck = .{};
        var session: Session(TestCheck) = .{ .tables = &decoder.tables, .storage = &decoder.buffer, .max_output_bytes = std.math.maxInt(u64) };
        session.begin(&br, &check);
        try std.testing.expectEqual(Stop.end, try session.run());
        try std.testing.expectEqualSlices(u8, case[1], decoder.buffer[0..session.out_pos]);
    }
}

test "[property] - [deflate decoder]: fast literals consume exact bits within output room" {
    const decoder = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(decoder);
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
        for ([_]usize{ 0, 1, 2, FAST_ROOM - 2, FAST_ROOM - 1, FAST_ROOM, FAST_ROOM + 1, FAST_ROOM + 2, 330, 363 }) |room| {
            @memset(decoder.buffer[WINDOW..][0..400], 0xa5);
            var reader = std.Io.Reader.fixed(&input);
            var br: BitReader = .{ .reader = &reader, .src = &input };
            var check: TestCheck = .{};
            var ctx: Session(TestCheck) = .{
                .br = &br,
                .check = &check,
                .tables = &decoder.tables,
                .storage = &decoder.buffer,
                .out = decoder.buffer[0 .. WINDOW + room],
                .out_pos = WINDOW,
                .max_output_bytes = std.math.maxInt(u64),
            };
            const ended = try decodeFastImpl(TestCheck, &ctx, FIXED_HUFF, false);
            const written = ctx.out_pos - WINDOW;
            try std.testing.expect(written <= length and written <= room);
            if (ended) try std.testing.expectEqual(length, written);
            try std.testing.expectEqual(ends[if (ended) length + 1 else written], br.i * 8 - br.nbits);
            try std.testing.expectEqualSlices(u8, plain[0..written], decoder.buffer[WINDOW..][0..written]);
            for (decoder.buffer[ctx.out_pos .. WINDOW + 400]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
        }
    }
}

test "[edge] - [deflate decoder]: lookahead retains unread bits after a maximum-width match" {
    const decoder = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(decoder);
    const tables = &decoder.tables;
    @memset(&tables.lit, UNUSED);
    @memset(&tables.dist, UNUSED);
    tables.lit[0] = (2048 << 16) | EXCEPTIONAL | SUBTABLE | (4 << 8) | LIT_TABLEBITS;
    tables.lit[2048] = lit_results[284] + (4 << 8) + 4;
    tables.dist[0] = (256 << 16) | EXCEPTIONAL | SUBTABLE | (7 << 8) | DIST_TABLEBITS;
    tables.dist[256] = dist_results[29] + (7 << 8) + 7;
    var k: usize = 1;
    while (k < 2048) : (k += 2) tables.lit[k] = lit_results[256] + (1 << 8) + 1;
    for (decoder.buffer[0..WINDOW], 0..) |*byte, i| byte.* = @truncate(i * 73 + i / 256);
    const h: Huff = .{ .lit = &tables.lit, .dist = &tables.dist, .lit_mask = 2047 };
    for ([_]u32{ 10, 11 }) |literal_width| {
        const literal = lit_results['A'] + (literal_width << 8) + literal_width;
        tables.lit[512] = if (literal_width == 10) literal else UNUSED;
        tables.lit[1536] = literal;
        const literal_code: u64 = if (literal_width == 10) 512 else 1536;
        const consumed: usize = 48 + @as(usize, literal_width) + 1;
        var input: [64]u8 = @splat(0);
        const token_bits: u64 = (@as(u64, 31) << 15) | (@as(u64, 8191) << 35);
        std.mem.writeInt(u64, input[0..8], token_bits | (literal_code << 48) | (@as(u64, 1) << @intCast(consumed - 1)), .little);
        var reader = std.Io.Reader.fixed(&input);
        var br: BitReader = .{ .reader = &reader, .src = &input };
        var check: TestCheck = .{};
        var ctx: Session(TestCheck) = .{
            .br = &br,
            .check = &check,
            .tables = tables,
            .storage = &decoder.buffer,
            .out = &decoder.buffer,
            .out_pos = WINDOW,
            .max_output_bytes = std.math.maxInt(u64),
        };
        try std.testing.expect(try decodeFastImpl(TestCheck, &ctx, h, true));
        try std.testing.expectEqual(WINDOW + 259, ctx.out_pos);
        try std.testing.expectEqual(consumed, br.i * 8 - br.nbits);
        try std.testing.expectEqualSlices(u8, decoder.buffer[0..258], decoder.buffer[WINDOW..][0..258]);
        try std.testing.expectEqual(@as(u8, 'A'), decoder.buffer[WINDOW + 258]);
    }
}
