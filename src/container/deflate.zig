//! Raw DEFLATE (RFC 1951) streams with no header, trailer, or checksum.

const std = @import("std");
const engine = @import("../deflate/deflate.zig");
const inflate = @import("inflate.zig");

pub const Error = engine.Error || error{ InputBufferTooSmall, TrailingData };

pub const Options = engine.DecompressOptions;

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

    pub fn begin(self: *Stream, br: *engine.BitReader) raw.Error!bool {
        if (!self.started) {
            self.started = true;
            return true;
        }
        if (try br.window(1) and self.options.trailing_data == .reject) return error.TrailingData;
        return false;
    }

    pub fn end(_: *Stream, _: *engine.BitReader, _: *Check, _: u64) raw.Error!void {}
};

const raw = @This();

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
    std.debug.assert(@sizeOf(Compressor) == 428584);
}

const NoCheck = struct {
    pub fn init() NoCheck {
        return .{};
    }

    pub fn update(_: *NoCheck, _: []const u8) void {}
};
