//! Public contracts of `zipir.Crc32` and `zipir.Adler32`: the gzip and zlib checks, equal to std's independent
//! implementations for every length, alignment, and split of the input, whichever CPU kernel runs.

const std = @import("std");
const zipir = @import("zipir");
const support = @import("support.zig");

test "[unit] - [checksum]: the reference vectors match" {
    var crc = zipir.Crc32.init();
    crc.update("123456789");
    try std.testing.expectEqual(@as(u32, 0xcbf43926), crc.final());
    var adler = zipir.Adler32.init();
    adler.update("Wikipedia");
    try std.testing.expectEqual(@as(u32, 0x11e60398), adler.final());
    try std.testing.expectEqual(@as(u32, 0), zipir.Crc32.init().final());
    try std.testing.expectEqual(@as(u32, 1), zipir.Adler32.init().final());
}

test "[property] - [checksum]: every length, alignment, and split equals std's checks" {
    const max_len = support.pick(usize, 600, 9000, 70_000);
    const bytes = try std.testing.allocator.alloc(u8, max_len + 64);
    defer std.testing.allocator.free(bytes);
    var rng = std.Random.DefaultPrng.init(0xc4ec);
    rng.random().bytes(bytes);
    const step = support.pick(usize, 7, 1, 1);
    var len: usize = 0;
    while (len <= max_len) : (len += step) {
        for ([_]usize{ 0, 1, 15, 31 }) |offset| {
            const data = bytes[offset..][0..len];
            const crc_expected = std.hash.Crc32.hash(data);
            var adler_expected: std.hash.Adler32 = .{};
            adler_expected.update(data);
            for ([_]usize{ 1, 13, 64, 4096 }) |chunk| {
                var crc = zipir.Crc32.init();
                var adler = zipir.Adler32.init();
                var at: usize = 0;
                while (at < data.len) : (at += chunk) {
                    const part = data[at..@min(data.len, at + chunk)];
                    crc.update(part);
                    adler.update(part);
                }
                try std.testing.expectEqual(crc_expected, crc.final());
                try std.testing.expectEqual(adler_expected.adler, adler.final());
            }
        }
    }
}
