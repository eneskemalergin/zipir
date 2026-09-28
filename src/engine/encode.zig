//! DEFLATE encoding (RFC 1951): the bit writer, Huffman encode trees, the presets' parsers, and the encoder,
//! which codes its input a window at a time.

const std = @import("std");
const copy = @import("../kernel/copy.zig");
const codes = @import("codes.zig");

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

const ENCODE_HASH = 65536;

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
    lens: [288]u4 = @splat(0),
    codes: [288]u16 = undefined,

    fn build(self: *EncodeTree, freq: []const u32, max_bits: u4) bool {
        var keys: [288]u64 = undefined;
        var n: usize = 0;
        @memset(&self.lens, 0);
        for (freq, 0..) |f, i| {
            if (f == 0) continue;
            keys[n] = @as(u64, f) << 9 | i;
            n += 1;
        }
        if (n == 0) return false;
        if (n == 1) {
            self.lens[@intCast(keys[0] & 511)] = 1;
            return self.canonical();
        }
        std.sort.pdq(u64, keys[0..n], {}, std.sort.asc(u64));
        var a: [288]u32 = undefined;
        for (keys[0..n], 0..) |k, i| a[i] = @intCast(k >> 9);
        // Moffat and Katajainen, "In-place calculation of minimum-redundancy codes": a[i] ends as the code
        // length of the i-th least frequent symbol.
        a[0] += a[1];
        var root: usize = 0;
        var leaf: usize = 2;
        var next: usize = 1;
        while (next < n - 1) : (next += 1) {
            if (leaf >= n or a[root] < a[leaf]) {
                a[next] = a[root];
                a[root] = @intCast(next);
                root += 1;
            } else {
                a[next] = a[leaf];
                leaf += 1;
            }
            if (leaf >= n or (root < next and a[root] < a[leaf])) {
                a[next] += a[root];
                a[root] = @intCast(next);
                root += 1;
            } else {
                a[next] += a[leaf];
                leaf += 1;
            }
        }
        a[n - 2] = 0;
        var j: usize = n - 2;
        while (j > 0) {
            j -= 1;
            a[j] = a[a[j]] + 1;
        }
        var avail: usize = 1;
        var used: usize = 0;
        var depth: u32 = 0;
        var r: isize = @as(isize, @intCast(n)) - 2;
        var out: isize = @as(isize, @intCast(n)) - 1;
        while (avail > 0) {
            while (r >= 0 and a[@intCast(r)] == depth) {
                used += 1;
                r -= 1;
            }
            while (avail > used) {
                a[@intCast(out)] = depth;
                out -= 1;
                avail -= 1;
            }
            avail = 2 * used;
            depth += 1;
            used = 0;
        }
        // a[0] is the longest code; limit the depth on the length counts (JPEG Annex K.3), then give the
        // shortest lengths to the most frequent symbols.
        var count: [33]u32 = @splat(0);
        for (a[0..n]) |l| count[l] += 1;
        var len: usize = a[0];
        while (len > max_bits) : (len -= 1) {
            while (count[len] > 0) {
                var k = len - 2;
                while (count[k] == 0) k -= 1;
                count[len] -= 2;
                count[len - 1] += 1;
                count[k + 1] += 2;
                count[k] -= 1;
            }
        }
        var s: usize = n;
        for (1..@as(usize, max_bits) + 1) |l| {
            for (0..count[l]) |_| {
                s -= 1;
                self.lens[@intCast(keys[s] & 511)] = @intCast(l);
            }
        }
        return self.canonical();
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

pub const Level = enum(u4) { fast = 1, even = 5, dense = 9 };

// Self-contained tokens (after igzip's ICF): bits 0-9 hold the first symbol (a literal 0-255, or 254 + the
// length of a match), bits 10-18 the second (a distance code 0-29, ICF_NONE, or ICF_LITERAL + a literal),
// bits 19-31 the distance's extra bits. A token is a match, one literal, or two literals. At most one token
// per two input bytes (a lone literal is always followed by a match of at least four), plus one per window.
const ICF_NONE: u32 = 30;
const ICF_LITERAL: u32 = 31;
const ICF_CAP = RING + 4;

// fast hashes into the first FAST_HASH heads: 2^16 cost it 2% to 5% for 0.1% to 0.5% more ratio.
const FAST_HASH = 32768;

const LOG2_FRACTION: [256]f64 = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]f64 = undefined;
    for (&t, 0..) |*e, i| e.* = @log2(1.0 + @as(f64, @floatFromInt(i)) / 256.0);
    break :blk t;
};

/// log2 of a count to about 0.006: the exponent plus eight fraction bits (for estimates only).
fn log2Table(x: u32) f64 {
    if (x == 0) return 0;
    const e = std.math.log2_int(u32, x);
    const m: u32 = if (e >= 8) (x >> @intCast(e - 8)) & 0xff else (x << @intCast(8 - e)) & 0xff;
    return @as(f64, @floatFromInt(e)) + LOG2_FRACTION[m];
}

fn fastHash(v: u32) usize {
    return (v *% 0x1e35a7bd) >> 17;
}

pub const EncodeError = std.Io.Writer.Error;

pub const CompressOptions = struct {
    level: Level = .even,
};

pub const Encoder = struct {
    // A window of input is parsed once more than a window is buffered (which also proves it is not the last);
    // the third 32 KiB is room for that surplus, so a writer can always offer 32 KiB of contiguous space.
    window: [3 * RING]u8 = undefined,
    head: [ENCODE_HASH]u16 = undefined,
    previous: [RING]u16 = undefined,
    lit_freq: [286]u32 = undefined,
    dist_freq: [30]u32 = undefined,
    // fast: self-contained tokens (see `parseFast`), one block per two windows.
    icf: [ICF_CAP]u32 = undefined,
    icf_count: usize = undefined,
    // The stream: its output, bits not yet written, and the window pairing carried between windows.
    out: *std.Io.Writer = undefined,
    bit_value: u64 = 0,
    bit_count: u32 = 0,
    level: Level = .even,
    history: usize = 0,
    size: u64 = 0,
    skip_search: bool = false,
    pending: bool = false,
    first_lit: [286]u32 = undefined,
    first_dist: [30]u32 = undefined,
    first_tokens: usize = 0,

    /// One BGZF block (at most 65280 bytes): the same presets with settings for a cold 64 KiB block
    /// (PHASE2.md): fast keeps two candidates per hash bucket and even searches deeper.
    pub fn encodeBlock(self: *Encoder, comptime Check: type, input: []const u8, writer: *std.Io.Writer, check: *Check, level: Level) EncodeError!void {
        std.debug.assert(input.len <= 2 * RING);
        return self.encodeSlice(Check, input, writer, check, level, true);
    }

    /// A whole stream of `input`, a window at a time.
    pub fn encodeSlice(self: *Encoder, comptime Check: type, input: []const u8, writer: *std.Io.Writer, check: *Check, level: Level, comptime block: bool) EncodeError!void {
        self.begin(writer, level, block);
        var at: usize = 0;
        while (true) {
            const n = @min(input.len - at, RING + 1);
            @memcpy(self.window[self.history..][0..n], input[at..][0..n]);
            const last = n <= RING;
            try self.step(Check, check, if (last) n else RING, if (last) 0 else 1, last, last, block);
            if (last) break;
            at += RING;
        }
        try self.finish();
    }

    /// Starts a stream written to `writer`. `block` selects the BGZF block settings.
    pub fn begin(self: *Encoder, writer: *std.Io.Writer, level: Level, comptime block: bool) void {
        // `previous` is never cleared: with `head` clear, every position a chain reaches was inserted in this
        // stream, which wrote its `previous` slot; a slot reused by a later position is behind `lower` and
        // rejected before it is read. BGZF pays this once per 64 KiB block.
        // 64 or 128 KiB: `@memset` here would call compiler_rt's byte-per-iteration `memset` (see `copy.zero`).
        copy.zero(std.mem.sliceAsBytes(self.headsFor(level)));
        // Block fast keeps each bucket's older candidate in `previous`, which must start clean too.
        if (block and level == .fast) copy.zero(std.mem.asBytes(self.previous[0..FAST_HASH]));
        self.out = writer;
        self.bit_value = 0;
        self.bit_count = 0;
        self.level = level;
        self.history = 0;
        self.size = 0;
        // A BGZF block learns nothing from the block before it: its first window starts with the search provisionally
        // off, so `hasEarlyMatch` (on a clean table) and the entropy check decide from the block itself.
        self.skip_search = block;
        self.pending = false;
    }

    /// Where the next window's bytes go: `space()[0..carried]` already holds the bytes carried from the last one.
    pub fn space(self: *Encoder) []u8 {
        return self.window[self.history..][0 .. 2 * RING];
    }

    /// Codes `space()[0..n]` as the next window: `n` is 32 KiB except in the last. The `carried` bytes after it
    /// (at most 32 KiB) begin the next window. `last` ends the run of windows (a pending pair is coded); `final`
    /// marks its last block as the stream's last (false for a flush).
    pub fn step(self: *Encoder, comptime Check: type, check: *Check, n: usize, carried: usize, last: bool, final: bool, comptime block: bool) EncodeError!void {
        std.debug.assert(n <= RING and (last or n == RING) and carried <= RING and (last or !final));
        var bits: BitWriter = .{ .writer = self.out, .value = self.bit_value, .count = self.bit_count };
        defer {
            self.bit_value = bits.value;
            self.bit_count = bits.count;
        }
        const level = self.level;
        const history = self.history;
        const end = history + n;
        check.update(self.window[history..end]);
        self.size +%= n;
        // Positions at the end of the previous window were not inserted: the last two lacked three-byte
        // lookahead, and `parseFast` stops eight bytes before the end.
        if (history != 0) {
            if (level == .fast) {
                var p = history - 8;
                while (p < history and p + 4 <= end) : (p += 1) {
                    const h = fastHash(std.mem.readInt(u32, self.window[p..][0..4], .little));
                    if (block) self.previous[h] = self.head[h];
                    self.head[h] = @intCast(p);
                }
            } else {
                var p = history - 2;
                while (p < history and p + 3 <= end) : (p += 1) self.insert(p, if (level == .even) self.hash(p, end, 5) else self.hash(p, end, 4));
            }
        }
        // Windows go in pairs: the first is parsed and kept; after the slide it is the history half, so the pair's
        // bytes are window[0..end]. fast makes one block per pair; even and dense make one block or two,
        // whichever codes smaller (`emitPair`).
        if (level == .fast and !block) {
            self.parseFast(history, end, !self.pending);
            if (!last and !self.pending) {
                self.pending = true;
            } else {
                _ = try self.emit(&bits, self.window[if (self.pending) 0 else history..end], final);
                self.pending = false;
            }
        } else if (level == .fast) {
            self.parseFastBlock(history, end, !self.pending);
            if (!last and !self.pending) {
                self.first_lit = self.lit_freq;
                self.first_dist = self.dist_freq;
                self.first_tokens = self.icf_count;
                self.pending = true;
            } else if (self.pending) {
                _ = try self.emitPair(&bits, end, final, &self.first_lit, &self.first_dist, self.first_tokens);
                self.pending = false;
            } else {
                _ = try self.emit(&bits, self.window[history..end], final);
            }
        } else {
            if (level == .even) self.parse(history, end, level, self.skip_search, !self.pending, 5, block) else self.parse(history, end, level, self.skip_search, !self.pending, 4, block);
            // A stored block turns the search off until `hasEarlyMatch` sees a match near a block start.
            if (!last and !self.pending) {
                // The first window of a pair: its counts price it as a block of its own later.
                self.first_lit = self.lit_freq;
                self.first_dist = self.dist_freq;
                self.first_tokens = self.icf_count;
                self.pending = true;
            } else if (self.pending) {
                self.skip_search = try self.emitPair(&bits, end, final, &self.first_lit, &self.first_dist, self.first_tokens);
                self.pending = false;
            } else {
                self.skip_search = try self.emit(&bits, self.window[history..end], final);
            }
        }
        if (last) return;
        if (history != 0) {
            @memcpy(self.window[0..RING], self.window[RING..][0..RING]);
            rebase(self.headsFor(level));
            if (level != .fast) rebase(&self.previous) else if (block) rebase(self.previous[0..FAST_HASH]);
            @memcpy(self.window[RING..][0..carried], self.window[2 * RING ..][0..carried]);
        }
        self.history = RING;
    }

    /// After the last window: pads the final block to a byte boundary and writes what is left.
    pub fn finish(self: *Encoder) EncodeError!void {
        var bits: BitWriter = .{ .writer = self.out, .value = self.bit_value, .count = self.bit_count };
        try bits.alignByte();
        self.bit_value = 0;
        self.bit_count = 0;
    }

    /// After a run ended by a non-final `step`: an empty stored block brings the output to a byte boundary, so
    /// every byte so far can be decoded, and the next window starts a new history (a full flush).
    pub fn sync(self: *Encoder) EncodeError!void {
        var bits: BitWriter = .{ .writer = self.out, .value = self.bit_value, .count = self.bit_count };
        try bits.put(0, 3);
        try bits.alignByte();
        try bits.put(0, 16);
        try bits.put(0xffff, 16);
        try bits.drain();
        const size = self.size;
        self.begin(self.out, self.level, false);
        self.size = size;
    }

    fn headsFor(self: *Encoder, level: Level) []u16 {
        return if (level == .fast) self.head[0..FAST_HASH] else self.head[0..];
    }

    /// The chain hash of the `key` bytes at `p` (4 for dense, 5 for even; zero-padded at the tail).
    fn hash(self: *const Encoder, p: usize, end: usize, comptime key: u4) usize {
        if (key == 5) {
            // Five-byte keys: DNA has 256 four-byte keys but 1024 five-byte ones, so even's short chain walk
            // reaches four times further back (and raised its ratio 0.3% at equal speed).
            const v = if (p + 8 <= end) std.mem.readInt(u64, self.window[p..][0..8], .little) & 0xff_ffff_ffff else blk: {
                var bytes: [8]u8 = @splat(0);
                const n = @min(5, end - p);
                @memcpy(bytes[0..n], self.window[p..][0..n]);
                break :blk std.mem.readInt(u64, &bytes, .little);
            };
            return @intCast((v *% 0x9e3779b97f4a7c15) >> 48);
        }
        // The final three-byte tail has no fourth byte for the hot-path key.
        const v = if (p + 4 <= end)
            std.mem.readInt(u32, self.window[p..][0..4], .little)
        else
            @as(u32, self.window[p]) | (@as(u32, self.window[p + 1]) << 8) | (@as(u32, self.window[p + 2]) << 16);
        return (v *% 0x1e35a7bd) >> 16;
    }

    fn insert(self: *Encoder, p: usize, h: usize) void {
        self.previous[p & (RING - 1)] = self.head[h];
        self.head[h] = @intCast(p + 1);
    }

    const Match = struct { len: usize = 2, dist: usize = 0 };

    fn find(self: *const Encoder, p: usize, end: usize, budget: usize, nice: usize, h: usize) Match {
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
            const next = self.previous[q & (RING - 1)];
            if (next >= entry) break;
            entry = next;
        }
        return best;
    }

    /// Order-0 entropy in bits per byte of `n` bytes with byte counts `counts`.
    fn entropyBits(counts: *const [256]u32, n: usize) f64 {
        if (n == 0) return 0;
        const total: f64 = @floatFromInt(n);
        var bits: f64 = 0;
        for (counts) |c| {
            if (c == 0) continue;
            const f: f64 = @floatFromInt(c);
            bits -= f * @log2(f / total);
        }
        return bits / total;
    }

    fn hasEarlyMatch(self: *const Encoder, start: usize, end: usize, comptime key: u4) bool {
        const lower = start -| RING;
        const stop = @min(end, start + 1024);
        var p = start;
        while (p + 4 <= stop) : (p += 1) {
            const h = self.hash(p, end, key);
            const entry = self.head[h];
            if (entry == 0) continue;
            const q: usize = entry - 1;
            if (q < lower or q >= p) continue;
            if (std.mem.readInt(u32, self.window[p..][0..4], .little) ==
                std.mem.readInt(u32, self.window[q..][0..4], .little)) return true;
        }
        return false;
    }

    /// fast, after igzip's level 1 (tmp/simd/IGZIP.md): two positions per step, one table candidate each,
    /// read without validity checks (every entry gives a distance in 1..32768; the bytes decide), length
    /// from one 8-byte XOR, minimum match 4, table inserts only at the two positions after a match start.
    /// From 32 missed pairs in a row, each further miss also passes `misses / 16` literals (rounded down to
    /// even) unsearched.
    /// Tokens are self-contained (`ICF_CAP`); a new block starts when `fresh`.
    fn parseFast(self: *Encoder, start: usize, end: usize, fresh: bool) void {
        if (fresh) {
            @memset(&self.lit_freq, 0);
            @memset(&self.dist_freq, 0);
            self.lit_freq[256] = 1;
            self.icf_count = 0;
        }
        var n = self.icf_count;
        var p = start;
        var misses: usize = 0;
        while (p + 9 <= end) {
            const v0 = std.mem.readInt(u64, self.window[p..][0..8], .little);
            const v1 = std.mem.readInt(u64, self.window[p + 1 ..][0..8], .little);
            const h0 = fastHash(@truncate(v0));
            const h1 = fastHash(@truncate(v1));
            const e0: usize = self.head[h0];
            self.head[h0] = @intCast(p);
            const e1: usize = self.head[h1];
            self.head[h1] = @intCast(p + 1);
            const d0 = ((p -% e0 -% 1) & (RING - 1)) + 1;
            const d1 = ((p -% e1) & (RING - 1)) + 1;
            const x0 = v0 ^ std.mem.readInt(u64, self.window[p - @min(d0, p) ..][0..8], .little);
            const x1 = v1 ^ std.mem.readInt(u64, self.window[p + 1 - @min(d1, p + 1) ..][0..8], .little);
            const lit0: u8 = @truncate(v0);
            var m = p;
            var x = x0;
            var d = d0;
            if (@as(u32, @truncate(x0)) != 0 or d0 > p) {
                if (@as(u32, @truncate(x1)) != 0 or d1 > p + 1) {
                    n = self.literalPairs(n, p, 2);
                    misses += 1;
                    p += 2;
                    const extra = @min(misses >> 4, end - p) & ~@as(usize, 1);
                    n = self.literalPairs(n, p, extra);
                    p += extra;
                    continue;
                }
                self.icf[n] = @as(u32, lit0) | ICF_NONE << 10;
                n += 1;
                self.lit_freq[lit0] += 1;
                m = p + 1;
                x = x1;
                d = d1;
            }
            const limit = @min(258, end - m);
            const len: usize = if (x != 0) @ctz(x) / 8 else 8 + matchLength(self.window[m + 8 ..][0 .. limit - 8], self.window[m - d + 8 ..][0 .. limit - 8]);
            const dc = distCode(d);
            self.icf[n] = @as(u32, @intCast(254 + len)) | @as(u32, @intCast(dc)) << 10 | @as(u32, @intCast(d - DIST_BASE[dc])) << 19;
            n += 1;
            self.lit_freq[257 + @as(usize, LEN_CODE[len - 3])] += 1;
            self.dist_freq[dc] += 1;
            misses = 0;
            // p + 1 is in the table already.
            var q = p + 2;
            while (q <= m + 2) : (q += 1) self.head[fastHash(std.mem.readInt(u32, self.window[q..][0..4], .little))] = @intCast(q);
            p = m + len;
        }
        const tail = (end -| p) & ~@as(usize, 1);
        n = self.literalPairs(n, p, tail);
        p += tail;
        if (p < end) {
            self.icf[n] = @as(u32, self.window[p]) | ICF_NONE << 10;
            n += 1;
            self.lit_freq[self.window[p]] += 1;
        }
        std.debug.assert(n <= ICF_CAP);
        self.icf_count = n;
    }

    /// fast on a BGZF block (PHASE2.md), after libdeflate's level 1: two candidates per hash bucket (`head` the
    /// newest, `previous` the one before), both checked with an 8-byte XOR, the longer taken (both measured when
    /// both match eight bytes); one position per step; the first 12 positions of each match inserted. On a
    /// cold 64 KiB block this reaches libdeflate 1's ratio where `parseFast` is 6% short.
    fn parseFastBlock(self: *Encoder, start: usize, end: usize, fresh: bool) void {
        if (fresh) {
            @memset(&self.lit_freq, 0);
            @memset(&self.dist_freq, 0);
            self.lit_freq[256] = 1;
            self.icf_count = 0;
        }
        var n = self.icf_count;
        var p = start;
        var held: ?u8 = null;
        var misses: usize = 0;
        while (p + 8 <= end) {
            const v = std.mem.readInt(u64, self.window[p..][0..8], .little);
            const h = fastHash(@truncate(v));
            const e0: usize = self.head[h];
            const e1: usize = self.previous[h];
            self.previous[h] = @intCast(e0);
            self.head[h] = @intCast(p);
            const d0 = ((p -% e0 -% 1) & (RING - 1)) + 1;
            const d1 = ((p -% e1 -% 1) & (RING - 1)) + 1;
            const x0 = v ^ std.mem.readInt(u64, self.window[p - @min(d0, p) ..][0..8], .little);
            const x1 = v ^ std.mem.readInt(u64, self.window[p - @min(d1, p) ..][0..8], .little);
            const l0: usize = if (d0 > p) 0 else @ctz(x0) / 8;
            const l1: usize = if (d1 > p) 0 else @ctz(x1) / 8;
            const use1 = l1 > l0;
            const x = if (use1) x1 else x0;
            var d = if (use1) d1 else d0;
            const l = @max(l0, l1);
            if (l < 4) {
                const byte: u8 = @truncate(v);
                self.lit_freq[byte] += 1;
                if (held) |first| {
                    self.icf[n] = @as(u32, first) | (ICF_LITERAL + @as(u32, byte)) << 10;
                    n += 1;
                    held = null;
                } else held = byte;
                misses += 1;
                p += 1;
                if (misses >= 64) {
                    const extra = @min(misses >> 5, end - p);
                    for (self.window[p..][0..extra]) |b| {
                        self.lit_freq[b] += 1;
                        if (held) |first| {
                            self.icf[n] = @as(u32, first) | (ICF_LITERAL + @as(u32, b)) << 10;
                            n += 1;
                            held = null;
                        } else held = b;
                    }
                    p += extra;
                }
                continue;
            }
            if (held) |first| {
                self.icf[n] = @as(u32, first) | ICF_NONE << 10;
                n += 1;
                held = null;
            }
            const limit = @min(258, end - p);
            var len: usize = l;
            if (x == 0) {
                len = 8 + matchLength(self.window[p + 8 ..][0 .. limit - 8], self.window[p - d + 8 ..][0 .. limit - 8]);
                if (l0 == 8 and l1 == 8 and d1 != d and len < limit) {
                    const other = 8 + matchLength(self.window[p + 8 ..][0 .. limit - 8], self.window[p - d1 + 8 ..][0 .. limit - 8]);
                    if (other > len) {
                        len = other;
                        d = d1;
                    }
                }
            }
            const dc = distCode(d);
            self.icf[n] = @as(u32, @intCast(254 + len)) | @as(u32, @intCast(dc)) << 10 | @as(u32, @intCast(d - DIST_BASE[dc])) << 19;
            n += 1;
            self.lit_freq[257 + @as(usize, LEN_CODE[len - 3])] += 1;
            self.dist_freq[dc] += 1;
            misses = 0;
            var q = p + 1;
            const insert_end = p + @min(len, 12);
            while (q < insert_end and q + 4 <= end) : (q += 1) {
                const hq = fastHash(std.mem.readInt(u32, self.window[q..][0..4], .little));
                self.previous[hq] = self.head[hq];
                self.head[hq] = @intCast(q);
            }
            p += len;
        }
        while (p < end) : (p += 1) {
            const byte = self.window[p];
            self.lit_freq[byte] += 1;
            if (held) |first| {
                self.icf[n] = @as(u32, first) | (ICF_LITERAL + @as(u32, byte)) << 10;
                n += 1;
                held = null;
            } else held = byte;
        }
        if (held) |byte| {
            self.icf[n] = @as(u32, byte) | ICF_NONE << 10;
            n += 1;
        }
        std.debug.assert(n <= ICF_CAP);
        self.icf_count = n;
    }

    /// `count` (even) literals from `p` as pair tokens.
    inline fn literalPairs(self: *Encoder, n: usize, p: usize, count: usize) usize {
        var k: usize = 0;
        while (k < count) : (k += 2) {
            const a = self.window[p + k];
            const b = self.window[p + k + 1];
            self.icf[n + k / 2] = @as(u32, a) | (ICF_LITERAL + @as(u32, b)) << 10;
            self.lit_freq[a] += 1;
            self.lit_freq[b] += 1;
        }
        return n + count / 2;
    }

    /// even and dense: chain search with lazy evaluation at `p + 1` (`parseFast` handles fast).
    fn parse(self: *Encoder, start: usize, end: usize, level: Level, skip_search: bool, fresh: bool, comptime key: u4, comptime block: bool) void {
        if (fresh) {
            @memset(&self.lit_freq, 0);
            @memset(&self.dist_freq, 0);
            self.lit_freq[256] = 1;
            self.icf_count = 0;
        }
        std.debug.assert(level != .fast);
        // dense (2026-09-27): a deeper walk, no early stop below the longest match, lazy evaluation up to 32 bytes
        // with 64 candidates, and lazy2 (libdeflate's levels 8 and 9); ratio 3.595 to 3.622 at 37 MB/s.
        // even on a BGZF block (PHASE2.md): budget 32, nice 258, lazy evaluation below 32 with 16 candidates.
        const budget: usize = if (level == .dense) 160 else if (block) 32 else 12;
        const nice: usize = if (level == .dense) 258 else if (block) 258 else 96;
        const lazy_below: usize = if (level == .dense) 32 else if (block) 32 else 16;
        var p = start;
        var n = self.icf_count;
        // A literal waiting for a second one to share its token.
        var held: ?u8 = null;
        var pending: Match = .{};
        var pending_hash: usize = 0;
        var pending_pos: usize = 0;
        var literal_until: usize = 0;
        if (skip_search and !self.hasEarlyMatch(start, end, key)) search_off: {
            // Count the bytes in four tables (no store-to-load chain on repeated bytes). The search stays off only
            // for near-random bytes (at least 7.9 bits per byte of order-0 entropy): `hasEarlyMatch` sees only a
            // block's first 1 KiB, and compressible data can start later in the block.
            var counts: [4][256]u32 = @splat(@splat(0));
            var q = start;
            while (q + 4 <= end) : (q += 4) {
                counts[0][self.window[q]] += 1;
                counts[1][self.window[q + 1]] += 1;
                counts[2][self.window[q + 2]] += 1;
                counts[3][self.window[q + 3]] += 1;
            }
            while (q < end) : (q += 1) counts[0][self.window[q]] += 1;
            var total: [256]u32 = undefined;
            for (&total, 0..) |*t, b| t.* = counts[0][b] + counts[1][b] + counts[2][b] + counts[3][b];
            if (entropyBits(&total, end - start) < 7.9) break :search_off;
            // All literals: insert every fourth position, enough for `hasEarlyMatch` to find history again.
            q = start;
            while (q + 3 <= end) : (q += 4) self.insert(q, self.hash(q, end, key));
            for (0..256) |b| self.lit_freq[b] += total[b];
            q = start;
            while (q + 2 <= end) : (q += 2) {
                self.icf[n] = @as(u32, self.window[q]) | (ICF_LITERAL + @as(u32, self.window[q + 1])) << 10;
                n += 1;
            }
            if (q < end) {
                self.icf[n] = @as(u32, self.window[q]) | ICF_NONE << 10;
                n += 1;
            }
            self.icf_count = n;
            return;
        }
        while (p < end) {
            var m: Match = undefined;
            var m_hash: usize = undefined;
            if (pending.len >= 3 and pending_pos == p) {
                m = pending;
                m_hash = pending_hash;
            } else if (p < literal_until) {
                if (p + 3 <= end) m_hash = self.hash(p, end, key) else m_hash = 0;
                m = .{};
            } else if (p + 3 <= end) {
                m_hash = self.hash(p, end, key);
                m = self.find(p, end, budget, nice, m_hash);
            } else {
                m = .{};
                m_hash = 0;
            }
            if (pending_pos == p) pending = .{};
            if (p + 3 <= end) self.insert(p, m_hash);
            if (m.len >= 3 and m.len < lazy_below and p + 3 < end) {
                pending_hash = self.hash(p + 1, end, key);
                const next = self.find(p + 1, end, if (level == .dense) 64 else if (block) 16 else @min(budget, 8), nice, pending_hash);
                if (next.len > m.len) {
                    pending = next;
                    pending_pos = p + 1;
                    m.len = 2;
                } else if (level == .dense and p + 4 < end) {
                    // lazy2: p + 2 is worth two literals when its match is at least two longer.
                    const hash2 = self.hash(p + 2, end, key);
                    const next2 = self.find(p + 2, end, 16, nice, hash2);
                    if (next2.len > m.len + 1) {
                        pending = next2;
                        pending_hash = hash2;
                        pending_pos = p + 2;
                        literal_until = p + 2;
                        m.len = 2;
                    }
                }
            }
            if (m.len >= 3) {
                if (held) |byte| {
                    self.icf[n] = @as(u32, byte) | ICF_NONE << 10;
                    n += 1;
                    held = null;
                }
                const dc = distCode(m.dist);
                self.icf[n] = @as(u32, @intCast(254 + m.len)) | @as(u32, @intCast(dc)) << 10 | @as(u32, @intCast(m.dist - DIST_BASE[dc])) << 19;
                n += 1;
                self.lit_freq[257 + @as(usize, LEN_CODE[m.len - 3])] += 1;
                self.dist_freq[dc] += 1;
                const stop = p + m.len;
                p += 1;
                // A self-overlapping match (runs, short periods) repeats its last `dist` positions: insert the
                // first three and the last dist + 3 only.
                if (m.dist + 6 < m.len) {
                    const first_end = p + 3;
                    while (p < first_end) : (p += 1) self.insert(p, self.hash(p, end, key));
                    p = stop - (m.dist + 3);
                }
                while (p < stop) : (p += 1) {
                    if (p + 3 <= end) self.insert(p, self.hash(p, end, key));
                }
            } else {
                const byte = self.window[p];
                self.lit_freq[byte] += 1;
                if (held) |first| {
                    self.icf[n] = @as(u32, first) | (ICF_LITERAL + @as(u32, byte)) << 10;
                    n += 1;
                    held = null;
                } else held = byte;
                p += 1;
            }
        }
        if (held) |byte| {
            self.icf[n] = @as(u32, byte) | ICF_NONE << 10;
            n += 1;
        }
        std.debug.assert(n <= ICF_CAP);
        self.icf_count = n;
    }

    fn cost(lit_freq: *const [286]u32, dist_freq: *const [30]u32, lit: *const EncodeTree, dist: *const EncodeTree) u64 {
        var n: u64 = 0;
        for (lit_freq, 0..) |f, i| n += @as(u64, f) * (lit.lens[i] + @as(u8, if (i >= 257) LEN_EXTRA[i - 257] else 0));
        for (dist_freq, 0..) |f, i| n += @as(u64, f) * (dist.lens[i] + @as(u8, DIST_EXTRA[i]));
        return n;
    }

    /// A block's trees and its coded size, dynamic and fixed, in bits (header included, stored excluded).
    const Plan = struct {
        lit: EncodeTree = .{},
        dist: EncodeTree = .{},
        code: EncodeTree = .{},
        run: CodeRuns = .{},
        nl: usize = 286,
        nd: usize = 30,
        nc: usize = 19,
        dynamic: u64 = std.math.maxInt(u64),
        fixed: u64 = 0,

        fn init(plan: *Plan, lit_freq: *const [286]u32, dist_freq_in: *const [30]u32) void {
            plan.* = .{};
            var dist_freq = dist_freq_in.*;
            var sum: u32 = 0;
            for (dist_freq) |f| sum += f;
            if (sum == 0) dist_freq[0] = 1;
            if (plan.lit.build(lit_freq, 15) and plan.dist.build(&dist_freq, 15)) {
                while (plan.nl > 257 and plan.lit.lens[plan.nl - 1] == 0) plan.nl -= 1;
                while (plan.nd > 1 and plan.dist.lens[plan.nd - 1] == 0) plan.nd -= 1;
                var lengths: [316]u4 = undefined;
                @memcpy(lengths[0..plan.nl], plan.lit.lens[0..plan.nl]);
                @memcpy(lengths[plan.nl..][0..plan.nd], plan.dist.lens[0..plan.nd]);
                plan.run.encode(lengths[0 .. plan.nl + plan.nd]);
                if (plan.code.build(&plan.run.freq, 7)) {
                    while (plan.nc > 4 and plan.code.lens[CLEN_ORDER[plan.nc - 1]] == 0) plan.nc -= 1;
                    plan.dynamic = 3 + 5 + 5 + 4 + 3 * plan.nc + cost(lit_freq, dist_freq_in, &plan.lit, &plan.dist);
                    for (plan.run.symbols[0..plan.run.count], plan.run.widths[0..plan.run.count]) |sym, w| plan.dynamic += plan.code.lens[sym] + @as(u8, w);
                }
            }
            plan.fixed = 3 + cost(lit_freq, dist_freq_in, &FIXED_LIT, &FIXED_DIST);
        }

        fn bits(plan: *const Plan) u64 {
            return @min(plan.dynamic, plan.fixed);
        }
    };

    fn emit(self: *const Encoder, bits: *BitWriter, raw: []const u8, last: bool) EncodeError!bool {
        var plan: Plan = undefined;
        plan.init(&self.lit_freq, &self.dist_freq);
        return self.emitPlanned(bits, &plan, raw, self.icf[0..self.icf_count], last);
    }

    /// A pair of windows (window[0..RING] and window[RING..end], tokens split at `first_tokens`) as one block or
    /// two, whichever is smaller counting stored blocks: mixed data gains from separate trees, uniform data from
    /// one header. Returns whether the last block written was stored.
    fn emitPair(self: *const Encoder, bits: *BitWriter, end: usize, last: bool, first_lit: *const [286]u32, first_dist: *const [30]u32, first_tokens: usize) EncodeError!bool {
        var second_lit: [286]u32 = undefined;
        for (&second_lit, self.lit_freq, first_lit) |*d, all, first| d.* = all - first;
        second_lit[256] = 1;
        var second_dist: [30]u32 = undefined;
        for (&second_dist, self.dist_freq, first_dist) |*d, all, first| d.* = all - first;
        const estimate = struct {
            /// Coded bits under ideal codes plus extra bits, and a header allowance per used symbol (a stand-in
            /// for building the trees: about 3% of the time on BGZF blocks); capped at the stored size.
            fn of(lit_freq: *const [286]u32, dist_freq: *const [30]u32, len: usize) f64 {
                var total: f64 = 0;
                for (lit_freq) |f| total += @floatFromInt(f);
                var dist_total: f64 = 0;
                for (dist_freq) |f| dist_total += @floatFromInt(f);
                var b: f64 = 17 * 8;
                const lt = log2Table(@intFromFloat(total));
                const dt = log2Table(@intFromFloat(dist_total));
                for (lit_freq, 0..) |f, i| {
                    if (f == 0) continue;
                    const x: f64 = @floatFromInt(f);
                    b += x * (lt - log2Table(f) + @as(f64, if (i >= 257) @floatFromInt(LEN_EXTRA[i - 257]) else 0)) + 4;
                }
                for (dist_freq, 0..) |f, i| {
                    if (f == 0) continue;
                    const x: f64 = @floatFromInt(f);
                    b += x * (dt - log2Table(f) + @as(f64, @floatFromInt(DIST_EXTRA[i]))) + 4;
                }
                return @min(b, 40 + 8 * @as(f64, @floatFromInt(len)));
            }
        }.of;
        if (estimate(&self.lit_freq, &self.dist_freq, end) <= estimate(first_lit, first_dist, RING) + estimate(&second_lit, &second_dist, end - RING)) {
            var merged: Plan = undefined;
            merged.init(&self.lit_freq, &self.dist_freq);
            return self.emitPlanned(bits, &merged, self.window[0..end], self.icf[0..self.icf_count], last);
        }
        var first: Plan = undefined;
        first.init(first_lit, first_dist);
        var second: Plan = undefined;
        second.init(&second_lit, &second_dist);
        _ = try self.emitPlanned(bits, &first, self.window[0..RING], self.icf[0..first_tokens], false);
        return self.emitPlanned(bits, &second, self.window[RING..end], self.icf[first_tokens..self.icf_count], last);
    }

    /// Writes one block of `raw` as planned (or stored when smaller) from its `tokens`. Returns whether the block was
    /// stored.
    fn emitPlanned(self: *const Encoder, bits: *BitWriter, plan: *const Plan, raw: []const u8, tokens: []const u32, last: bool) EncodeError!bool {
        _ = self;
        const stored = 3 + ((8 - ((@as(usize, bits.count) + 3) & 7)) & 7) + 32 + raw.len * 8;
        if (stored < plan.fixed and stored <= plan.dynamic) {
            // A block of two windows is one byte more than a stored block holds.
            var rest = raw;
            while (true) {
                const chunk = rest[0..@min(rest.len, 65535)];
                try bits.put(@intFromBool(last and chunk.len == rest.len), 3);
                try bits.alignByte();
                var header: [4]u8 = undefined;
                const len: u16 = @intCast(chunk.len);
                std.mem.writeInt(u16, header[0..2], len, .little);
                std.mem.writeInt(u16, header[2..4], ~len, .little);
                try bits.writer.writeAll(&header);
                try bits.writer.writeAll(chunk);
                rest = rest[chunk.len..];
                if (rest.len == 0) break;
            }
            return true;
        }
        if (plan.dynamic < plan.fixed) {
            try bits.put(4 | @as(u32, @intFromBool(last)), 3);
            try bits.put(@intCast(plan.nl - 257), 5);
            try bits.put(@intCast(plan.nd - 1), 5);
            try bits.put(@intCast(plan.nc - 4), 4);
            for (CLEN_ORDER[0..plan.nc]) |sym| try bits.put(plan.code.lens[sym], 3);
            for (plan.run.symbols[0..plan.run.count], plan.run.widths[0..plan.run.count], plan.run.extras[0..plan.run.count]) |sym, w, e| {
                try bits.symbol(&plan.code, sym);
                try bits.put(e, w);
            }
            try emitIcf(tokens, bits, &plan.lit, &plan.dist);
        } else {
            try bits.put(2 | @as(u32, @intFromBool(last)), 3);
            try emitIcf(tokens, bits, &FIXED_LIT, &FIXED_DIST);
        }
        try bits.drain();
        return false;
    }

    fn emitIcf(tokens: []const u32, bits: *BitWriter, lit: *const EncodeTree, dist: *const EncodeTree) EncodeError!void {
        // First symbol: code | length << 32, a match's length extra bits merged into the code.
        var first: [513]u64 = undefined;
        for (first[0..256], 0..) |*e, s| e.* = lit.codes[s] | (@as(u64, lit.lens[s]) << 32);
        first[256] = 0;
        for (first[257..], 3..) |*e, len| {
            const l = LEN_CODE[len - 3];
            const code_len: u6 = lit.lens[257 + @as(usize, l)];
            const extra = @as(u64, len) - LEN_BASE[l];
            e.* = (lit.codes[257 + @as(usize, l)] | (extra << code_len)) | (@as(u64, code_len + LEN_EXTRA[l]) << 32);
        }
        // Second symbol: code | length << 32 | extra-bit count << 40.
        var second: [ICF_LITERAL + 256]u64 = undefined;
        for (second[0..30], 0..) |*e, c| e.* = dist.codes[c] | (@as(u64, dist.lens[c]) << 32) | (@as(u64, DIST_EXTRA[c]) << 40);
        second[ICF_NONE] = 0;
        for (second[ICF_LITERAL..], 0..) |*e, s| e.* = lit.codes[s] | (@as(u64, lit.lens[s]) << 32);
        try bits.drain();
        const w = bits.writer;
        var i: usize = 0;
        while (true) {
            // Bit buffer and output position in registers; one unconditional 8-byte store per token (at most 55
            // bits pending) while 8 bytes of room remain.
            const buf = w.buffer;
            var pos = w.end;
            var value = bits.value;
            var count: u32 = bits.count;
            std.debug.assert(count <= 7);
            // Two tokens per step: one add and one store when they fit in 56 bits together (the common case),
            // which halves the chain of dependent bit-buffer updates.
            while (i + 2 <= tokens.len and buf.len - pos >= 16) : (i += 2) {
                const c0 = icfCode(tokens[i], &first, &second);
                const c1 = icfCode(tokens[i + 1], &first, &second);
                if (c0.len + c1.len <= 56) {
                    value |= (c0.bits | (c1.bits << @intCast(c0.len))) << @intCast(count);
                    count += c0.len + c1.len;
                } else {
                    value |= c0.bits << @intCast(count);
                    count += c0.len;
                    std.mem.writeInt(u64, buf[pos..][0..8], value, .little);
                    pos += count >> 3;
                    value >>= @intCast(count & 56);
                    count &= 7;
                    value |= c1.bits << @intCast(count);
                    count += c1.len;
                }
                std.mem.writeInt(u64, buf[pos..][0..8], value, .little);
                pos += count >> 3;
                value >>= @intCast(count & 56);
                count &= 7;
            }
            while (i < tokens.len and buf.len - pos >= 8) : (i += 1) {
                const code = icfCode(tokens[i], &first, &second);
                value |= code.bits << @intCast(count);
                count += code.len;
                std.mem.writeInt(u64, buf[pos..][0..8], value, .little);
                pos += count >> 3;
                value >>= @intCast(count & 56);
                count &= 7;
            }
            w.end = pos;
            bits.value = value;
            bits.count = count;
            if (i == tokens.len) break;
            // Under 8 bytes of room: one token through the writer, which drains its buffer.
            const code = icfCode(tokens[i], &first, &second);
            i += 1;
            // `put` takes at most 16 bits; the bits above `len` are zero.
            try bits.put(@as(u16, @truncate(code.bits)), @intCast(@min(code.len, 16)));
            if (code.len > 16) try bits.put(@as(u16, @truncate(code.bits >> 16)), @intCast(@min(code.len - 16, 16)));
            if (code.len > 32) try bits.put(@as(u16, @truncate(code.bits >> 32)), @intCast(code.len - 32));
            // The register loop needs at most 7 pending bits.
            try bits.drain();
        }
        try bits.symbol(lit, 256);
    }

    const IcfCode = struct { bits: u64, len: u32 };

    /// One token's bits: at most 48 (a 20-bit length code and extra, a 28-bit distance code and extra).
    inline fn icfCode(t: u32, first: *const [513]u64, second: *const [ICF_LITERAL + 256]u64) IcfCode {
        const a = first[t & 0x3ff];
        const b = second[(t >> 10) & 0x1ff];
        const a_len: u6 = @intCast(a >> 32);
        const b_len: u6 = @intCast((b >> 32) & 0xff);
        const b_bits = (b & 0xffffffff) | (@as(u64, t >> 19) << b_len);
        return .{ .bits = (a & 0xffffffff) | (b_bits << a_len), .len = @as(u32, a_len) + b_len + @as(u32, @intCast(b >> 40)) };
    }
};

comptime {
    std.debug.assert(@sizeOf(Encoder) == 428584);
}

const TestCheck = struct {
    pub fn update(_: *TestCheck, _: []const u8) void {}
};

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

test "[property] - [deflate encoder]: BGZF block output does not depend on stale table entries" {
    // A BGZF-sized block on a workspace full of stale entries writes the same bytes as on a clean one, at every
    // preset. (A stale second slot of fast would change output only when a bucket is first used late in a block
    // and its stale position holds matching bytes, which no small input guarantees; the clear is by construction.)
    var input: [65280]u8 = undefined;
    var state: u32 = 0x85ebca6b;
    for (&input) |*byte| {
        state = state *% 1664525 +% 1013904223;
        byte.* = "AC"[state >> 31];
    }
    const clean = try std.testing.allocator.create(Encoder);
    defer std.testing.allocator.destroy(clean);
    const stale = try std.testing.allocator.create(Encoder);
    defer std.testing.allocator.destroy(stale);
    var expected: [65536 + 64]u8 = undefined;
    var actual: [65536 + 64]u8 = undefined;
    const NoCheck = struct {
        fn update(_: *@This(), _: []const u8) void {}
    };
    for ([_]Level{ .fast, .even, .dense }) |level| {
        @memset(&clean.head, 0);
        @memset(&clean.previous, 0);
        for (&stale.head, 0..) |*slot, i| slot.* = @truncate(i *% 2654435761 +% 7);
        for (&stale.previous, 0..) |*slot, i| slot.* = @truncate(i *% 40503 +% 29);
        // Two blocks in a row on each workspace: the second starts with the first one's tables.
        for ([_]usize{ input.len, 20000 }) |len| {
            var want_writer = std.Io.Writer.fixed(&expected);
            var want_check: NoCheck = .{};
            try clean.encodeBlock(NoCheck, input[0..len], &want_writer, &want_check, level);
            var got_writer = std.Io.Writer.fixed(&actual);
            var got_check: NoCheck = .{};
            try stale.encodeBlock(NoCheck, input[0..len], &got_writer, &got_check, level);
            try std.testing.expectEqualSlices(u8, want_writer.buffered(), got_writer.buffered());
        }
    }
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
    for ([_]Level{ .fast, .even, .dense }) |level| {
        @memset(&clean.head, 0);
        @memset(&clean.previous, 0);
        for (&stale.head, 0..) |*slot, i| slot.* = @truncate(i *% 2654435761 +% 99);
        for (&stale.previous, 0..) |*slot, i| slot.* = @truncate(i *% 40503 +% 17);
        // Two streams in a row on each workspace: the second starts with the first one's chains.
        for ([_]usize{ input.len, RING / 3 }) |len| {
            var want_writer = std.Io.Writer.fixed(&expected);
            var want_check: NoCheck = .{};
            try clean.encodeSlice(NoCheck, input[0..len], &want_writer, &want_check, level, false);
            var got_writer = std.Io.Writer.fixed(&actual);
            var got_check: NoCheck = .{};
            try stale.encodeSlice(NoCheck, input[0..len], &got_writer, &got_check, level, false);
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
