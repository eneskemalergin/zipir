//! BGZF (SAM specification 4.1): BGZF blocks, gzip members of at most 64 KiB whose `BC` extra subfield records
//! their size, ended by an empty 28-byte block (the EOF marker); `.gzi` indexes map uncompressed offsets to blocks.

const std = @import("std");
const decode = @import("../engine/decode.zig");
const encode = @import("../engine/encode.zig");
const codes = @import("../engine/codes.zig");
const crc = @import("../kernel/crc32.zig");
const gzip = @import("gzip.zig");
const stream_reader = @import("../stream/reader.zig");

pub const DecompressError = gzip.DecompressError || error{ NotBgzf, BadBlockSize, BlockSizeMismatch, BlockTooLarge, MissingEofMarker, BadVirtualOffset, BadIndex };

pub const MAX_BLOCK = 65536;

pub const BLOCK_INPUT = 65280;

pub const EOF_MARKER = [28]u8{ 0x1f, 0x8b, 8, 4, 0, 0, 0, 0, 0, 0xff, 6, 0, 'B', 'C', 2, 0, 0x1b, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

pub const VirtualOffset = packed struct(u64) { uoffset: u16, coffset: u48 };

pub const Block = struct { coffset: u64, size: u32, data_size: u32 };

pub const ScanOptions = struct {
    trailing_data: stream_reader.TrailingData = .reject,
    require_eof_marker: bool = false,
};

pub const DecompressOptions = struct {
    /// More decoded output than this is `OutputLimitExceeded`.
    max_output_bytes: u64 = std.math.maxInt(u64),
    trailing_data: stream_reader.TrailingData = .reject,
    /// Input that does not end with the EOF marker is `MissingEofMarker`; either way `framing.eof_marker` tells.
    require_eof_marker: bool = false,
};

/// Reads BGZF block headers and trailers without decoding. Input reader capacity must be at least 16 bytes; with a
/// positional `std.Io.File.Reader`, block bodies are skipped by seeking.
pub fn scan(reader: *std.Io.Reader, options: ScanOptions) Scanner {
    return .{ .reader = reader, .options = options };
}

/// `eof_marker` tells whether the last block returned so far is the 28-byte EOF marker.
pub const Scanner = struct {
    reader: *std.Io.Reader,
    options: ScanOptions,
    coffset: u64 = 0,
    eof_marker: bool = false,
    done: bool = false,

    /// Null after the last block; the input must end exactly at a block boundary.
    pub fn next(self: *Scanner) DecompressError!?Block {
        if (self.done) return null;
        const r = self.reader;
        if (r.buffer.len < 16) return error.InputBufferTooSmall;
        const head = r.peek(2) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => return self.end(r.buffered().len == 0),
        };
        if (head[0] != 0x1f or head[1] != 0x8b) {
            if (self.coffset == 0) return error.NotBgzf;
            if (self.options.trailing_data == .leave) return self.end(true);
            return error.TrailingData;
        }
        var fixed: [12]u8 = undefined;
        try readAll(r, &fixed);
        if (fixed[2] != 8) return error.UnsupportedMethod;
        if (fixed[3] & 0xe0 != 0) return error.ReservedFlag;
        if (fixed[3] & 4 == 0) return error.NotBgzf;
        const xlen = std.mem.readInt(u16, fixed[10..12], .little);
        var bsize: ?u16 = null;
        var left: usize = xlen;
        while (left != 0) {
            if (left < 4) return error.BadHeader;
            var sub: [4]u8 = undefined;
            try readAll(r, &sub);
            const len = std.mem.readInt(u16, sub[2..4], .little);
            left -= 4;
            if (len > left) return error.BadHeader;
            if (bsize == null and sub[0] == 'B' and sub[1] == 'C' and len == 2) {
                var value: [2]u8 = undefined;
                try readAll(r, &value);
                bsize = std.mem.readInt(u16, &value, .little);
            } else try discardAll(r, len);
            left -= len;
        }
        const size = @as(u32, bsize orelse return error.NotBgzf) + 1;
        const header_len = 12 + @as(u32, xlen);
        if (size < header_len + 2 + 8) return error.BadBlockSize;
        var tail: [10]u8 = undefined;
        const marker_header = xlen == 6 and bsize.? == EOF_MARKER.len - 1 and std.mem.eql(u8, &fixed, EOF_MARKER[0..12]);
        const tail_len: u32 = if (size == EOF_MARKER.len) 10 else 4;
        try discardAll(r, size - header_len - tail_len);
        try readAll(r, tail[0..tail_len]);
        const data_size = std.mem.readInt(u32, tail[tail_len - 4 ..][0..4], .little);
        if (data_size > MAX_BLOCK) return error.BlockTooLarge;
        self.eof_marker = marker_header and size == EOF_MARKER.len and std.mem.eql(u8, &tail, EOF_MARKER[18..]);
        const block: Block = .{ .coffset = self.coffset, .size = size, .data_size = data_size };
        self.coffset += size;
        return block;
    }

    fn end(self: *Scanner, empty: bool) DecompressError!?Block {
        if (!empty) return if (self.coffset == 0) error.Truncated else if (self.options.trailing_data == .leave) self.finishScan() else error.TrailingData;
        if (self.coffset == 0) return error.Truncated;
        return self.finishScan();
    }

    fn finishScan(self: *Scanner) DecompressError!?Block {
        self.done = true;
        if (self.options.require_eof_marker and !self.eof_marker) return error.MissingEofMarker;
        return null;
    }
};

/// Decodes BGZF blocks; a block's bytes become readable only after its size fields, CRC-32, and ISIZE are
/// checked, and every block's decoded size is capped at 65536 whatever its ISIZE claims. `init(input, options)`
/// starts it in place; `reader` gives the decoded bytes and `err` the reason for a `ReadFailed`;
/// `framing.blocks` and `framing.eof_marker` tell what was read. Over a `std.Io.File.Reader`, `seek` moves
/// to a virtual offset and `seekUncompressed` to an uncompressed one through `.gzi` entries. Input reader
/// capacity must be at least 28 bytes, the EOF marker's length. A peek of up to 64 KiB always fits. No allocation
/// occurs.
pub const Decompressor = stream_reader.Decompressor(DecompressFraming);

const DecompressFraming = struct {
    pub const Check = crc.Crc32;
    pub const DecompressOptions = format.DecompressOptions;
    pub const DecompressError = format.DecompressError;
    pub const min_input_buffer = EOF_MARKER.len;
    pub const max_stream_bytes = MAX_BLOCK;

    options: format.DecompressOptions,
    /// Blocks read so far.
    blocks: u64 = 0,
    /// Whether the last block read is the 28-byte EOF marker.
    eof_marker: bool = false,
    // After a seek, a first block that is not one is `BadVirtualOffset`.
    seeking: bool = false,
    first_size: u64 = 0,
    current: BlockHeader = undefined,

    pub fn init(options: format.DecompressOptions) DecompressFraming {
        return .{ .options = options };
    }

    pub fn header(self: *DecompressFraming, br: *decode.BitReader) format.DecompressError!bool {
        _ = try br.refill(2);
        if (br.src.len < 2 or br.src[0] != 0x1f or br.src[1] != 0x8b) {
            if (self.blocks == 0) {
                if (self.seeking) return error.BadVirtualOffset;
                if (br.src.len < 2) return error.Truncated;
                return error.NotBgzf;
            }
            if (br.src.len != 0 and self.options.trailing_data == .reject) return error.TrailingData;
            if (self.options.require_eof_marker and !self.eof_marker) return error.MissingEofMarker;
            return false;
        }
        self.current = readBlockHeader(br) catch |err| {
            if (self.seeking and self.blocks == 0 and isHeaderError(err)) return error.BadVirtualOffset;
            return err;
        };
        return true;
    }

    pub fn trailer(self: *DecompressFraming, br: *decode.BitReader, check: *Check, size: u64) format.DecompressError!void {
        try readBlockTrailer(br, self.current, check.final(), size);
        if (self.blocks == 0) self.first_size = size;
        self.blocks += 1;
        self.eof_marker = self.current.marker;
    }

    // A block that outgrows 65536 bytes is `BlockTooLarge` unless the caller's output limit is what stopped it.
    pub fn streamError(self: *const DecompressFraming, err: format.DecompressError, start: u64) format.DecompressError {
        if (err == error.OutputLimitExceeded and self.options.max_output_bytes - start > MAX_BLOCK) return error.BlockTooLarge;
        return err;
    }
};

const format = @This();

/// Reusable without initialization, including after errors. No allocation occurs during decode.
pub const BlockDecoder = struct {
    decoder: decode.Decoder = .{},

    /// `block` is one whole block; the result is its decoded length.
    pub fn decodeBlock(self: *BlockDecoder, block: []const u8, out: *[MAX_BLOCK]u8) DecompressError!usize {
        if (block.len < EOF_MARKER.len) return error.BadBlockSize;
        var reader = std.Io.Reader.fixed(block);
        var br: decode.BitReader = .{ .reader = &reader };
        const header = try readBlockHeader(&br);
        var check: crc.Crc32 = .init();
        var session: decode.Session(crc.Crc32) = .{ .decoder = &self.decoder, .max_output_bytes = std.math.maxInt(u64), .max_stream_bytes = MAX_BLOCK };
        session.begin(&br, &check);
        // The buffer holds more than a block, so the cap ends a block that is too large first.
        if (try mapBlockError(session.run()) != .end) unreachable;
        const size = session.out_pos;
        try readBlockTrailer(&br, header, check.final(), size);
        if (header.block_size != block.len) return error.BlockSizeMismatch;
        @memcpy(out[0..size], self.decoder.buffer[0..size]);
        return size;
    }
};

comptime {
    std.debug.assert(@sizeOf(BlockDecoder) == 196608);
}

pub const Split = enum { fill, lines };

/// `.fill` makes blocks of 65280 bytes; `.lines` gives exactly the uncompressed
/// boundaries of `bgzip` 1.24 on text: blocks end after the last newline of each read window, leading `#`
/// or `@` header lines get their own blocks, and a line longer than a block continues in the next one.
/// The index of the last '\n' in `bytes`, 32 bytes at a time from the end (`std.mem.lastIndexOfScalar` compares
/// one byte per step, which cost a text block with no newline more than compressing it).
fn lastNewline(bytes: []const u8) ?usize {
    const V = @Vector(32, u8);
    var end = bytes.len;
    while (end >= 32) {
        const chunk: V = bytes[end - 32 ..][0..32].*;
        const mask: u32 = @bitCast(chunk == @as(V, @splat('\n')));
        if (mask != 0) return end - 32 + (31 - @clz(mask));
        end -= 32;
    }
    return std.mem.lastIndexOfScalar(u8, bytes[0..end], '\n');
}

pub const BlockSplitter = struct {
    split: Split,
    in_header: bool = true,
    long_line: bool = false,
    // Bytes at the start of `available` already written into the open block, and whether it then ends.
    carry: usize = 0,
    carry_ends: bool = false,
    // Bytes after `carry` that bgzip keeps from its previous read window.
    leftover: usize = 0,
    draining: bool = false,

    pub const LOOKAHEAD = 2 * BLOCK_INPUT;

    pub fn init(split: Split) BlockSplitter {
        return .{ .split = split };
    }

    /// The length of the next block, which starts at `available[0]`; null when `available` is empty or,
    /// unless `at_end`, shorter than `LOOKAHEAD`. Never 0.
    pub fn next(self: *BlockSplitter, available: []const u8, at_end: bool) ?usize {
        if (available.len == 0) return null;
        if (!at_end and available.len < LOOKAHEAD) return null;
        return switch (self.split) {
            .fill => @min(available.len, BLOCK_INPUT),
            .lines => self.lines(available, at_end),
        };
    }

    fn reset(self: *BlockSplitter) void {
        self.carry = 0;
        self.carry_ends = false;
        self.leftover = 0;
        self.draining = false;
    }

    // One pass of bgzip's text loop per read window: write `n` bytes into the open block (which closes when
    // it reaches 65280 bytes) and close it after them when `flush` is set.
    fn lines(self: *BlockSplitter, available: []const u8, at_end: bool) usize {
        if (self.draining) return @min(available.len, BLOCK_INPUT);
        var open = self.carry;
        if (self.carry_ends) {
            self.carry = 0;
            self.carry_ends = false;
            return open;
        }
        while (true) {
            const window = available[open..@min(available.len, open + BLOCK_INPUT)];
            if (window.len == self.leftover and at_end) {
                // bgzip's read returns nothing new: it writes what it kept, then closing flushes.
                self.carry = 0;
                self.leftover = 0;
                self.draining = true;
                return @min(available.len, BLOCK_INPUT);
            }
            var n: usize = undefined;
            var flush = false;
            if (self.in_header and (self.long_line or window[0] == '@' or window[0] == '#')) {
                var last_start: usize = 0;
                var i: usize = 0;
                while (std.mem.indexOfScalarPos(u8, window, i, '\n')) |newline| {
                    i = newline + 1;
                    last_start = i;
                    if (i < window.len and window[i] != '@' and window[i] != '#') {
                        self.in_header = false;
                        break;
                    }
                }
                self.long_line = last_start == 0;
                n = if (last_start == 0) window.len else last_start;
                flush = last_start != 0;
            } else if (lastNewline(window)) |last| {
                n = last + 1;
                flush = true;
            } else n = window.len;
            self.leftover = window.len - n;
            if (open + n >= BLOCK_INPUT) {
                self.carry = open + n - BLOCK_INPUT;
                self.carry_ends = flush and self.carry != 0;
                return BLOCK_INPUT;
            }
            open += n;
            if (flush) {
                self.carry = 0;
                return open;
            }
        }
    }
};

/// Reusable without initialization. No allocation occurs during compression.
pub const BlockEncoder = struct {
    encoder: encode.Encoder = .{},

    /// Asserts `input.len <= 65280`; the result is the block's length in `out`.
    pub fn compressBlock(self: *BlockEncoder, input: []const u8, out: *[MAX_BLOCK]u8, preset: encode.Preset) usize {
        std.debug.assert(input.len <= BLOCK_INPUT);
        var body = std.Io.Writer.fixed(out[HEADER_LEN .. MAX_BLOCK - 8]);
        var check: crc.Crc32 = .init();
        // 65280 input bytes compress to at most 65291 (two stored blocks at worst), which fits `body`,
        // and a fixed writer of that size cannot fail.
        self.encoder.encodeBlock(crc.Crc32, input, &body, &check, preset) catch unreachable;
        const size = HEADER_LEN + body.end + 8;
        var subfield = [6]u8{ 'B', 'C', 2, 0, 0, 0 };
        std.mem.writeInt(u16, subfield[4..6], @intCast(size - 1), .little);
        var header = std.Io.Writer.fixed(out[0..HEADER_LEN]);
        gzip.writeHeader(&header, &subfield) catch unreachable;
        std.mem.writeInt(u32, out[size - 8 ..][0..4], check.final(), .little);
        std.mem.writeInt(u32, out[size - 4 ..][0..4], @intCast(input.len), .little);
        return size;
    }
};

comptime {
    std.debug.assert(@sizeOf(BlockEncoder) == 428584);
}

pub const CompressOptions = struct {
    preset: encode.Preset = .even,
    split: Split = .fill,
    index: ?*IndexBuilder = null,
};

pub const CompressError = error{ WriteFailed, IndexFull };

pub const Totals = struct { uncompressed: u64, compressed: u64 };

/// Writes BGZF: `init(output, options)` starts it in place, plain bytes go to `writer` in any sizes (block
/// boundaries depend only on the bytes), `flush` ends the open block so the next byte starts one (a record
/// boundary; the output writer is not flushed), and `finish` writes the rest and the EOF marker. `err` tells why
/// `writer` failed: `IndexFull`, or `WriteFailed` from the output writer. Input is staged in two blocks' worth
/// of memory so that `.lines` sees as far ahead as `bgzip` does, plus 32 KiB so a contiguous request of up to
/// 32 KiB always fits. No allocation occurs.
pub const Compressor = struct {
    writer: std.Io.Writer,
    err: ?CompressError,
    encoder: BlockEncoder,
    staging: [BlockSplitter.LOOKAHEAD + codes.WINDOW]u8,
    block: [MAX_BLOCK]u8,
    splitter: BlockSplitter,
    preset: encode.Preset,
    index: ?*IndexBuilder,
    out: *std.Io.Writer,
    compressed: u64,
    uncompressed: u64,

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = flush,
        .rebase = rebase,
    };

    /// Starts a stream into `output`, resetting everything. The workspace must stay at this address while
    /// `writer` is used: the writer's buffer is inside it. It cannot fail; the error union matches the other
    /// formats' compressors.
    pub fn init(self: *Compressor, output: *std.Io.Writer, options: CompressOptions) std.Io.Writer.Error!void {
        self.writer = .{ .vtable = &vtable, .buffer = &self.staging, .end = 0 };
        self.err = null;
        self.splitter = .init(options.split);
        self.preset = options.preset;
        self.index = options.index;
        self.out = output;
        self.compressed = 0;
        self.uncompressed = 0;
    }

    /// Writes what is staged and the EOF marker; the writer then fails until `init`. The caller flushes the
    /// output writer.
    pub fn finish(self: *Compressor) std.Io.Writer.Error!Totals {
        if (self.err != null) return error.WriteFailed;
        errdefer self.writer = .failing;
        try self.endBlock();
        self.out.writeAll(&EOF_MARKER) catch return self.fail(error.WriteFailed);
        self.compressed += EOF_MARKER.len;
        self.writer = .failing;
        return .{ .uncompressed = self.uncompressed, .compressed = self.compressed };
    }

    fn parent(w: *std.Io.Writer) *Compressor {
        return @alignCast(@fieldParentPtr("writer", w));
    }

    fn fail(self: *Compressor, err: CompressError) error{WriteFailed} {
        self.err = err;
        self.writer = .failing;
        return error.WriteFailed;
    }

    // Writes every block whose boundary is decided: with a full lookahead, or all of it when `at_end`.
    fn emitReady(self: *Compressor, comptime at_end: bool) std.Io.Writer.Error!void {
        const w = &self.writer;
        while (at_end or w.end >= BlockSplitter.LOOKAHEAD) {
            const len = self.splitter.next(self.staging[0..w.end], at_end) orelse return;
            const size = self.encoder.compressBlock(self.staging[0..len], &self.block, self.preset);
            self.out.writeAll(self.block[0..size]) catch return self.fail(error.WriteFailed);
            if (self.index) |index| index.add(self.compressed, @intCast(len)) catch |err| return self.fail(err);
            self.compressed += size;
            self.uncompressed += len;
            @memmove(self.staging[0 .. w.end - len], self.staging[len..w.end]);
            w.end -= len;
        }
    }

    fn endBlock(self: *Compressor) std.Io.Writer.Error!void {
        try self.emitReady(true);
        self.splitter.reset();
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self = parent(w);
        var consumed: usize = 0;
        copy: {
            for (data[0 .. data.len - 1]) |bytes| {
                const n = take(w, bytes);
                consumed += n;
                if (n < bytes.len) break :copy;
            }
            const pattern = data[data.len - 1];
            for (0..splat) |_| {
                const n = take(w, pattern);
                consumed += n;
                if (n < pattern.len) break :copy;
            }
        }
        try self.emitReady(false);
        return consumed;
    }

    fn take(w: *std.Io.Writer, bytes: []const u8) usize {
        const n = @min(bytes.len, w.buffer.len - w.end);
        @memcpy(w.buffer[w.end..][0..n], bytes[0..n]);
        w.end += n;
        return n;
    }

    fn rebase(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
        const self = parent(w);
        if (w.buffer.len - w.end >= capacity) return;
        // Room comes only from writing whole blocks, whose lengths are not known ahead: preserving bytes
        // through that is not offered.
        if (preserve != 0 or w.end < BlockSplitter.LOOKAHEAD) return error.WriteFailed;
        try self.emitReady(false);
        if (w.buffer.len - w.end < capacity) return error.WriteFailed;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        return parent(w).endBlock();
    }
};

pub const IndexEntry = struct { coffset: u64, uoffset: u64 };

/// Caller-owned storage for `.gzi` entries, filled as htslib does: one per block that holds data, except
/// the first. Blocks are added in file order, from `Scanner.next` or through `WriterOptions.index`.
pub const IndexBuilder = struct {
    entries: []IndexEntry,
    len: usize = 0,
    uoffset: u64 = 0,
    seen_data: bool = false,

    pub fn init(entries: []IndexEntry) IndexBuilder {
        return .{ .entries = entries };
    }

    pub fn add(self: *IndexBuilder, coffset: u64, data_size: u32) error{IndexFull}!void {
        if (data_size == 0) return;
        if (self.seen_data) {
            if (self.len == self.entries.len) return error.IndexFull;
            self.entries[self.len] = .{ .coffset = coffset, .uoffset = self.uoffset };
            self.len += 1;
        }
        self.seen_data = true;
        self.uoffset += data_size;
    }

    pub fn slice(self: *const IndexBuilder) []const IndexEntry {
        return self.entries[0..self.len];
    }
};

/// The `.gzi` layout: the entry count, then each entry, as little-endian u64s.
pub fn writeIndex(writer: *std.Io.Writer, entries: []const IndexEntry) std.Io.Writer.Error!void {
    try writer.writeInt(u64, entries.len, .little);
    for (entries) |entry| {
        try writer.writeInt(u64, entry.coffset, .little);
        try writer.writeInt(u64, entry.uoffset, .little);
    }
}

/// Entries are streamed, never held whole. They must increase strictly in both
/// offsets and point inside a BGZF file of `file_size` bytes; anything else, or a short file, is `BadIndex`.
pub const IndexReader = struct {
    reader: *std.Io.Reader,
    file_size: u64,
    remaining: u64,
    previous: IndexEntry = .{ .coffset = 0, .uoffset = 0 },

    pub fn init(reader: *std.Io.Reader, file_size: u64) DecompressError!IndexReader {
        var count: [8]u8 = undefined;
        try readIndexBytes(reader, &count);
        return .{ .reader = reader, .file_size = file_size, .remaining = std.mem.readInt(u64, &count, .little) };
    }

    pub fn next(self: *IndexReader) DecompressError!?IndexEntry {
        if (self.remaining == 0) {
            var extra: [1]u8 = undefined;
            const n = self.reader.readSliceShort(&extra) catch return error.ReadFailed;
            if (n != 0) return error.BadIndex;
            return null;
        }
        var bytes: [16]u8 = undefined;
        try readIndexBytes(self.reader, &bytes);
        const entry: IndexEntry = .{ .coffset = std.mem.readInt(u64, bytes[0..8], .little), .uoffset = std.mem.readInt(u64, bytes[8..16], .little) };
        if (entry.coffset <= self.previous.coffset or entry.uoffset <= self.previous.uoffset or entry.coffset >= self.file_size) return error.BadIndex;
        self.previous = entry;
        self.remaining -= 1;
        return entry;
    }
};

const HEADER_LEN = 18;

fn readIndexBytes(r: *std.Io.Reader, out: []u8) DecompressError!void {
    r.readSliceAll(out) catch |err| return switch (err) {
        error.EndOfStream => error.BadIndex,
        error.ReadFailed => error.ReadFailed,
    };
}

fn readAll(r: *std.Io.Reader, out: []u8) DecompressError!void {
    r.readSliceAll(out) catch |err| return switch (err) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.ReadFailed,
    };
}

fn discardAll(r: *std.Io.Reader, n: usize) DecompressError!void {
    r.discardAll(n) catch |err| return switch (err) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.ReadFailed,
    };
}

fn isHeaderError(err: DecompressError) bool {
    return switch (err) {
        error.NotBgzf, error.BadHeader, error.UnsupportedMethod, error.ReservedFlag, error.HeaderCrcMismatch, error.BadBlockSize => true,
        else => false,
    };
}

// Where a BGZF block starts in the input, its size from `BC`, and whether it is the EOF marker.
const BlockHeader = struct { start: u64, block_size: u64, marker: bool };

fn mapBlockError(result: decode.DecodeError!decode.Stop) DecompressError!decode.Stop {
    return result catch |err| if (err == error.OutputLimitExceeded) error.BlockTooLarge else err;
}

const BlockVisitor = struct {
    bsize: ?u16 = null,
    bc: [2]u8 = undefined,

    pub fn subfield(self: *BlockVisitor, id: [2]u8, len: u16, offset: u16, bytes: []const u8) error{}!void {
        if (self.bsize != null or id[0] != 'B' or id[1] != 'C' or len != 2) return;
        @memcpy(self.bc[offset..][0..bytes.len], bytes);
        if (offset + bytes.len == 2) self.bsize = std.mem.readInt(u16, &self.bc, .little);
    }
};

// Reads a BGZF block's gzip header, which must carry the `BC` subfield giving the block's size.
fn readBlockHeader(br: *decode.BitReader) DecompressError!BlockHeader {
    const start = br.consumed();
    const marker = blk: {
        if (br.src.len - br.i < EOF_MARKER.len and !try br.refill(EOF_MARKER.len)) break :blk false;
        break :blk std.mem.eql(u8, br.src[br.i..][0..EOF_MARKER.len], &EOF_MARKER);
    };
    var visitor: BlockVisitor = .{};
    try gzip.readHeader(br, BlockVisitor, &visitor, std.math.maxInt(u64));
    const block_size = @as(u64, visitor.bsize orelse return error.NotBgzf) + 1;
    if (block_size < br.consumed() - start + 2 + 8) return error.BadBlockSize;
    return .{ .start = start, .block_size = block_size, .marker = marker };
}

// After the block's DEFLATE data: its end must be where `BC` said, then CRC-32 and ISIZE.
fn readBlockTrailer(br: *decode.BitReader, header: BlockHeader, crc_value: u32, size: u64) DecompressError!void {
    if (br.consumed() - header.start + 8 != header.block_size) return error.BlockSizeMismatch;
    try gzip.readTrailer(br, crc_value, size);
}
