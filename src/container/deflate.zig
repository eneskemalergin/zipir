//! Raw DEFLATE (RFC 1951) streams with no header, trailer, or checksum.

const std = @import("std");
const engine = @import("../deflate/deflate.zig");

pub const Error = engine.Error || error{ InputBufferTooSmall, TrailingData };

pub const Options = engine.DecompressOptions;

/// No integrity check: corruption is detected only when it breaks the DEFLATE structure.
/// Reusable without initialization, including after errors. No allocation occurs during decode.
/// Assumes reader, writer and workspace storage do not overlap; overlap is not checked. One active call per workspace.
pub const Decompressor = struct {
    decoder: engine.Decoder = .{},

    /// Reader capacity must be >=16; underlying reads may be shorter. Caller flushes writer.
    /// Output is provisional until success. Errors abort; a failed call cannot be resumed.
    pub fn decompress(self: *Decompressor, reader: *std.Io.Reader, writer: *std.Io.Writer, options: Options) Error!u64 {
        if (reader.buffer.len < 16) return error.InputBufferTooSmall;
        var br: engine.BitReader = .{ .reader = reader };
        defer br.release();
        var session = self.decoder.session(NoCheck, writer, .{ .max_output_bytes = options.max_output_bytes });
        var check: NoCheck = .{};
        _ = try session.stream(&br, &check);
        if (try br.window(1)) {
            if (options.trailing_data == .reject) return error.TrailingData;
        }
        return session.finish();
    }
};

comptime {
    std.debug.assert(@sizeOf(Decompressor) == 196608);
}

pub const CompressError = engine.EncodeError;

pub const CompressOptions = engine.CompressOptions;

/// Writes no integrity check: a reader detects corruption only when it breaks the DEFLATE structure.
/// Reusable without initialization, including after errors. No allocation occurs during compression.
/// Assumes reader, writer and workspace storage do not overlap; overlap is not checked. One active call per workspace.
pub const Compressor = struct {
    encoder: engine.Encoder = .{},

    /// Reads through EOF and writes one stream. Caller flushes writer; failures may leave partial output.
    /// Reader capacity may be zero. A failed call cannot be resumed.
    pub fn compress(self: *Compressor, reader: *std.Io.Reader, writer: *std.Io.Writer, options: CompressOptions) CompressError!u64 {
        var check: NoCheck = .{};
        return self.encoder.encodeStream(NoCheck, reader, writer, &check, options.level);
    }
};

comptime {
    std.debug.assert(@sizeOf(Compressor) == 238848);
}

const NoCheck = struct {
    pub fn update(_: *NoCheck, _: []const u8) void {}
};
