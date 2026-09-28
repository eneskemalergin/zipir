//! Raw DEFLATE (RFC 1951): one DEFLATE stream with no framing and no check. Corruption is detected only when it
//! breaks the DEFLATE structure.

const std = @import("std");
const decode = @import("../engine/decode.zig");
const encode = @import("../engine/encode.zig");
const stream_reader = @import("../stream/reader.zig");
const stream_writer = @import("../stream/writer.zig");

pub const DecompressOptions = stream_reader.Options;

pub const DecompressError = decode.DecodeError || stream_reader.Error || error{TrailingData};

/// Decompresses one raw DEFLATE stream. `init(input, options)` starts it in place; `reader` gives the decoded bytes
/// and `err` the reason for a `ReadFailed`. Input reader capacity must be at least 16 bytes. No allocation occurs.
pub const Decompressor = stream_reader.Decompressor(DecompressFraming);

pub const CompressOptions = stream_writer.Options;

pub const CompressError = std.Io.Writer.Error;

/// Writes one raw DEFLATE stream: `init(output, options)` starts it in place, plain bytes go to `writer`, and
/// `finish` writes the final DEFLATE block. No allocation occurs.
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

// The check of a format without one.
const NoCheck = struct {
    pub fn init() NoCheck {
        return .{};
    }

    pub fn update(_: *NoCheck, _: []const u8) void {}
};
