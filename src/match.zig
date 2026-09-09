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

pub fn matchByte(buf: []u8, start: usize, dist: usize, len: usize) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        buf[start + i] = buf[start + i - dist];
    }
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
