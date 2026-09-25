//! Bounded zlib compression and decompression through caller-owned readers and writers.

const std = @import("std");
const deflate = @import("../deflate/deflate.zig");
const adler32 = @import("../kernel/adler32.zig");

pub const Error = deflate.Error || error{
    InputBufferTooSmall,
    BadHeader,
    UnsupportedMethod,
    WindowTooLarge,
    DictionaryUnsupported,
    BadAdler,
    TrailingData,
};

pub const Options = struct {
    max_output_bytes: u64 = std.math.maxInt(u64),
    trailing_data: enum { reject, leave } = .reject,
};

/// Reusable without initialization, including after errors. No allocation occurs during decode.
/// Assumes reader, writer and workspace storage do not overlap; overlap is not checked. One active call per workspace.
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

pub const CompressError = deflate.EncodeError;

pub const CompressOptions = deflate.CompressOptions;

/// Reusable without initialization, including after errors. No allocation occurs during compression.
/// Assumes reader, writer and workspace storage do not overlap; overlap is not checked. One active call per workspace.
pub const Compressor = struct {
    encoder: deflate.Encoder = .{},

    /// Reads through EOF and writes one stream. Caller flushes writer; failures may leave partial output.
    /// Reader capacity may be zero. A failed call cannot be resumed.
    pub fn compress(self: *Compressor, reader: *std.Io.Reader, writer: *std.Io.Writer, options: CompressOptions) CompressError!u64 {
        try writer.writeAll(&headerFor(options.level));
        var check: adler32.Adler32 = .init();
        const size = try self.encoder.encodeStream(adler32.Adler32, reader, writer, &check, options.level);
        var trailer: [4]u8 = undefined;
        std.mem.writeInt(u32, &trailer, check.final(), .big);
        try writer.writeAll(&trailer);
        return size;
    }
};

comptime {
    std.debug.assert(@sizeOf(Compressor) == 238848);
}

// CMF 0x78 is DEFLATE with a 32 KiB window; FLEVEL follows zlib's level convention (fastest, fast, default, maximum).
fn headerFor(level: deflate.Level) [2]u8 {
    return switch (level) {
        .fast => .{ 0x78, 0x01 },
        .balanced => .{ 0x78, 0x5e },
        .dense => .{ 0x78, 0xda },
    };
}

fn parseHeader(br: *deflate.BitReader) !void {
    const header = try br.getBytes(2);
    const cmf = header[0];
    const flg = header[1];
    if (cmf & 0x0f != 8) return error.UnsupportedMethod;
    if (cmf >> 4 > 7) return error.WindowTooLarge;
    if ((@as(u16, cmf) << 8 | flg) % 31 != 0) return error.BadHeader;
    if (flg & 0x20 != 0) return error.DictionaryUnsupported;
}

fn inflate(work: *Decompressor, reader: *std.Io.Reader, writer: *std.Io.Writer, options: Options) Error!u64 {
    if (reader.buffer.len < 16) return error.InputBufferTooSmall;
    var br: deflate.BitReader = .{ .reader = reader };
    defer br.release();
    var session = work.decoder.session(adler32.Adler32, writer, .{ .max_output_bytes = options.max_output_bytes });
    try parseHeader(&br);
    var check: adler32.Adler32 = .init();
    _ = try session.stream(&br, &check);
    const footer = try br.getBytes(4);
    if (check.final() != std.mem.readInt(u32, footer[0..4], .big)) return error.BadAdler;
    if (try br.window(1)) {
        if (options.trailing_data == .reject) return error.TrailingData;
    }
    return session.finish();
}

test {
    _ = adler32;
}
