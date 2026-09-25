//! Public library root for zipir.

const std = @import("std");

pub const gzip = @import("container/gzip.zig");
pub const zlib = @import("container/zlib.zig");
pub const Format = enum { gzip, zlib };

pub fn Decompressor(comptime format: Format) type {
    return switch (format) {
        .gzip => gzip.Decompressor,
        .zlib => zlib.Decompressor,
    };
}

pub fn Compressor(comptime format: Format) type {
    return switch (format) {
        .gzip => gzip.Compressor,
        .zlib => zlib.Compressor,
    };
}

pub const version: std.SemanticVersion = .{
    .major = 0,
    .minor = 1,
    .patch = 2,
};

test {
    _ = gzip;
    _ = zlib;
}
