//! Public library root for z_flate.

const std = @import("std");

pub const gzip = @import("gzip.zig");
pub const Format = enum { gzip };

pub fn Decompressor(comptime format: Format) type {
    return switch (format) {
        .gzip => gzip.Decompressor,
    };
}

pub fn Compressor(comptime format: Format) type {
    return switch (format) {
        .gzip => gzip.Compressor,
    };
}

pub const version: std.SemanticVersion = .{
    .major = 0,
    .minor = 0,
    .patch = 0,
};

test "[unit] - [root]: reports version 0.0.0" {
    try std.testing.expectEqual(@as(usize, 0), version.major);
    try std.testing.expectEqual(@as(usize, 0), version.minor);
    try std.testing.expectEqual(@as(usize, 0), version.patch);
}

test {
    _ = gzip;
}
