//! Bounded zlib compression and decompression through caller-owned readers and writers.

const std = @import("std");
const engine = @import("../deflate/deflate.zig");
const adler32 = @import("../kernel/adler32.zig");
const inflate = @import("inflate.zig");
const compress = @import("compress.zig");

pub const Error = engine.Error || error{
    InputBufferTooSmall,
    BadHeader,
    UnsupportedMethod,
    WindowTooLarge,
    DictionaryUnsupported,
    BadAdler,
    TrailingData,
};

pub const Options = engine.DecompressOptions;

/// Decodes one zlib stream and checks its Adler-32. `init(input, options)` starts it in place; `reader` gives
/// the decoded bytes and `err` the reason for a `ReadFailed`. Input reader capacity must be >=16. No allocation occurs.
pub const Decompressor = inflate.Inflate(Stream);

const Stream = struct {
    pub const Check = adler32.Adler32;
    pub const Error = zlib.Error;
    pub const Options = zlib.Options;
    pub const min_input_buffer = 16;

    options: zlib.Options,
    started: bool = false,

    pub fn init(options: zlib.Options) Stream {
        return .{ .options = options };
    }

    pub fn begin(self: *Stream, br: *engine.BitReader) zlib.Error!bool {
        if (!self.started) {
            self.started = true;
            try parseHeader(br);
            return true;
        }
        if (try br.window(1) and self.options.trailing_data == .reject) return error.TrailingData;
        return false;
    }

    pub fn end(_: *Stream, br: *engine.BitReader, check: *Check, _: u64) zlib.Error!void {
        const footer = try br.getBytes(4);
        if (check.final() != std.mem.readInt(u32, footer[0..4], .big)) return error.BadAdler;
    }
};

const zlib = @This();

pub const CompressError = engine.EncodeError;

pub const CompressOptions = engine.CompressOptions;

/// Writes one zlib stream: `init(output, options)` writes the header and starts it in place, plain bytes go to
/// `writer`, and `finish` writes the last block and the Adler-32. No allocation occurs.
pub const Compressor = compress.Deflate(struct {
    pub const Check = adler32.Adler32;

    pub fn header(output: *std.Io.Writer, level: engine.Level) std.Io.Writer.Error!void {
        return output.writeAll(&headerFor(level));
    }

    pub fn trailer(output: *std.Io.Writer, check: *Check, _: u64) std.Io.Writer.Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, check.final(), .big);
        return output.writeAll(&bytes);
    }
});

comptime {
    std.debug.assert(@sizeOf(Compressor) == 428624);
}

// CMF 0x78 is DEFLATE with a 32 KiB window; FLEVEL follows zlib's level convention (fastest, fast, default, maximum).
fn headerFor(level: engine.Level) [2]u8 {
    return switch (level) {
        .fast => .{ 0x78, 0x01 },
        .even => .{ 0x78, 0x5e },
        .dense => .{ 0x78, 0xda },
    };
}

fn parseHeader(br: *engine.BitReader) !void {
    const header = try br.getBytes(2);
    const cmf = header[0];
    const flg = header[1];
    if (cmf & 0x0f != 8) return error.UnsupportedMethod;
    if (cmf >> 4 > 7) return error.WindowTooLarge;
    if ((@as(u16, cmf) << 8 | flg) % 31 != 0) return error.BadHeader;
    if (flg & 0x20 != 0) return error.DictionaryUnsupported;
}

test {
    _ = adler32;
}
