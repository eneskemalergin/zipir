//! Public library root for zipir.

const std = @import("std");
const gzip_container = @import("format/gzip.zig");

// The gzip container also serves BGZF its header and trailer helpers; only its public API is re-exported.
pub const gzip = struct {
    pub const Error = gzip_container.Error;
    pub const Options = gzip_container.Options;
    pub const Decompressor = gzip_container.Decompressor;
    pub const CompressError = gzip_container.CompressError;
    pub const CompressOptions = gzip_container.CompressOptions;
    pub const Compressor = gzip_container.Compressor;
};
pub const zlib = @import("format/zlib.zig");
pub const deflate = @import("format/deflate.zig");
pub const bgzf = @import("format/bgzf.zig");
pub const tar = @import("archive/tar.zig");
pub const Format = enum { gzip, zlib, deflate };

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
    _ = gzip_container;
    _ = zlib;
    _ = deflate;
    _ = bgzf;
    _ = tar;
}
