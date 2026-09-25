//! BGZF (SAM specification 4.1): gzip members of at most 64 KiB whose `BC` extra subfield records their size.

const std = @import("std");
const engine = @import("../deflate/deflate.zig");
const crc = @import("../kernel/crc32.zig");
const gzip = @import("gzip.zig");

pub const Error = gzip.Error || error{ NotBgzf, BadBlockSize, BlockSizeMismatch, BlockTooLarge, MissingEofMarker, BadVirtualOffset };

pub const MAX_BLOCK = 65536;

pub const EOF_MARKER = [28]u8{ 0x1f, 0x8b, 8, 4, 0, 0, 0, 0, 0, 0xff, 6, 0, 'B', 'C', 2, 0, 0x1b, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

pub const VirtualOffset = packed struct(u64) { uoffset: u16, coffset: u48 };

pub const Block = struct { coffset: u64, size: u32, data_size: u32 };

pub const ScanOptions = struct {
    trailing_data: engine.TrailingData = .reject,
    require_eof_marker: bool = false,
};

pub const ReaderOptions = struct {
    max_output_bytes: u64 = std.math.maxInt(u64),
    trailing_data: engine.TrailingData = .reject,
    require_eof_marker: bool = false,
};

pub const Summary = struct { bytes: u64, blocks: u64, eof_marker: bool };

/// Reader capacity must be >=16; with a positional `std.Io.File.Reader`, block bodies are skipped by seeking.
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
    pub fn next(self: *Scanner) Error!?Block {
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

    fn end(self: *Scanner, empty: bool) Error!?Block {
        if (!empty) return if (self.coffset == 0) error.Truncated else if (self.options.trailing_data == .leave) self.finishScan() else error.TrailingData;
        if (self.coffset == 0) return error.Truncated;
        return self.finishScan();
    }

    fn finishScan(self: *Scanner) Error!?Block {
        self.done = true;
        if (self.options.require_eof_marker and !self.eof_marker) return error.MissingEofMarker;
        return null;
    }
};

/// Reusable without initialization, including after errors. No allocation occurs during decode.
/// Assumes reader, writer and workspace storage do not overlap; overlap is not checked. One active call per workspace.
pub const Reader = struct {
    decoder: engine.Decoder = .{},

    /// Reader capacity must be >=28, the EOF marker's length, so the marker is compared byte for byte.
    /// Caller flushes writer. Output is provisional until success. Every block's decoded size is capped at
    /// 65536 whatever its ISIZE claims.
    pub fn decompress(self: *Reader, reader: *std.Io.Reader, writer: *std.Io.Writer, options: ReaderOptions) Error!Summary {
        if (reader.buffer.len < EOF_MARKER.len) return error.InputBufferTooSmall;
        var br: engine.BitReader = .{ .reader = reader };
        defer br.release();
        var session = self.decoder.session(crc.Crc32, writer, .{ .max_output_bytes = options.max_output_bytes });
        session.stream_limit = MAX_BLOCK;
        var summary: Summary = .{ .bytes = 0, .blocks = 0, .eof_marker = false };
        while (true) {
            _ = try br.window(2);
            if (br.src.len == 0 and summary.blocks != 0) break;
            if (br.src.len < 2 or br.src[0] != 0x1f or br.src[1] != 0x8b) {
                if (summary.blocks != 0) {
                    if (options.trailing_data == .leave) break;
                    return error.TrailingData;
                }
                if (br.src.len < 2) return error.Truncated;
                return error.NotBgzf;
            }
            const block = try readBlock(&br, &session, options.max_output_bytes - summary.bytes);
            summary.bytes += block.size;
            summary.blocks += 1;
            summary.eof_marker = block.eof_marker;
        }
        if (options.require_eof_marker and !summary.eof_marker) return error.MissingEofMarker;
        _ = try session.finish();
        return summary;
    }

    /// `offset.coffset` must be a block start. `offset.uoffset` decoded bytes of that block are skipped, then
    /// up to `length` bytes are written, continuing into later blocks; fewer only at the end of the data.
    /// Decoding stops after the block that completes the range, so later blocks are not checked.
    /// Reader capacity must be >=28. Caller flushes writer.
    pub fn readAt(self: *Reader, source: *std.Io.File.Reader, offset: VirtualOffset, writer: *std.Io.Writer, length: u64) Error!u64 {
        if (source.interface.buffer.len < EOF_MARKER.len) return error.InputBufferTooSmall;
        if (length == 0) return 0;
        source.seekTo(offset.coffset) catch return error.ReadFailed;
        var window: Window = .{ .inner = writer, .skip = offset.uoffset, .left = length };
        var br: engine.BitReader = .{ .reader = &source.interface };
        defer br.release();
        var session = self.decoder.session(crc.Crc32, &window.writer, .{});
        session.stream_limit = MAX_BLOCK;
        var first = true;
        var decoded: u64 = 0;
        while (decoded < offset.uoffset +| length) {
            _ = try br.window(2);
            if (br.src.len < 2 or br.src[0] != 0x1f or br.src[1] != 0x8b) {
                if (first) return error.BadVirtualOffset;
                if (br.src.len == 0) break;
                return error.TrailingData;
            }
            const block = readBlock(&br, &session, std.math.maxInt(u64)) catch |err| {
                if (first and isHeaderError(err)) return error.BadVirtualOffset;
                return err;
            };
            if (first and block.size < offset.uoffset) return error.BadVirtualOffset;
            first = false;
            decoded += block.size;
        }
        _ = try session.finish();
        return length - window.left;
    }
};

comptime {
    std.debug.assert(@sizeOf(Reader) == 196608);
}

/// Reusable without initialization, including after errors. No allocation occurs during decode.
pub const BlockDecoder = struct {
    decoder: engine.Decoder = .{},

    /// `block` is one whole block; the result is its decoded length.
    pub fn decodeBlock(self: *BlockDecoder, block: []const u8, out: *[MAX_BLOCK]u8) Error!usize {
        if (block.len < EOF_MARKER.len) return error.BadBlockSize;
        var reader = std.Io.Reader.fixed(block);
        var br: engine.BitReader = .{ .reader = &reader };
        var writer = std.Io.Writer.fixed(out);
        var session = self.decoder.session(crc.Crc32, &writer, .{});
        session.stream_limit = MAX_BLOCK;
        const decoded = try readBlock(&br, &session, std.math.maxInt(u64));
        _ = try session.finish();
        if (decoded.block_size != block.len) return error.BlockSizeMismatch;
        return decoded.size;
    }
};

comptime {
    std.debug.assert(@sizeOf(BlockDecoder) == 196608);
}

fn readAll(r: *std.Io.Reader, out: []u8) Error!void {
    r.readSliceAll(out) catch |err| return switch (err) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.ReadFailed,
    };
}

fn discardAll(r: *std.Io.Reader, n: usize) Error!void {
    r.discardAll(n) catch |err| return switch (err) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.ReadFailed,
    };
}

fn isHeaderError(err: Error) bool {
    return switch (err) {
        error.NotBgzf, error.BadHeader, error.UnsupportedMethod, error.ReservedFlag, error.HeaderCrcMismatch, error.BadBlockSize => true,
        else => false,
    };
}

const Decoded = struct { size: u64, block_size: u64, eof_marker: bool };

const BlockVisitor = struct {
    bsize: ?u16 = null,
    bc: [2]u8 = undefined,

    pub fn subfield(self: *BlockVisitor, id: [2]u8, len: u16, offset: u16, bytes: []const u8) error{}!void {
        if (self.bsize != null or id[0] != 'B' or id[1] != 'C' or len != 2) return;
        @memcpy(self.bc[offset..][0..bytes.len], bytes);
        if (offset + bytes.len == 2) self.bsize = std.mem.readInt(u16, &self.bc, .little);
    }
};

// `room` is what the caller's output limit still allows: a block that outgrows 65536 bytes is
// `BlockTooLarge` unless the caller's limit is what stopped it.
fn readBlock(br: *engine.BitReader, session: *engine.Session(crc.Crc32), room: u64) Error!Decoded {
    const start = br.consumed();
    const marker = blk: {
        if (br.src.len - br.i < EOF_MARKER.len and !try br.window(EOF_MARKER.len)) break :blk false;
        break :blk std.mem.eql(u8, br.src[br.i..][0..EOF_MARKER.len], &EOF_MARKER);
    };
    var visitor: BlockVisitor = .{};
    try gzip.parseHeader(br, BlockVisitor, &visitor);
    const block_size = @as(u64, visitor.bsize orelse return error.NotBgzf) + 1;
    if (block_size < br.consumed() - start + 2 + 8) return error.BadBlockSize;
    var check: crc.Crc32 = .init();
    const size = session.stream(br, &check) catch |err| switch (err) {
        error.OutputLimitExceeded => return if (room > MAX_BLOCK) error.BlockTooLarge else error.OutputLimitExceeded,
        else => |e| return e,
    };
    if (br.consumed() - start + 8 != block_size) return error.BlockSizeMismatch;
    try gzip.readTrailer(br, check.final(), size);
    return .{ .size = size, .block_size = block_size, .eof_marker = marker };
}

// Drops the first `skip` bytes, passes on at most `left`, and drops the rest.
const Window = struct {
    writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
    inner: *std.Io.Writer,
    skip: u64,
    left: u64,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Window = @alignCast(@fieldParentPtr("writer", w));
        var total: usize = 0;
        for (data, 0..) |bytes, i| {
            for (0..if (i + 1 == data.len) splat else 1) |_| {
                total += bytes.len;
                var rest = bytes;
                const skipped: usize = @intCast(@min(self.skip, rest.len));
                self.skip -= skipped;
                rest = rest[skipped..];
                const n: usize = @intCast(@min(self.left, rest.len));
                try self.inner.writeAll(rest[0..n]);
                self.left -= n;
            }
        }
        return total;
    }
};
