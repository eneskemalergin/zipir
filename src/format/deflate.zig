//! Raw DEFLATE (RFC 1951): one DEFLATE stream with no framing and no check. Corruption is detected only when it
//! breaks the DEFLATE structure.

const std = @import("std");
const decode = @import("../engine/decode.zig");
const encode = @import("../engine/encode.zig");
const stream_reader = @import("../stream/reader.zig");
const stream_writer = @import("../stream/writer.zig");

pub const DecompressOptions = stream_reader.Options;

pub const DecompressError = decode.DecodeError || stream_reader.Error || error{TrailingData};

/// Decompresses one raw DEFLATE stream. `init(input, options)` starts it in place and resets it, also after errors; it
/// assumes the workspace stays at that address while `reader` is used (the reader's buffer is inside it) and requires
/// an input reader capacity of at least 16 bytes (`InputBufferTooSmall`). `reader` gives the decoded bytes; on
/// `ReadFailed`, `err` holds the reason. After the end, `input` stands just after the compressed data.
pub const Decompressor = stream_reader.Decompressor(DecompressFraming);

pub const CompressOptions = stream_writer.Options;

pub const CompressError = std.Io.Writer.Error;

/// Writes one raw DEFLATE stream. `init(output, options)` starts it in place, also after errors; it assumes the
/// workspace stays at that address while `writer` is used. The output depends only on the bytes written, never on the
/// write sizes, and a contiguous request of up to 32 KiB always fits. `writer.flush()` is a full flush (everything so
/// far decodes, and the history restarts); it does not flush `output`. `finish` writes the final DEFLATE block and
/// returns the number of plain bytes; the writer then fails until `init`, and the caller flushes `output`.
pub const Compressor = stream_writer.Compressor(CompressFraming);

comptime {
    std.debug.assert(@sizeOf(Compressor) == 428624);
}

const format = @This();

const DecompressFraming = struct {
    pub const Check = NoCheck;
    pub const DecompressOptions = format.DecompressOptions;
    pub const DecompressError = format.DecompressError;
    pub const min_input_buffer = 16;

    options: format.DecompressOptions,
    started: bool = false,

    pub fn init(options: format.DecompressOptions) DecompressFraming {
        return .{ .options = options };
    }

    pub fn header(self: *DecompressFraming, br: *decode.BitReader) format.DecompressError!bool {
        if (!self.started) {
            self.started = true;
            return true;
        }
        if (try br.refill(1) and self.options.trailing_data == .reject) return error.TrailingData;
        return false;
    }

    pub fn trailer(_: *DecompressFraming, _: *decode.BitReader, _: *Check, _: u64) format.DecompressError!void {}
};

const CompressFraming = struct {
    pub const Check = NoCheck;

    pub fn header(_: *std.Io.Writer, _: encode.Preset) std.Io.Writer.Error!void {}

    pub fn trailer(_: *std.Io.Writer, _: *Check, _: u64) std.Io.Writer.Error!void {}
};

const NoCheck = struct {
    pub fn init() NoCheck {
        return .{};
    }

    pub fn update(_: *NoCheck, _: []const u8) void {}
};
