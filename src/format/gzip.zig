//! gzip (RFC 1952): members of a gzip header, a DEFLATE stream, and a trailer with CRC-32 and ISIZE. The header
//! and trailer helpers are shared with BGZF, whose blocks are gzip members.

const std = @import("std");
const decode = @import("../engine/decode.zig");
const encode = @import("../engine/encode.zig");
const crc = @import("../kernel/crc32.zig");
const stream_reader = @import("../stream/reader.zig");
const stream_writer = @import("../stream/writer.zig");

pub const DecompressOptions = struct {
    /// More decoded output than this is `OutputLimitExceeded`.
    max_output_bytes: u64 = std.math.maxInt(u64),
    trailing_data: stream_reader.TrailingData = .reject,
    /// Header bytes after the fixed ten (extra field, name, comment, header CRC) allowed in each member; more is
    /// `HeaderTooLong`. Bounds the work a header can cause before any output.
    max_header_bytes: u64 = 1 << 20,
};

pub const DecompressError = decode.DecodeError || stream_reader.Error || error{
    BadHeader,
    UnsupportedMethod,
    ReservedFlag,
    HeaderCrcMismatch,
    HeaderTooLong,
    IsizeMismatch,
    CrcMismatch,
    TrailingData,
};

/// Decompresses concatenated gzip members, checking each CRC-32 and ISIZE; empty input is `Truncated`.
/// `init(input, options)` starts it in place; `reader` gives the decoded bytes and `err` the reason for a
/// `ReadFailed`. Input reader capacity must be at least 16 bytes. No allocation occurs.
pub const Decompressor = stream_reader.Decompressor(DecompressFraming);

pub const CompressOptions = stream_writer.Options;

pub const CompressError = std.Io.Writer.Error;

/// Writes one gzip member: `init(output, options)` writes the header and starts it in place, plain bytes go to
/// `writer`, and `finish` writes the final DEFLATE block and the trailer. No allocation occurs.
pub const Compressor = stream_writer.Compressor(CompressFraming);

comptime {
    std.debug.assert(@sizeOf(Compressor) == 428624);
}

const format = @This();

const DecompressFraming = struct {
    pub const Check = crc.Crc32;
    pub const DecompressOptions = format.DecompressOptions;
    pub const DecompressError = format.DecompressError;
    pub const min_input_buffer = 16;

    options: format.DecompressOptions,
    members: u64 = 0,

    pub fn init(options: format.DecompressOptions) DecompressFraming {
        return .{ .options = options };
    }

    pub fn header(self: *DecompressFraming, br: *decode.BitReader) format.DecompressError!bool {
        _ = try br.refill(2);
        if (br.src.len == 0 and self.members != 0) return false;
        if (br.src.len < 2 or br.src[0] != 0x1f or br.src[1] != 0x8b) {
            if (self.members != 0) {
                if (self.options.trailing_data == .leave) return false;
                return error.TrailingData;
            }
            if (br.src.len < 2) return error.Truncated;
            return error.BadHeader;
        }
        try readHeader(br, void, {}, self.options.max_header_bytes);
        self.members += 1;
        return true;
    }

    pub fn trailer(_: *DecompressFraming, br: *decode.BitReader, check: *Check, size: u64) format.DecompressError!void {
        try readTrailer(br, check.final(), size);
    }
};

const CompressFraming = struct {
    pub const Check = crc.Crc32;

    pub fn header(output: *std.Io.Writer, _: encode.Preset) std.Io.Writer.Error!void {
        return writeHeader(output, "");
    }

    pub fn trailer(output: *std.Io.Writer, check: *Check, size: u64) std.Io.Writer.Error!void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], check.final(), .little);
        std.mem.writeInt(u32, bytes[4..8], @truncate(size), .little);
        return output.writeAll(&bytes);
    }
};

/// Reads a member's header, shared with BGZF. `Visitor` is `void` (plain gzip) or declares
/// `subfield(*Visitor, id: [2]u8, len: u16, offset: u16, bytes: []const u8) !void`, called as extra subfield bytes
/// stream by; a subfield that overruns XLEN is `BadHeader`. `limit` bounds the bytes after the fixed ten.
pub fn readHeader(br: *decode.BitReader, comptime Visitor: type, visitor: if (Visitor == void) void else *Visitor, limit: u64) !void {
    const header = try br.getBytes(10);
    if (header[0] != 0x1f or header[1] != 0x8b) return error.BadHeader;
    if (header[2] != 8) return error.UnsupportedMethod;
    const flags = header[3];
    if (flags & 0xe0 != 0) return error.ReservedFlag;
    var checksum = crc.Crc32.init();
    checksum.update(header);
    var optional: u64 = 0;
    if (flags & 4 != 0) {
        optional = 2;
        if (optional > limit) return error.HeaderTooLong;
        const size_bytes = try br.getBytes(2);
        const size = std.mem.readInt(u16, size_bytes[0..2], .little);
        checksum.update(size_bytes);
        optional += size;
        if (optional > limit) return error.HeaderTooLong;
        if (Visitor == void) {
            var left: usize = size;
            while (left != 0) {
                if (br.i == br.src.len and !try br.refill(1)) return error.Truncated;
                const n = @min(left, br.src.len - br.i);
                checksum.update(try br.getBytes(n));
                left -= n;
            }
        } else try readSubfields(br, &checksum, size, Visitor, visitor);
    }
    for ([_]u8{ 8, 16 }) |flag| {
        if (flags & flag == 0) continue;
        while (true) {
            if (br.i == br.src.len and !try br.refill(1)) return error.Truncated;
            const remaining = br.src[br.i..];
            const zero = std.mem.findScalar(u8, remaining, 0);
            const n = if (zero) |end| end + 1 else remaining.len;
            optional += n;
            if (optional > limit) return error.HeaderTooLong;
            checksum.update(try br.getBytes(n));
            if (zero != null) break;
        }
    }
    if (flags & 2 != 0) {
        if (optional + 2 > limit) return error.HeaderTooLong;
        const expected: u16 = @truncate(checksum.final());
        const field = try br.getBytes(2);
        if (std.mem.readInt(u16, field[0..2], .little) != expected) return error.HeaderCrcMismatch;
    }
}

fn readSubfields(br: *decode.BitReader, checksum: *crc.Crc32, size: u16, comptime Visitor: type, visitor: *Visitor) !void {
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
            if (br.i == br.src.len and !try br.refill(1)) return error.Truncated;
            const n: u16 = @intCast(@min(len - offset, br.src.len - br.i));
            const bytes = try br.getBytes(n);
            checksum.update(bytes);
            try visitor.subfield(id, len, offset, bytes);
            offset += n;
        }
        left -= len;
    }
}

/// Writes a member's header, shared with BGZF: MTIME 0, XFL 0, OS 255 (unknown), and FEXTRA with `extra` as the
/// subfields when not empty.
pub fn writeHeader(writer: *std.Io.Writer, extra: []const u8) std.Io.Writer.Error!void {
    std.debug.assert(extra.len <= std.math.maxInt(u16));
    var header = [12]u8{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff, 0, 0 };
    if (extra.len == 0) return writer.writeAll(header[0..10]);
    header[3] = 4;
    std.mem.writeInt(u16, header[10..12], @intCast(extra.len), .little);
    try writer.writeAll(&header);
    try writer.writeAll(extra);
}

/// Reads and checks a member's trailer, shared with BGZF: ISIZE is compared before CRC-32, the gzip error precedence.
pub fn readTrailer(br: *decode.BitReader, crc_value: u32, size: u64) DecompressError!void {
    const footer = try br.getBytes(8);
    if (std.mem.readInt(u32, footer[4..8], .little) != @as(u32, @truncate(size))) return error.IsizeMismatch;
    if (std.mem.readInt(u32, footer[0..4], .little) != crc_value) return error.CrcMismatch;
}

test {
    _ = crc;
}
