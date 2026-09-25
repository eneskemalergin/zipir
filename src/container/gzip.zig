//! Bounded gzip compression and decompression through caller-owned readers and writers.

const std = @import("std");
const engine = @import("../deflate/deflate.zig");
const crc = @import("../kernel/crc32.zig");

pub const Error = engine.Error || error{
    InputBufferTooSmall,
    BadHeader,
    UnsupportedMethod,
    ReservedFlag,
    HeaderCrcMismatch,
    IsizeMismatch,
    CrcMismatch,
    TrailingData,
};

pub const Options = engine.DecompressOptions;

/// Reusable without initialization, including after errors. No allocation occurs during decode.
/// Assumes reader, writer and workspace storage do not overlap; overlap is not checked. One active call per workspace.
pub const Decompressor = struct {
    decoder: engine.Decoder = .{},

    /// Reader capacity must be >=16; underlying reads may be shorter. Caller flushes writer.
    /// Output is provisional until success. Errors abort; a failed call cannot be resumed.
    pub fn decompress(self: *Decompressor, reader: *std.Io.Reader, writer: *std.Io.Writer, options: Options) Error!u64 {
        return inflate(self, reader, writer, options);
    }
};

comptime {
    std.debug.assert(@sizeOf(Decompressor) == 196608);
}

pub const CompressError = engine.EncodeError;

pub const CompressOptions = engine.CompressOptions;

/// Reusable without initialization, including after errors. No allocation occurs during compression.
/// Assumes reader, writer and workspace storage do not overlap; overlap is not checked. One active call per workspace.
pub const Compressor = struct {
    encoder: engine.Encoder = .{},

    /// Reads through EOF and writes one member. Caller flushes writer; failures may leave partial output.
    /// Reader capacity may be zero. A failed call cannot be resumed.
    pub fn compress(self: *Compressor, reader: *std.Io.Reader, writer: *std.Io.Writer, options: CompressOptions) CompressError!u64 {
        try writer.writeAll(&.{ 31, 139, 8, 0, 0, 0, 0, 0, 0, 255 });
        var check: crc.Crc32 = .init();
        const size = try self.encoder.encodeStream(crc.Crc32, reader, writer, &check, options.level);
        var trailer: [8]u8 = undefined;
        std.mem.writeInt(u32, trailer[0..4], check.final(), .little);
        std.mem.writeInt(u32, trailer[4..8], @truncate(size), .little);
        try writer.writeAll(&trailer);
        return size;
    }
};

comptime {
    std.debug.assert(@sizeOf(Compressor) == 238848);
}

// Shared with BGZF. `Visitor` is `void` (plain gzip) or provides
// `subfield(*Visitor, id: [2]u8, len: u16, offset: u16, bytes: []const u8) !void`, called as extra subfield
// bytes stream by; a subfield that overruns XLEN is `BadHeader`.
pub fn parseHeader(br: *engine.BitReader, comptime Visitor: type, visitor: if (Visitor == void) void else *Visitor) !void {
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
        if (Visitor == void) {
            var left: usize = size;
            while (left != 0) {
                if (br.i == br.src.len and !try br.window(1)) return error.Truncated;
                const n = @min(left, br.src.len - br.i);
                checksum.update(try br.getBytes(n));
                left -= n;
            }
        } else try readSubfields(br, &checksum, size, Visitor, visitor);
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

fn readSubfields(br: *engine.BitReader, checksum: *crc.Crc32, size: u16, comptime Visitor: type, visitor: *Visitor) !void {
    var left: usize = size;
    while (left != 0) {
        if (left < 4) return error.BadHeader;
        const head = try br.getBytes(4);
        checksum.update(head);
        const id: [2]u8 = head[0..2].*;
        const len = std.mem.readInt(u16, head[2..4], .little);
        left -= 4;
        if (len > left) return error.BadHeader;
        if (len == 0) try visitor.subfield(id, 0, 0, &.{});
        var offset: u16 = 0;
        while (offset < len) {
            if (br.i == br.src.len and !try br.window(1)) return error.Truncated;
            const n: u16 = @intCast(@min(len - offset, br.src.len - br.i));
            const bytes = try br.getBytes(n);
            checksum.update(bytes);
            try visitor.subfield(id, len, offset, bytes);
            offset += n;
        }
        left -= len;
    }
}

// Shared with BGZF: ISIZE is compared before CRC-32, the gzip error precedence.
pub fn readTrailer(br: *engine.BitReader, crc_value: u32, size: u64) Error!void {
    const footer = try br.getBytes(8);
    if (std.mem.readInt(u32, footer[4..8], .little) != @as(u32, @truncate(size))) return error.IsizeMismatch;
    if (std.mem.readInt(u32, footer[0..4], .little) != crc_value) return error.CrcMismatch;
}

fn inflateMember(session: *engine.Session(crc.Crc32), br: *engine.BitReader) Error!void {
    try parseHeader(br, void, {});
    var check: crc.Crc32 = .init();
    const size = try session.stream(br, &check);
    try readTrailer(br, check.final(), size);
}

fn inflate(work: *Decompressor, reader: *std.Io.Reader, writer: *std.Io.Writer, options: Options) Error!u64 {
    if (reader.buffer.len < 16) return error.InputBufferTooSmall;
    var br: engine.BitReader = .{ .reader = reader };
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

test {
    _ = crc;
}
