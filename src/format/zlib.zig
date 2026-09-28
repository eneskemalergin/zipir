//! zlib (RFC 1950): one DEFLATE stream between a two-byte header and a big-endian Adler-32.

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

/// Decompresses one zlib stream and checks its Adler-32. `init(input, options)` starts it in place and resets it, also
/// after errors; it assumes the workspace stays at that address while `reader` is used (the reader's buffer is inside
/// it) and requires an input reader capacity of at least 16 bytes (`InputBufferTooSmall`). `reader` gives the decoded
/// bytes; on `ReadFailed`, `err` holds the reason. After the end, `input` stands just after the compressed data.
pub const Decompressor = stream_reader.Decompressor(DecompressFraming);

pub const CompressOptions = stream_writer.Options;

pub const CompressError = std.Io.Writer.Error;

/// Writes one zlib stream. `init(output, options)` writes the header and starts it in place, also after errors; it
/// assumes the workspace stays at that address while `writer` is used. The output depends only on the bytes written,
/// never on the write sizes, and a contiguous request of up to 32 KiB always fits. `writer.flush()` is a full flush
/// (everything so far decodes, and the history restarts); it does not flush `output`. `finish` writes the final DEFLATE
/// block and the Adler-32 and returns the number of plain bytes; the writer then fails until `init`, and the caller
/// flushes `output`.
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

// CMF 0x78 is DEFLATE with a 32 KiB window; FLEVEL follows zlib's level convention (fastest, fast, default,
// maximum) for the level each preset is compared with.
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
