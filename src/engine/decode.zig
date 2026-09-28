//! DEFLATE decoding (RFC 1951): the bit reader, Huffman decode tables, and a session that decodes into a bounded
//! buffer of history plus batch and pauses when the buffer is full.

const std = @import("std");
const copy = @import("../kernel/copy.zig");
const codes = @import("codes.zig");
// Tests only: they make DEFLATE streams to decode.
const encode = @import("encode.zig");

const CLEN_ORDER = codes.CLEN_ORDER;
const LEN_EXTRA = codes.LEN_EXTRA;
const DIST_EXTRA = codes.DIST_EXTRA;
const LEN_BASE = codes.LEN_BASE;
const DIST_BASE = codes.DIST_BASE;
const RING = codes.RING;
const FIXED_LIT_LENS = codes.FIXED_LIT_LENS;
const FIXED_DIST_LENS = codes.FIXED_DIST_LENS;
const bitReverse = codes.bitReverse;
const buildCodes = codes.buildCodes;

/// `PeekTooLarge`: a reader was asked to hold more than its buffer allows (at most 128 KiB is always possible).
pub const Error = error{ Truncated, BadHuffman, BadSymbol, BadDistance, BadStored, BadBlock, OutputLimitExceeded, ReadFailed, WriteFailed, PeekTooLarge };

pub const TrailingData = enum { reject, leave };

pub const DecompressOptions = struct {
    max_output_bytes: u64 = std.math.maxInt(u64),
    trailing_data: TrailingData = .reject,
};

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
};

comptime {
    std.debug.assert(@sizeOf(Decoder) == 196608);
}

/// Why `Session.run` returned: the stream's final block ended, or the buffer has no room left.
pub const Stop = enum { end, full };

const Block = enum { header, stored, fixed, dynamic, end };

/// Decodes DEFLATE streams into `Decoder.buffer`, pausing when the buffer is full. `buffer[0..out_pos]` is
/// decoded output; the owner reads it, then `rebase` keeps what is unread plus 32 KiB of history and frees
/// the rest. Bits, block state, and a match cut short by a full buffer carry over to the next `run`.
pub fn Session(comptime Check: type) type {
    return struct {
        const Self = @This();

        decoder: *Decoder,
        br: *BitReader = undefined,
        check: *Check = undefined,
        out: []u8 = &.{},
        out_pos: usize = 0,
        // Bytes decoded before `buffer[0]`: `position` is `base + out_pos`.
        base: u64 = 0,
        check_pos: usize = 0,
        stream_start: u64 = 0,
        max_output_bytes: u64,
        // Output cap for each stream (a BGZF block holds at most 65536 bytes), applied with max_output_bytes.
        stream_limit: u64 = std.math.maxInt(u64),
        block: Block = .end,
        final: bool = false,
        stored_left: usize = 0,
        match_distance: usize = 0,
        match_left: usize = 0,

        /// Starts a stream at the current position; `run` then decodes it.
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

        /// Decodes until the stream ends or the buffer is full; new bytes are in the check when it returns.
        pub fn run(self: *Self) Error!Stop {
            const stop = try self.decode();
            self.catchup();
            // A pause can come right after a 64-bit refill; the fast loop's refill needs fewer than 64 bits held.
            if (stop == .full) self.br.putBack();
            return stop;
        }

        /// Frees room: keeps `buffer[keep_from..out_pos]` and at least 32 KiB of history before `out_pos`,
        /// moved to the front. Returns how far bytes moved, which the owner subtracts from its offsets.
        pub fn rebase(self: *Self, keep_from: usize) usize {
            const from = @min(keep_from, self.out_pos -| RING);
            if (from != 0) {
                const kept = self.out_pos - from;
                @memmove(self.decoder.buffer[0..kept], self.decoder.buffer[from..self.out_pos]);
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

        // `out` ends where the output limits stop this stream, or at the end of the buffer.
        fn limit(self: *Self) void {
            const at = self.position();
            const allowed = @min(self.max_output_bytes - at, (self.stream_start +| self.stream_limit) - at);
            const room = self.decoder.buffer.len - self.out_pos;
            self.out = self.decoder.buffer[0 .. self.out_pos + @as(usize, @intCast(@min(room, allowed)))];
        }

        // No room: a limit (not the buffer's end) is what stopped decoding.
        fn full(self: *const Self) Error!Stop {
            if (self.out.len < self.decoder.buffer.len) return error.OutputLimitExceeded;
            return .full;
        }

        fn decode(self: *Self) Error!Stop {
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
                        if (self.out_pos == self.out.len) return self.full();
                        if (br.i == br.src.len and !try br.window(1)) return error.Truncated;
                        const n = @min(self.stored_left, br.src.len - br.i, self.out.len - self.out_pos);
                        self.put(try br.getBytes(n));
                        self.stored_left -= n;
                    }
                    self.block = .header;
                },
                .fixed => switch (try decodeHuff(Check, self, &FIXED_TABLES.lit, &FIXED_TABLES.dist)) {
                    .end => self.block = .header,
                    .full => return self.full(),
                },
                .dynamic => switch (try decodeHuff(Check, self, &self.decoder.tables.lit_first, &self.decoder.tables.dist_first)) {
                    .end => self.block = .header,
                    .full => return self.full(),
                },
                .end => return .end,
            };
        }

        fn readTables(self: *Self) Error!void {
            const br = self.br;
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
        }

        fn catchup(self: *Self) void {
            if (self.check_pos >= self.out_pos) return;
            self.check.update(self.out[self.check_pos..self.out_pos]);
            self.check_pos = self.out_pos;
        }

        // Stored bytes; the caller made room for all of them.
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

        fn startMatch(self: *Self, distance: usize, length: usize) Error!bool {
            if (distance == 0 or distance > RING or distance > self.position() - self.stream_start) return error.BadDistance;
            self.match_distance = distance;
            self.match_left = length;
            return self.copyMatch();
        }

        // Copies what fits of the pending match; true when none is left.
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

fn fillFirst(table: []Entry, width: u4, lens: []const u4, kind_of: *const fn (usize) Kind, payload_of: *const fn (usize) u16, comptime predecoded: bool) !void {
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
    // The refill below shifts by the bit count, which must stay under 64 (a pause puts whole bytes back).
    std.debug.assert(count < 64);
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

// `.end` at the end-of-block code; `.full` before a literal or match finds no room, or with a match pending.
fn decodeHuff(comptime Check: type, ctx: *Session(Check), lit: []const Entry, dist: []const Entry) Error!Stop {
    const br = ctx.br;
    while (true) {
        if (br.src.len - br.i < 8) {
            if (br.nbits >= 10) {
                const buffered = peekFirst(lit, 10, br.bits);
                if (buffered.kind == .eob) {
                    br.consume(buffered.nbits);
                    return .end;
                }
            }
            _ = try br.window(8);
        }
        if (try @call(.never_inline, decodeFast, .{ Check, ctx, lit, dist })) return .end;
        // A stream may end at the end of the input (raw DEFLATE has no trailer), so fewer than 15 bits
        // can remain; a code that is invalid or longer than what remains is then a truncation.
        try br.fill(15);
        var e = peekFirst(lit, 10, br.bits);
        if (e.kind == .long) e = lookupLong(e, &ctx.decoder.tables.lit_spill, br.bits, 10);
        if (br.nbits < 15 and (e.kind == .invalid or e.nbits > br.nbits)) return error.Truncated;
        switch (e.kind) {
            .eob => {
                br.consume(e.nbits);
                return .end;
            },
            .lit => {
                if (ctx.out_pos == ctx.out.len) return .full;
                br.consume(e.nbits);
                ctx.out[ctx.out_pos] = @truncate(e.payload);
                ctx.out_pos += 1;
            },
            .len => {
                if (ctx.out_pos == ctx.out.len) return .full;
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
                if (!try ctx.startMatch(d.payload + @as(usize, dadd), length)) return .full;
            },
            else => return error.BadSymbol,
        }
    }
}

const TestCheck = struct {
    pub fn update(_: *TestCheck, _: []const u8) void {}
};

test {
    _ = copy;
    _ = codes;
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
    var check: TestCheck = .{};
    var ctx: Session(TestCheck) = .{
        .decoder = decoder,
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

// Reads `size` bytes at a time from a paused session, rebasing after each read while bytes stay unread.

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
        try std.testing.expectEqualSlices(u8, expected[got..][0..n], session.decoder.buffer[seek..][0..n]);
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
    // Text-like runs, long matches across batch ends, and random stretches that become stored blocks.
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
    for ([_]encode.Level{ .fast, .even, .dense }) |level| {
        var writer = std.Io.Writer.fixed(compressed);
        var encode_check: TestCheck = .{};
        try encoder.encodeSlice(TestCheck, plain, &writer, &encode_check, level, false);
        for ([_]usize{ 1, 7, 4093, 65536, 1 << 20 }) |size| {
            if (size == 1 and level != .even) continue;
            var reader = std.Io.Reader.fixed(writer.buffered());
            var br: BitReader = .{ .reader = &reader };
            var check: SumCheck = .{};
            var session: Session(SumCheck) = .{ .decoder = decoder, .max_output_bytes = std.math.maxInt(u64) };
            session.begin(&br, &check);
            try pumpSession(&session, size, plain);
            try std.testing.expectEqual(@as(u64, plain.len), session.position());
            try std.testing.expectEqual(expected, check);
        }
        // An output limit equal to the stream's size is met; one byte less is exceeded.
        for ([_]u64{ plain.len, plain.len - 1 }) |max| {
            var reader = std.Io.Reader.fixed(writer.buffered());
            var br: BitReader = .{ .reader = &reader };
            var check: SumCheck = .{};
            var session: Session(SumCheck) = .{ .decoder = decoder, .max_output_bytes = max };
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
        var session: Session(TestCheck) = .{ .decoder = decoder, .max_output_bytes = std.math.maxInt(u64) };
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
                .out_pos = RING,
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
            .out_pos = RING,
            .max_output_bytes = std.math.maxInt(u64),
        };
        try std.testing.expect(try decodeFastImpl(TestCheck, &ctx, &decoder.tables.lit_first, &decoder.tables.dist_first, true));
        try std.testing.expectEqual(RING + 259, ctx.out_pos);
        try std.testing.expectEqual(consumed, br.i * 8 - br.nbits);
        try std.testing.expectEqualSlices(u8, decoder.buffer[0..258], decoder.buffer[RING..][0..258]);
        try std.testing.expectEqual(@as(u8, 'A'), decoder.buffer[RING + 258]);
    }
}
