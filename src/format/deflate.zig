//! Raw DEFLATE (RFC 1951): one stream with no framing and no check, so corruption is detected only when it breaks
//! the DEFLATE structure. `init` sets the `Decompressor` or `Compressor` up in place and assumes the workspace stays at
//! that address while `reader` or `writer` is used. On `ReadFailed`, `err` holds the reason. A contiguous write of up
//! to 32 KiB always fits; `writer.flush()` is a full flush; `finish` writes the final block and returns the plain byte
//! count.

const std = @import("std");
const decode = @import("../engine/decode.zig");
const encode = @import("../engine/encode.zig");
const stream_reader = @import("../stream/reader.zig");
const stream_writer = @import("../stream/writer.zig");

pub const DecompressOptions = stream_reader.Options;

pub const DecompressError = decode.DecodeError || stream_reader.Error || error{TrailingData};

pub const Decompressor = stream_reader.Decompressor(DecompressFraming);

pub const SliceDecoder = stream_reader.SliceDecoder(DecompressFraming);

pub const CompressOptions = stream_writer.Options;

pub const CompressError = std.Io.Writer.Error;

pub const Compressor = stream_writer.Compressor(CompressFraming);

comptime {
    std.debug.assert(@sizeOf(Compressor) == 428624);
    std.debug.assert(@sizeOf(SliceDecoder) == 7704);
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
