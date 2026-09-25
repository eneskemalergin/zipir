//! Bounded gzip compression and decompression through caller-owned readers and writers.

const std = @import("std");
const deflate = @import("../deflate/deflate.zig");
const crc = @import("../kernel/crc32.zig");

const RING = deflate.RING;
const CLEN_ORDER = deflate.CLEN_ORDER;
const LEN_EXTRA = deflate.LEN_EXTRA;
const DIST_EXTRA = deflate.DIST_EXTRA;
const LEN_BASE = deflate.LEN_BASE;
const DIST_BASE = deflate.DIST_BASE;
const FIXED_LIT_LENS = deflate.FIXED_LIT_LENS;
const FIXED_DIST_LENS = deflate.FIXED_DIST_LENS;
const bitReverse = deflate.bitReverse;
const buildCodes = deflate.buildCodes;

pub const Error = deflate.Error || error{
    InputBufferTooSmall,
    BadHeader,
    UnsupportedMethod,
    ReservedFlag,
    HeaderCrcMismatch,
    IsizeMismatch,
    CrcMismatch,
    TrailingData,
};

pub const Options = struct {
    max_output_bytes: u64 = std.math.maxInt(u64),
    trailing_data: enum { reject, leave } = .reject,
};

/// Reusable without initialization, including after errors. No allocation occurs during decode.
/// Reader, writer and workspace storage must not overlap. One active call per workspace.
pub const Decompressor = struct {
    decoder: deflate.Decoder = .{},

    /// Reader capacity must be >=16; underlying reads may be shorter. Caller flushes writer.
    /// Output is provisional until success. Errors abort; a failed call cannot be resumed.
    pub fn decompress(self: *Decompressor, reader: *std.Io.Reader, writer: *std.Io.Writer, options: Options) Error!u64 {
        return inflate(self, reader, writer, options);
    }
};

comptime {
    std.debug.assert(@sizeOf(Decompressor) == 196608);
}

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
        if (options.level != .fast) @memset(&self.previous, 0);
        try writer.writeAll(&.{ 31, 139, 8, 0, 0, 0, 0, 0, 0, 255 });
        var bits: Bw = .{ .writer = writer };
        var history: usize = 0;
        var sum: u32 = 0xffffffff;
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
            sum = crc.updateState(sum, self.window[history..end]);
            size +%= n;
            // The previous block's final two positions lacked three-byte lookahead.
            if (history != 0) {
                var p = history - 2;
                while (p < history and p + 3 <= end) : (p += 1) {
                    if (options.level == .fast) self.insert(p, self.hash(p, end), false) else self.insert(p, self.hash(p, end), true);
                }
            }
            // Fast searches one head candidate, so its parse keeps no chain.
            if (options.level == .fast) self.parse(history, end, options, skip_search, false) else self.parse(history, end, options, skip_search, true);
            const stored = try self.emit(&bits, self.window[history..end], last);
            // Stored blocks are a bounded miss signal. Recheck after one skipped block.
            skip_search = stored and !skip_search and options.level != .fast;
            if (last) break;
            if (history != 0) {
                @memcpy(self.window[0..RING], self.window[RING..][0..RING]);
                rebase(&self.head);
                if (options.level != .fast) rebase(&self.previous);
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

    fn hash(self: *const Compressor, p: usize, end: usize) usize {
        // The final three-byte tail has no fourth byte for the hot-path key.
        const v = if (p + 4 <= end)
            std.mem.readInt(u32, self.window[p..][0..4], .little)
        else
            @as(u32, self.window[p]) | (@as(u32, self.window[p + 1]) << 8) | (@as(u32, self.window[p + 2]) << 16);
        return (v *% 0x1e35a7bd) >> 17;
    }

    fn insert(self: *Compressor, p: usize, h: usize, comptime chain: bool) void {
        if (chain) self.previous[p & (RING - 1)] = self.head[h];
        self.head[h] = @intCast(p + 1);
    }

    const Match = struct { len: usize = 2, dist: usize = 0 };

    fn find(self: *const Compressor, p: usize, end: usize, budget: usize, nice: usize, h: usize, comptime chain: bool) Match {
        var best: Match = .{};
        if (p + 3 > end) return best;
        const limit = @min(258, end - p);
        const lower = p -| RING;
        var entry = self.head[h];
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

    fn hasEarlyMatch(self: *const Compressor, start: usize, end: usize) bool {
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

    fn parse(self: *Compressor, start: usize, end: usize, options: CompressOptions, skip_search: bool, comptime chain: bool) void {
        @memset(&self.lit_freq, 0);
        @memset(&self.dist_freq, 0);
        self.lit_freq[256] = 1;
        self.token_bytes = 0;
        const budget: usize = switch (options.level) {
            .fast => 1,
            .balanced => 12,
            .dense => 128,
        };
        const nice: usize = switch (options.level) {
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

    fn emit(self: *const Compressor, bits: *Bw, raw: []const u8, last: bool) CompressError!bool {
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

    fn emitTokens(self: *const Compressor, bits: *Bw, raw: []const u8, lit: *const EncodeTree, dist: *const EncodeTree) CompressError!void {
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

// --- Decompression ---

fn parseHeader(br: *deflate.Br) !void {
    const header = try br.getBytes(10);
    if (header[0] != 0x1f or header[1] != 0x8b) return error.BadHeader;
    if (header[2] != 8) return error.UnsupportedMethod;
    const flags = header[3];
    if (flags & 0xe0 != 0) return error.ReservedFlag;
    var checksum = crc.Crc32.init();
    checksum.update(header);
    if (flags & 4 != 0) {
        const size_bytes = try br.getBytes(2);
        const size = std.mem.readInt(u16, size_bytes[0..2], .little);
        checksum.update(size_bytes);
        var left: usize = size;
        while (left != 0) {
            if (br.i == br.src.len and !try br.window(1)) return error.Truncated;
            const n = @min(left, br.src.len - br.i);
            checksum.update(try br.getBytes(n));
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
            checksum.update(try br.getBytes(n));
            if (zero != null) break;
        }
    }
    if (flags & 2 != 0) {
        const expected: u16 = @truncate(checksum.final());
        const field = try br.getBytes(2);
        if (std.mem.readInt(u16, field[0..2], .little) != expected) return error.HeaderCrcMismatch;
    }
}

fn inflateMember(session: *deflate.Session(crc.Crc32), br: *deflate.Br) Error!void {
    try parseHeader(br);
    var check: crc.Crc32 = .init();
    const size = try session.stream(br, &check);
    const footer = try br.getBytes(8);
    const trailer_crc = std.mem.readInt(u32, footer[0..4], .little);
    const trailer_size = std.mem.readInt(u32, footer[4..8], .little);
    if (trailer_size != @as(u32, @truncate(size))) return error.IsizeMismatch;
    if (check.final() != trailer_crc) return error.CrcMismatch;
}

fn inflate(work: *Decompressor, reader: *std.Io.Reader, writer: *std.Io.Writer, options: Options) Error!u64 {
    if (reader.buffer.len < 16) return error.InputBufferTooSmall;
    var br: deflate.Br = .{ .reader = reader };
    defer br.release();
    var session = work.decoder.session(crc.Crc32, writer, .{ .max_output_bytes = options.max_output_bytes });
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
        try inflateMember(&session, &br);
        have_member = true;
    }
    return session.finish();
}

// --- Compression ---

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

const Bw = struct {
    writer: *std.Io.Writer,
    value: u64 = 0,
    count: u32 = 0,

    fn put(self: *Bw, value: u32, n: u5) CompressError!void {
        std.debug.assert(n <= 16 and (n == 0 or value < (@as(u32, 1) << n)));
        if (n == 0) return;
        if (self.count > 47) try self.drain();
        self.value |= @as(u64, value) << @intCast(self.count);
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

    inline fn add(self: *Bw, entry: u64) void {
        self.value |= (entry & 0xffffffff) << @intCast(self.count);
        self.count += @intCast(entry >> 32);
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

test {
    _ = crc;
}

test "[edge] - [gzip]: over-depth encoding trees are shortened to complete limited codes" {
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
