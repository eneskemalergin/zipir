//! Bounded overlap-safe DEFLATE match copies.

const std = @import("std");

pub fn dist1Broadcast32(dst: []u8, v: u8) void {
    const V = @Vector(32, u8);
    const splat: V = @splat(v);
    var i: usize = 0;
    while (i + 32 <= dst.len) : (i += 32) {
        dst[i..][0..32].* = splat;
    }
    if (i < dst.len) @memset(dst[i..], v);
}

fn matchByte(buf: []u8, start: usize, dist: usize, len: usize) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        buf[start + i] = buf[start + i - dist];
    }
}

// Asserts distance 1..31, 32 valid history bytes, and 31 owned tail bytes; one vector is
// reused at positions with the same phase in the history pattern.
pub inline fn repeatSmall(buf: []u8, start: usize, distance: usize, length: usize) void {
    @setEvalBranchQuota(10000);
    var advance: usize = undefined;
    const history: @Vector(32, u8) = buf[start - 32 ..][0..32].*;
    const pattern: @Vector(32, u8) = switch (distance) {
        inline 1...31 => |period| blk: {
            const mask = comptime mask: {
                var indices: [32]i32 = undefined;
                for (&indices, 0..) |*index, i| index.* = @intCast(32 - period + i % period);
                break :mask indices;
            };
            advance = (32 / period) * period;
            break :blk @shuffle(u8, history, undefined, mask);
        },
        else => unreachable,
    };
    var i: usize = 0;
    while (i < length) : (i += advance) buf[start + i ..][0..32].* = pattern;
}

pub fn matchVec16(buf: []u8, start: usize, dist: usize, len: usize) void {
    if (dist < 16) {
        matchByte(buf, start, dist, len);
        return;
    }
    const V = @Vector(16, u8);
    var i: usize = 0;
    while (i + 16 <= len) : (i += 16) {
        const chunk: V = buf[start + i - dist ..][0..16].*;
        buf[start + i ..][0..16].* = chunk;
    }
    while (i < len) : (i += 1) {
        buf[start + i] = buf[start + i - dist];
    }
}

test "[property] - [match]: all overlap distances and match lengths preserve bytes" {
    var expected: [1024]u8 = undefined;
    var actual: [1024]u8 = undefined;
    var random = std.Random.DefaultPrng.init(7);
    for (1..65) |distance| {
        for (3..259) |length| {
            random.fill(expected[0..distance]);
            @memcpy(actual[0..distance], expected[0..distance]);
            matchByte(&expected, distance, distance, length);
            if (distance == 1) dist1Broadcast32(actual[distance..][0..length], actual[0]) else matchVec16(&actual, distance, distance, length);
            try std.testing.expectEqualSlices(u8, expected[0 .. distance + length], actual[0 .. distance + length]);
        }
    }
}

test "[property] - [match]: periodic vectors preserve history and bounded tail" {
    var expected: [512]u8 = undefined;
    var actual: [512]u8 = undefined;
    var random = std.Random.DefaultPrng.init(91);
    for (1..32) |distance| {
        for (3..259) |length| {
            for (0..16) |offset| {
                const start = 32 + offset;
                random.fill(&expected);
                actual = expected;
                matchByte(&expected, start, distance, length);
                repeatSmall(&actual, start, distance, length);
                try std.testing.expectEqualSlices(u8, expected[0 .. start + length], actual[0 .. start + length]);
                try std.testing.expectEqualSlices(u8, expected[start + length + 31 ..], actual[start + length + 31 ..]);
            }
        }
    }
}
