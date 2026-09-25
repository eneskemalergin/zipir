//! Bounded zlib decompression through caller-owned readers and writers.

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
