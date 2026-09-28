//! The zipir package root: the public API. `gzip` re-exports only gzip's public API; the header and trailer helpers
//! it shares with BGZF stay internal.

const std = @import("std");
const gzip_format = @import("format/gzip.zig");

pub const gzip = struct {
    pub const DecompressOptions = gzip_format.DecompressOptions;
    pub const DecompressError = gzip_format.DecompressError;
    pub const Decompressor = gzip_format.Decompressor;
    pub const CompressOptions = gzip_format.CompressOptions;
    pub const CompressError = gzip_format.CompressError;
    pub const Compressor = gzip_format.Compressor;
};
pub const zlib = @import("format/zlib.zig");
pub const deflate = @import("format/deflate.zig");
pub const bgzf = @import("format/bgzf.zig");
pub const tar = @import("archive/tar.zig");
pub const Format = enum { gzip, zlib, deflate };

pub const Preset = @import("engine/encode.zig").Preset;

pub fn Decompressor(comptime format: Format) type {
    return switch (format) {
        .gzip => gzip.Decompressor,
        .zlib => zlib.Decompressor,
        .deflate => deflate.Decompressor,
    };
}

pub fn Compressor(comptime format: Format) type {
    return switch (format) {
        .gzip => gzip.Compressor,
        .zlib => zlib.Compressor,
        .deflate => deflate.Compressor,
    };
}

pub const version: std.SemanticVersion = .{
    .major = 0,
    .minor = 1,
    .patch = 2,
};

test {
    _ = gzip_format;
    _ = zlib;
    _ = deflate;
    _ = bgzf;
    _ = tar;
}
