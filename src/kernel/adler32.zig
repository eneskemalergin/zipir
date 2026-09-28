//! Streaming Adler-32 with a runtime-selected accelerated backend. The AVX2 kernel is never inlined into its
//! callers: inlining it slows zlib decoding.

const std = @import("std");
const options = @import("kernel_options");
const cpu = @import("cpu.zig");
const avx2 = if (options.adler32_x86_avx2 == .direct) @import("adler32_x86_avx2.zig") else struct {};

const MODULUS: u32 = 65_521;
const NMAX: usize = 5_552;
const AVX2_MIN_LENGTH: usize = 128;

extern fn zipir_adler32_x86_avx2_update(start: u32, bytes: [*]const u8, len: usize) callconv(.c) u32;

pub const Adler32 = struct {
    state: u32 = 1,

    pub fn init() Adler32 {
        return .{};
    }

    pub fn update(self: *Adler32, bytes: []const u8) void {
        self.state = updateDispatched(self.state, bytes);
    }

    pub fn final(self: Adler32) u32 {
        return self.state;
    }
};

inline fn useAvx2() bool {
    if (comptime options.adler32_x86_avx2 == .absent) return false;
    return cpu.has(.avx2);
}

inline fn avx2Update(start: u32, bytes: []const u8) u32 {
    if (comptime options.adler32_x86_avx2 == .direct) return @call(.never_inline, avx2.update, .{ start, bytes });
    return zipir_adler32_x86_avx2_update(start, bytes.ptr, bytes.len);
}

fn updateDispatched(start: u32, bytes: []const u8) u32 {
    if (bytes.len == 0) return start;
    if (bytes.len >= AVX2_MIN_LENGTH and useAvx2()) return avx2Update(start, bytes);
    return updatePortableChunk(start, bytes);
}

fn updatePortableChunk(start: u32, bytes: []const u8) u32 {
    var a = start & 0xffff;
    var b = start >> 16;

    if (bytes.len == 1) {
        a +%= bytes[0];
        if (a >= MODULUS) a -= MODULUS;
        b +%= a;
        if (b >= MODULUS) b -= MODULUS;
    } else if (bytes.len < 16) {
        for (bytes) |byte| {
            a +%= byte;
            b +%= a;
        }
        if (a >= MODULUS) a -= MODULUS;
        b %= MODULUS;
    } else {
        const rounds_per_block = (NMAX - 48) / 64;
        var offset: usize = 0;

        while (offset + NMAX <= bytes.len) {
            var rounds: usize = 0;
            while (rounds < rounds_per_block) : (rounds += 1) {
                comptime var index: usize = 0;
                inline while (index < 64) : (index += 1) {
                    a +%= bytes[offset + index];
                    b +%= a;
                }
                offset += 64;
            }
            comptime var index: usize = 0;
            inline while (index < 48) : (index += 1) {
                a +%= bytes[offset + index];
                b +%= a;
            }
            offset += 48;

            a %= MODULUS;
            b %= MODULUS;
        }

        if (offset < bytes.len) {
            while (offset + 32 <= bytes.len) : (offset += 32) {
                comptime var index: usize = 0;
                inline while (index < 32) : (index += 1) {
                    a +%= bytes[offset + index];
                    b +%= a;
                }
            }
            while (offset + 16 <= bytes.len) : (offset += 16) {
                comptime var index: usize = 0;
                inline while (index < 16) : (index += 1) {
                    a +%= bytes[offset + index];
                    b +%= a;
                }
            }
            while (offset < bytes.len) : (offset += 1) {
                a +%= bytes[offset];
                b +%= a;
            }

            a %= MODULUS;
            b %= MODULUS;
        }
    }

    return a | (b << 16);
}

fn reference(bytes: []const u8) u32 {
    var a: u64 = 1;
    var b: u64 = 0;
    for (bytes) |byte| {
        a = (a + byte) % MODULUS;
        b = (b + a) % MODULUS;
    }
    return @as(u32, @intCast(a)) | (@as(u32, @intCast(b)) << 16);
}

test "[unit] - [adler]: stream starts at the zlib Adler-32 value" {
    const stream = Adler32.init();
    try std.testing.expectEqual(@as(u32, 1), stream.final());
    try std.testing.expectEqual(@sizeOf(std.hash.Adler32), @sizeOf(Adler32));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Adler32));
}

test "[property] - [adler]: stream matches an independent reference across partitions" {
    var bytes: [NMAX * 2 + 64]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x1357_2468);
    random.fill(&bytes);

    const chunk_sizes = [_]usize{
        1,        2,    7,        15,        16, 31, 64, 128,
        NMAX - 1, NMAX, NMAX + 1, bytes.len,
    };
    for (chunk_sizes) |chunk_size| {
        var stream = Adler32.init();
        var offset: usize = 0;
        while (offset < bytes.len) {
            const amount = @min(chunk_size, bytes.len - offset);
            stream.state = updatePortableChunk(stream.state, bytes[offset .. offset + amount]);
            offset += amount;
        }
        try std.testing.expectEqual(reference(&bytes), stream.final());
    }
}

test "[property] - [adler]: portable and dispatched streams produce the same checksum" {
    var bytes: [8_193]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x2468_1357);
    random.fill(&bytes);

    var portable = Adler32.init();
    var dispatched = Adler32.init();
    portable.state = updatePortableChunk(portable.state, bytes[0..31]);
    portable.state = updatePortableChunk(portable.state, bytes[31..4096]);
    portable.state = updatePortableChunk(portable.state, bytes[4096..]);
    dispatched.update(bytes[0..31]);
    dispatched.update(bytes[31..4096]);
    dispatched.update(bytes[4096..]);

    try std.testing.expectEqual(portable.final(), dispatched.final());
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(@TypeOf(portable)));
}

test "[edge] - [adler]: tiny updates stay on the portable path" {
    var stream = Adler32.init();
    stream.update("a");
    try std.testing.expectEqual(@as(u32, 0x0062_0062), stream.final());
}

test "[edge] - [adler]: empty updates do not change state" {
    var stream = Adler32.init();
    stream.update("");
    try std.testing.expectEqual(@as(u32, 1), stream.final());
}

test "[unit] - [adler]: known vectors match Adler-32" {
    var stream = Adler32.init();
    stream.state = updatePortableChunk(stream.state, "a");
    try std.testing.expectEqual(@as(u32, 0x0062_0062), stream.final());

    stream = Adler32.init();
    stream.state = updatePortableChunk(stream.state, "example");
    try std.testing.expectEqual(@as(u32, 0x0bc0_02ed), stream.final());

    stream = Adler32.init();
    stream.state = updatePortableChunk(stream.state, "123456789");
    try std.testing.expectEqual(@as(u32, 0x091e_01de), stream.final());
}

test "[property] - [adler]: the AVX2 backend matches an independent reference at every length and alignment" {
    if (comptime options.adler32_x86_avx2 == .absent) return error.SkipZigTest;
    if (!cpu.features().avx2) return error.SkipZigTest;
    var bytes: [4096 + 64]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x5eed_a0d1);
    random.fill(&bytes);
    for (0..64) |alignment| {
        const data = bytes[alignment..][0..4096];
        var a: u32 = 1;
        var b: u32 = 0;
        for (0..data.len + 1) |length| {
            try std.testing.expectEqual(a | (b << 16), avx2Update(1, data[0..length]));
            if (length == data.len) break;
            a = (a + data[length]) % MODULUS;
            b = (b + a) % MODULUS;
        }
    }
    var large: [3 * NMAX + 8193]u8 = undefined;
    random.fill(&large);
    for ([_]usize{ NMAX - 1, NMAX, NMAX + 1, 8191, 8192, 8193, large.len }) |length| {
        try std.testing.expectEqual(reference(large[0..length]), avx2Update(1, large[0..length]));
    }
}
