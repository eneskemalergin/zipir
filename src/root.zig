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
    if (format != .gzip) @compileError("zlib compression is not implemented");
    return gzip.Compressor;
}

pub const version: std.SemanticVersion = .{
    .major = 0,
    .minor = 1,
    .patch = 2,
};

test "[unit] - [root]: reports version 0.1.2" {
    try std.testing.expectEqual(@as(usize, 0), version.major);
    try std.testing.expectEqual(@as(usize, 1), version.minor);
    try std.testing.expectEqual(@as(usize, 2), version.patch);
}

test {
    _ = gzip;
    _ = zlib;
}
