//! zlib (RFC 1950): one DEFLATE stream between a two-byte header and a big-endian Adler-32. `init` sets the
//! `Decompressor` or `Compressor` up in place and assumes the workspace stays at that address while `reader` or
//! `writer` is used. On `ReadFailed`, `err` holds the reason. A contiguous write of up to 32 KiB always fits;
//! `writer.flush()` is a full flush; `finish` writes the final block and the Adler-32 and returns the plain byte count.

const std = @import("std");
const decode = @import("../engine/decode.zig");
const encode = @import("../engine/encode.zig");
const adler32 = @import("../kernel/adler32.zig");
const stream_reader = @import("../stream/reader.zig");
const stream_writer = @import("../stream/writer.zig");

pub const DecompressOptions = stream_reader.Options;

pub const DecompressError = decode.DecodeError || stream_reader.Error || error{
    BadHeader,
    UnsupportedMethod,
    WindowTooLarge,
    DictionaryUnsupported,
    BadAdler,
    TrailingData,
};

pub const Decompressor = stream_reader.Decompressor(DecompressFraming);

pub const CompressOptions = stream_writer.Options;

pub const CompressError = std.Io.Writer.Error;

pub const Compressor = stream_writer.Compressor(CompressFraming);

comptime {
    std.debug.assert(@sizeOf(Compressor) == 428624);
}

const format = @This();

const DecompressFraming = struct {
    pub const Check = adler32.Adler32;
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
            try readHeader(br);
            return true;
        }
        if (try br.refill(1) and self.options.trailing_data == .reject) return error.TrailingData;
        return false;
    }

    pub fn trailer(_: *DecompressFraming, br: *decode.BitReader, check: *Check, _: u64) format.DecompressError!void {
        const bytes = try br.getBytes(4);
        if (check.final() != std.mem.readInt(u32, bytes[0..4], .big)) return error.BadAdler;
    }
};

const CompressFraming = struct {
    pub const Check = adler32.Adler32;

    pub fn header(output: *std.Io.Writer, preset: encode.Preset) std.Io.Writer.Error!void {
        return output.writeAll(&headerBytes(preset));
    }

    pub fn trailer(output: *std.Io.Writer, check: *Check, _: u64) std.Io.Writer.Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, check.final(), .big);
        return output.writeAll(&bytes);
    }
};

fn headerBytes(preset: encode.Preset) [2]u8 {
    return switch (preset) {
        .fast => .{ 0x78, 0x01 },
        .even => .{ 0x78, 0x5e },
        .dense => .{ 0x78, 0xda },
    };
}

fn readHeader(br: *decode.BitReader) DecompressError!void {
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
