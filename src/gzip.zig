//! Bounded gzip compression and decompression through caller-owned readers and writers.

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

pub const CompressError = error{ ReadFailed, WriteFailed };

pub const CompressOptions = struct {
    level: enum(u4) { fast = 1, balanced = 5, dense = 9 } = .balanced,
};

/// Reusable without initialization, including after errors. No allocation occurs during compression.
/// Reader, writer and workspace storage must not overlap. One active call per workspace.
pub const Compressor = struct {
    window: [2 * RING]u8 = undefined,
    head: [ENCODE_HASH]u16 = undefined,
    previous: [RING]u16 = undefined,
    tokens: [RING + RING / 4 + 2]u8 = undefined,
    lit_freq: [286]u32 = undefined,
    dist_freq: [30]u32 = undefined,
    token_bytes: usize = undefined,

    /// Reads through EOF and writes one member. Caller flushes writer; failures may leave partial output.
    /// Reader capacity may be zero. A failed call cannot be resumed.
    pub fn compress(self: *Compressor, reader: *std.Io.Reader, writer: *std.Io.Writer, options: CompressOptions) CompressError!u64 {
        @memset(&self.head, 0);
        @memset(&self.previous, 0);
        try writer.writeAll(&.{ 31, 139, 8, 0, 0, 0, 0, 0, 0, 255 });
        var bits: Bw = .{ .writer = writer };
        var history: usize = 0;
        var sum: u32 = 0xffffffff;
        var size: u64 = 0;
        var lookahead: [1]u8 = undefined;
        var carried: usize = 0;
        while (true) {
            if (carried != 0) self.window[history] = lookahead[0];
            const n = carried + try reader.readSliceShort(self.window[history + carried ..][0 .. RING - carried]);
            carried = if (n == RING) try reader.readSliceShort(&lookahead) else 0;
            const last = carried == 0;
            const end = history + n;
            sum = crc.update(sum, self.window[history..end]);
            size +%= n;
            // The previous block's final two positions lacked three-byte lookahead.
            if (history != 0) {
                var p = history - 2;
                while (p < history and p + 3 <= end) : (p += 1) self.insert(p);
            }
            self.parse(history, end, options);
            try self.emit(&bits, self.window[history..end], last);
            if (last) break;
            if (history != 0) {
                @memcpy(self.window[0..RING], self.window[RING..][0..RING]);
                rebase(&self.head);
                rebase(&self.previous);
            }
            history = RING;
        }
        try bits.alignByte();
        var trailer: [8]u8 = undefined;
        std.mem.writeInt(u32, trailer[0..4], crc.finish(sum), .little);
        std.mem.writeInt(u32, trailer[4..8], @truncate(size), .little);
        try writer.writeAll(&trailer);
        return size;
    }

    fn hash(self: *const Compressor, p: usize) usize {
        const v = @as(u32, self.window[p]) | (@as(u32, self.window[p + 1]) << 8) | (@as(u32, self.window[p + 2]) << 16);
        return (v *% 0x1e35a7bd) >> 18;
    }

    fn insert(self: *Compressor, p: usize) void {
        const h = self.hash(p);
        self.previous[p & (RING - 1)] = self.head[h];
        self.head[h] = @intCast(p + 1);
    }

    const Match = struct { len: usize = 2, dist: usize = 0 };

    fn find(self: *const Compressor, p: usize, end: usize, budget: usize) Match {
        var best: Match = .{};
        if (p + 3 > end) return best;
        const limit = @min(258, end - p);
        const lower = p -| RING;
        var entry = self.head[self.hash(p)];
        var attempts = budget;
        while (entry != 0 and attempts != 0) : (attempts -= 1) {
            const q: usize = entry - 1;
            if (q < lower or q >= p) break;
            if (self.window[q + best.len] == self.window[p + best.len] and
                self.window[q] == self.window[p] and self.window[q + 1] == self.window[p + 1])
            {
                const len = matchLength(self.window[p..][0..limit], self.window[q..][0..limit]);
                if (len > best.len) {
                    best = .{ .len = len, .dist = p - q };
                    if (len == limit) break;
                }
            }
            const next = self.previous[q & (RING - 1)];
            if (next >= entry) break;
            entry = next;
        }
        return best;
    }

    fn parse(self: *Compressor, start: usize, end: usize, options: CompressOptions) void {
        @memset(&self.lit_freq, 0);
        @memset(&self.dist_freq, 0);
        self.lit_freq[256] = 1;
        self.token_bytes = 0;
        const budget: usize = switch (options.level) {
            .fast => 4,
            .balanced => 32,
            .dense => 128,
        };
        var p = start;
        var literal_start = start;
        var pending: Match = .{};
        while (p < end) {
            var m = if (pending.len >= 3) pending else self.find(p, end, budget);
            pending = .{};
            if (p + 3 <= end) self.insert(p);
            if (options.level != .fast and m.len >= 3 and m.len < 258 and p + 3 < end) {
                const next = self.find(p + 1, end, budget);
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
                    if (p + 3 <= end) self.insert(p);
                }
                literal_start = p;
            } else {
                self.lit_freq[self.window[p]] += 1;
                p += 1;
            }
        }
        self.addLiterals(end - literal_start);
    }

    fn addLiterals(self: *Compressor, n: usize) void {
        if (n == 0) return;
        std.mem.writeInt(u16, self.tokens[self.token_bytes..][0..2], @intCast(n - 1), .little);
        self.token_bytes += 2;
    }

    fn cost(self: *const Compressor, lit: *const EncodeTree, dist: *const EncodeTree) u64 {
        var n: u64 = 0;
        for (self.lit_freq, 0..) |f, i| n += @as(u64, f) * (lit.lens[i] + @as(u8, if (i >= 257) LEN_EXTRA[i - 257] else 0));
        for (self.dist_freq, 0..) |f, i| n += @as(u64, f) * (dist.lens[i] + @as(u8, DIST_EXTRA[i]));
        return n;
    }

    fn emit(self: *const Compressor, bits: *Bw, raw: []const u8, last: bool) CompressError!void {
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
            return;
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
    }

    fn emitTokens(self: *const Compressor, bits: *Bw, raw: []const u8, lit: *const EncodeTree, dist: *const EncodeTree) CompressError!void {
        var t: usize = 0;
        var p: usize = 0;
        while (t < self.token_bytes) {
            const word = std.mem.readInt(u16, self.tokens[t..][0..2], .little);
            t += 2;
            if (word & 0x8000 == 0) {
                const end = p + @as(usize, word) + 1;
                for (raw[p..end]) |v| try bits.symbol(lit, v);
                p = end;
            } else {
                const v = self.tokens[t];
                t += 1;
                const d = @as(usize, word & 0x7fff) + 1;
                const l = LEN_CODE[v];
                const dc = distCode(d);
                try bits.symbol(lit, 257 + @as(usize, l));
                try bits.put(@as(u32, v) + 3 - LEN_BASE[l], LEN_EXTRA[l]);
                try bits.symbol(dist, dc);
                try bits.put(@intCast(d - DIST_BASE[dc]), DIST_EXTRA[dc]);
                p += @as(usize, v) + 3;
            }
        }
        std.debug.assert(p == raw.len);
        try bits.symbol(lit, 256);
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
            self.crcCatchup();
            self.crc = crc.copyUpdate(self.crc, bytes[off..][0..n], self.out[self.out_pos..][0..n]);
            self.out_pos += n;
            self.crc_pos = self.out_pos;
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
                try fillTwoLevel(&ctx.work.lit_first, &ctx.work.lit_spill, 10, &lit_lens, litKind, litPayload, true);
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

// --- Compression ---

const ENCODE_HASH = 16384;

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
    while (n + 8 <= a.len) : (n += 8) {
        const x = std.mem.readInt(u64, a[n..][0..8], .little) ^ std.mem.readInt(u64, b[n..][0..8], .little);
        if (x != 0) return n + @as(usize, @ctz(x)) / 8;
    }
    while (n < a.len and a[n] == b[n]) : (n += 1) {}
    return n;
}

fn distCode(d: usize) usize {
    if (d <= 4) return d - 1;
    const top = std.math.log2_int(usize, d - 1);
    return 2 * @as(usize, top) + (((d - 1) >> (top - 1)) & 1);
}

const Bw = struct {
    writer: *std.Io.Writer,
    value: u64 = 0,
    count: u6 = 0,

    fn put(self: *Bw, value: u32, n: u5) CompressError!void {
        std.debug.assert(n <= 16 and (n == 0 or value < (@as(u32, 1) << n)));
        if (n == 0) return;
        if (self.count > 47) try self.drain();
        self.value |= @as(u64, value) << self.count;
        self.count += n;
    }

    fn drain(self: *Bw) CompressError!void {
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

    fn symbol(self: *Bw, tree: *const EncodeTree, s: usize) CompressError!void {
        try self.put(tree.codes[s], @intCast(tree.lens[s]));
    }

    fn alignByte(self: *Bw) CompressError!void {
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
                if (depth > max_bits) return false;
                p = nodes[p].parent;
            }
            self.lens[i] = @intCast(@max(1, depth));
        }
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

test {
    _ = crc;
    _ = copy;
}

test "[property] - [gzip tables]: narrower roots preserve entries and bounded spill" {
    const Tables = struct {
        fn check(comptime width: u4, lens: []const u4, seen_heights: *u16, compare_widths: bool) !void {
            const capacity = if (width == 10) 1536 else 292;
            var root: [1 << width]Entry = undefined;
            var spill: [if (width == 10) 4608 else 2048]Entry = undefined;
            const kind = if (width == 10) litKind else distKind;
            const payload = if (width == 10) litPayload else distPayload;
            try fillTwoLevel(&root, &spill, width, lens, kind, payload, true);
            var used: usize = 0;
            for (root) |entry| {
                if (entry.kind == .long) used = @max(used, entry.payload + (@as(usize, 1) << @intCast(entry.extra)));
            }
            try std.testing.expect(used <= capacity);

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

test "[property] - [gzip]: fast literals consume exact bits within output room" {
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

test "[edge] - [gzip]: lookahead retains unread bits after a maximum-width match" {
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

test "[edge] - [gzip]: over-depth encoding trees select the fallback" {
    var tree: EncodeTree = .{};
    var freq: [25]u32 = @splat(1);
    for (2..freq.len) |i| freq[i] = freq[i - 1] + freq[i - 2];
    try std.testing.expect(!tree.build(&freq, 15));
    @memset(&freq, 0);
    freq[9] = 1;
    try std.testing.expect(tree.build(&freq, 15));
    try std.testing.expectEqual(@as(u4, 1), tree.lens[9]);
    try std.testing.expectEqual(@as(u16, 0), tree.codes[9]);
}

test "[edge] - [gzip compressor]: position rebasing preserves sentinels and every vector tail" {
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

test "[property] - [gzip compressor]: bit output matches scalar packing at writer limits" {
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
            var bits: Bw = .{ .writer = &writer };
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
