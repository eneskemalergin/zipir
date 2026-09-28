//! Raw DEFLATE (RFC 1951) streams with no header, trailer, or checksum.

const std = @import("std");
const decode = @import("../engine/decode.zig");
const encode = @import("../engine/encode.zig");
const inflate = @import("../stream/reader.zig");
const compress = @import("../stream/writer.zig");

pub const Error = decode.Error || error{ InputBufferTooSmall, TrailingData };

pub const Options = decode.DecompressOptions;

/// Decodes one raw DEFLATE stream. No integrity check: corruption is detected only when it breaks the DEFLATE
/// structure. `init(input, options)` starts it in place; `reader` gives the decoded bytes and `err` the reason
/// for a `ReadFailed`. Input reader capacity must be >=16. No allocation occurs.
pub const Decompressor = inflate.Inflate(Stream);

const Stream = struct {
    pub const Check = NoCheck;
    pub const Error = raw.Error;
    pub const Options = raw.Options;
    pub const min_input_buffer = 16;

    options: raw.Options,
    started: bool = false,

    pub fn init(options: raw.Options) Stream {
        return .{ .options = options };
    }

    pub fn begin(self: *Stream, br: *decode.BitReader) raw.Error!bool {
        if (!self.started) {
            self.started = true;
            return true;
        }
        if (try br.window(1) and self.options.trailing_data == .reject) return error.TrailingData;
        return false;
    }

    pub fn end(_: *Stream, _: *decode.BitReader, _: *Check, _: u64) raw.Error!void {}
};

const raw = @This();

pub const CompressError = encode.EncodeError;

pub const CompressOptions = encode.CompressOptions;

/// Writes one raw DEFLATE stream, with no integrity check: a reader detects corruption only when it breaks the
/// DEFLATE structure. `init(output, options)` starts it in place, plain bytes go to `writer`, and `finish` writes
/// the last block. No allocation occurs.
pub const Compressor = compress.Deflate(struct {
    pub const Check = NoCheck;

    pub fn header(_: *std.Io.Writer, _: encode.Level) std.Io.Writer.Error!void {}

    pub fn trailer(_: *std.Io.Writer, _: *Check, _: u64) std.Io.Writer.Error!void {}
});

comptime {
    std.debug.assert(@sizeOf(Compressor) == 428624);
}

const NoCheck = struct {
    pub fn init() NoCheck {
        return .{};
    }

    pub fn update(_: *NoCheck, _: []const u8) void {}
};
