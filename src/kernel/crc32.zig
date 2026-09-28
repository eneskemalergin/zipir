//! Incremental gzip CRC-32: portable slicing plus a PCLMUL fold chosen at run time.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("kernel_options");
const cpu = @import("cpu.zig");
const pclmul = if (options.crc32_x86_pclmul == .direct) @import("crc32_x86_pclmul.zig") else struct {};

extern fn zipir_crc32_x86_pclmul_update(crc_in: u32, data: [*]const u8, len: usize) callconv(.c) u32;
extern fn zipir_crc32_x86_pclmul_copy_update(crc_in: u32, data: [*]const u8, dest: [*]u8, len: usize) callconv(.c) u32;

const PCLMUL_MIN_BULK: usize = 64;

const POLY: u32 = 0xEDB88320;

const TABLES = blk: {
    @setEvalBranchQuota(400_000);
    var t: [8][256]u32 = undefined;
    for (0..256) |i| {
        var crc: u32 = @intCast(i);
        for (0..8) |_| {
            crc = if (crc & 1 != 0) (crc >> 1) ^ POLY else crc >> 1;
        }
        t[0][i] = crc;
    }
    for (0..256) |i| {
        var crc = t[0][i];
        for (1..8) |k| {
            crc = t[0][crc & 0xff] ^ (crc >> 8);
            t[k][i] = crc;
        }
    }
    break :blk t;
};

inline fn tail(crc0: u32, data: []const u8) u32 {
    var crc = crc0;
    for (data) |b| {
        crc = TABLES[0][(crc ^ b) & 0xff] ^ (crc >> 8);
    }
    return crc;
}

fn updatePortable(crc_in: u32, data: []const u8) u32 {
    var crc = crc_in;
    var i: usize = 0;
    while (i + 8 <= data.len) : (i += 8) {
        const word = crc ^ std.mem.readInt(u64, data[i..][0..8], .little);
        crc =
            TABLES[7][@as(u8, @truncate(word))] ^
            TABLES[6][@as(u8, @truncate(word >> 8))] ^
            TABLES[5][@as(u8, @truncate(word >> 16))] ^
            TABLES[4][@as(u8, @truncate(word >> 24))] ^
            TABLES[3][@as(u8, @truncate(word >> 32))] ^
            TABLES[2][@as(u8, @truncate(word >> 40))] ^
            TABLES[1][@as(u8, @truncate(word >> 48))] ^
            TABLES[0][@as(u8, @truncate(word >> 56))];
    }
    return tail(crc, data[i..]);
}

inline fn usePclmul() bool {
    if (comptime options.crc32_x86_pclmul == .absent) return false;
    return cpu.has(.pclmul) and cpu.has(.sse4_1);
}

inline fn pclmulUpdate(crc_in: u32, data: []const u8) u32 {
    if (comptime options.crc32_x86_pclmul == .direct) return pclmul.update(crc_in, data);
    return zipir_crc32_x86_pclmul_update(crc_in, data.ptr, data.len);
}

inline fn pclmulCopyUpdate(crc_in: u32, data: []const u8, dest: []u8) u32 {
    if (comptime options.crc32_x86_pclmul == .direct) return pclmul.copyUpdate(crc_in, data, dest);
    return zipir_crc32_x86_pclmul_copy_update(crc_in, data.ptr, dest.ptr, data.len);
}

fn finish(crc_in: u32) u32 {
    return crc_in ^ 0xffffffff;
}

pub const Crc32 = struct {
    state: u32 = 0xffffffff,

    pub fn init() Crc32 {
        return .{};
    }

    pub fn update(self: *Crc32, bytes: []const u8) void {
        self.state = updateState(self.state, bytes);
    }

    pub fn copyUpdate(self: *Crc32, src: []const u8, dst: []u8) void {
        self.state = copyUpdateState(self.state, src, dst);
    }

    pub fn final(self: Crc32) u32 {
        return finish(self.state);
    }
};

const HAVE_ARM_CRC = options.kernel_backend != .portable and switch (builtin.cpu.arch) {
    .aarch64 => std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc),
    else => false,
};

fn updateArm(crc_in: u32, data: []const u8) u32 {
    if (comptime !HAVE_ARM_CRC) return updatePortable(crc_in, data);
    var value = crc_in;
    var i: usize = 0;
    while (data.len - i >= 8) : (i += 8) {
        const word = std.mem.readInt(u64, data[i..][0..8], .little);
        value = asm ("crc32x w0, w1, %[word]"
            : [result] "={w0}" (-> u32),
            : [previous] "{w1}" (value),
              [word] "r" (word),
        );
    }
    return tail(value, data[i..]);
}

fn updateState(crc_in: u32, data: []const u8) u32 {
    if (comptime HAVE_ARM_CRC) return updateArm(crc_in, data);
    if (data.len == 0) return crc_in;
    if (data.len >= PCLMUL_MIN_BULK and usePclmul()) {
        const bulk = data.len & ~@as(usize, 15);
        return tail(pclmulUpdate(crc_in, data[0..bulk]), data[bulk..]);
    }
    return updatePortable(crc_in, data);
}

fn copyUpdateState(crc_in: u32, data: []const u8, dest: []u8) u32 {
    std.debug.assert(data.len == dest.len);
    if (data.len >= PCLMUL_MIN_BULK and usePclmul()) {
        const bulk = data.len & ~@as(usize, 15);
        const value = pclmulCopyUpdate(crc_in, data[0..bulk], dest[0..bulk]);
        @memcpy(dest[bulk..], data[bulk..]);
        return tail(value, data[bulk..]);
    }
    @memcpy(dest, data);
    return updateState(crc_in, data);
}

test "[property] - [crc]: native and portable incremental paths match independent CRC" {
    var bytes: [4096 + 64]u8 = undefined;
    var random = std.Random.DefaultPrng.init(42);
    random.fill(&bytes);
    for ([_]usize{ 0, 1, 15, 63 }) |offset| {
        for ([_]usize{ 0, 1, 7, 8, 15, 16, 63, 64, 65, 127, 128, 4096 }) |length| {
            const data = bytes[offset..][0..length];
            const expected = std.hash.crc.Crc32IsoHdlc.hash(data);
            for ([_]usize{ 1, 7, 63, 64, 65, 4096 }) |chunk| {
                var native: u32 = 0xffffffff;
                var portable: u32 = 0xffffffff;
                var i: usize = 0;
                while (i < data.len) {
                    const part = data[i..][0..@min(chunk, data.len - i)];
                    native = updateState(native, part);
                    portable = updatePortable(portable, part);
                    i += part.len;
                }
                try std.testing.expectEqual(expected, finish(native));
                try std.testing.expectEqual(expected, finish(portable));
            }
        }
    }
}

test "[property] - [crc]: fused copies preserve bytes, incremental CRC and exact bounds" {
    var bytes: [8192 + 64]u8 = undefined;
    var copied: [8192 + 128]u8 = undefined;
    var random = std.Random.DefaultPrng.init(97);
    random.fill(&bytes);
    for ([_]usize{ 0, 1, 7, 15, 31, 63 }) |prefix| {
        for ([_]usize{ 0, 1, 7, 8, 15, 16, 31, 32, 63, 64, 65, 79, 80, 127, 128, 129, 255, 256, 4096, 8192 }) |length| {
            const expected = std.hash.crc.Crc32IsoHdlc.hash(bytes[0 .. prefix + length]);
            for ([_]usize{ 1, 7, 63, 64, 65, 511, 8192 }) |chunk| {
                @memset(&copied, 0xa5);
                const start = 64 - prefix;
                var value = std.hash.crc.Crc32IsoHdlc.hash(bytes[0..prefix]) ^ 0xffffffff;
                var i: usize = 0;
                while (i < length) {
                    const n = @min(chunk, length - i);
                    value = copyUpdateState(value, bytes[prefix + i ..][0..n], copied[start + i ..][0..n]);
                    i += n;
                }
                value = copyUpdateState(value, &.{}, copied[start..start]);
                try std.testing.expectEqual(expected, finish(value));
                try std.testing.expectEqualSlices(u8, bytes[prefix..][0..length], copied[start..][0..length]);
                for (copied[0..start]) |b| try std.testing.expectEqual(@as(u8, 0xa5), b);
                for (copied[start + length ..]) |b| try std.testing.expectEqual(@as(u8, 0xa5), b);
            }
        }
    }
}

test "[property] - [crc]: the PCLMUL backend matches the portable fold at every bulk length and alignment" {
    if (comptime options.crc32_x86_pclmul == .absent) return error.SkipZigTest;
    if (!cpu.features().pclmul or !cpu.features().sse4_1) return error.SkipZigTest;
    var bytes: [4096 + 64]u8 = undefined;
    var copied: [4096 + 64]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x5eed_c3c3);
    random.fill(&bytes);
    for (0..64) |alignment| {
        const data = bytes[alignment..][0..4096];
        var length: usize = PCLMUL_MIN_BULK;
        while (length <= data.len) : (length += 16) {
            const expected = updatePortable(0xffffffff, data[0..length]);
            try std.testing.expectEqual(expected, pclmulUpdate(0xffffffff, data[0..length]));
            @memset(&copied, 0xa5);
            const dest = copied[63 - alignment ..][0..length];
            try std.testing.expectEqual(expected, pclmulCopyUpdate(0xffffffff, data[0..length], dest));
            try std.testing.expectEqualSlices(u8, data[0..length], dest);
        }
    }
    const large = try std.testing.allocator.alloc(u8, 16 << 20);
    defer std.testing.allocator.free(large);
    random.fill(large);
    try std.testing.expectEqual(updatePortable(0x1234_5678, large), pclmulUpdate(0x1234_5678, large));
}
