//! Incremental gzip CRC with portable slicing and target-guarded acceleration.

const std = @import("std");
const builtin = @import("builtin");

const HAVE_PCLMUL = switch (builtin.cpu.arch) {
    .x86, .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .pclmul),
    else => false,
};

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

const X = @Vector(2, u64);

// IEEE CRC-32 fold constants (reflected). Same POLYNOMIAL as gzip. Barrett at the end.
// Source: Intel PCLMUL CRC paper via zlib/chromium SSE path (k1..k5, POLYNOMIAL).
const K1K2: X = .{ 0x0154442bd4, 0x01c6e41596 };
const K3K4: X = .{ 0x01751997d0, 0x00ccaa009e };
const K5K0: X = .{ 0x0163cd6124, 0 };
const POLYNOMIAL: X = .{ 0x01db710641, 0x01f7011641 };
const MASK32: X = .{ 0x00000000ffffffff, 0x00000000ffffffff };

inline fn clmul(a: X, b: X, comptime imm: u8) X {
    return switch (imm) {
        0x00 => asm volatile ("pclmulqdq $0x00, %[b], %[out]"
            : [out] "=x" (-> X),
            : [_] "0" (a),
              [b] "x" (b),
        ),
        0x10 => asm volatile ("pclmulqdq $0x10, %[b], %[out]"
            : [out] "=x" (-> X),
            : [_] "0" (a),
              [b] "x" (b),
        ),
        0x11 => asm volatile ("pclmulqdq $0x11, %[b], %[out]"
            : [out] "=x" (-> X),
            : [_] "0" (a),
              [b] "x" (b),
        ),
        else => unreachable,
    };
}

inline fn loadu(p: [*]const u8) X {
    const b: [16]u8 = p[0..16].*;
    return @bitCast(b);
}

inline fn psrldq(v: X, comptime n: u8) X {
    const in: @Vector(16, u8) = @bitCast(v);
    var out: @Vector(16, u8) = @splat(0);
    comptime var i: usize = 0;
    inline while (i < 16) : (i += 1) {
        if (i + n < 16) out[i] = in[i + n];
    }
    return @bitCast(out);
}

inline fn extract1(v: X) u32 {
    const b: [16]u8 = @bitCast(v);
    return std.mem.readInt(u32, b[4..8], .little);
}

fn reduce128(x1_in: X) u32 {
    var x1 = x1_in;
    var x0 = K3K4;
    const x2 = clmul(x1, x0, 0x10);
    x1 = psrldq(x1, 8) ^ x2;
    x0 = K5K0;
    var t = psrldq(x1, 4);
    x1 = x1 & MASK32;
    x1 = clmul(x1, x0, 0x00) ^ t;
    x0 = POLYNOMIAL;
    t = x1 & MASK32;
    t = clmul(t, x0, 0x10) & MASK32;
    t = clmul(t, x0, 0x00);
    x1 = x1 ^ t;
    return extract1(x1);
}

inline fn storeu(p: [*]u8, value: X) void {
    p[0..16].* = @bitCast(value);
}

fn pclmul64Body(comptime copying: bool, data: []const u8, crc_in: u32, dest: []u8) u32 {
    std.debug.assert(data.len >= 64);
    std.debug.assert(data.len % 16 == 0);
    var x1 = loadu(data.ptr + 0);
    var x2 = loadu(data.ptr + 16);
    var x3 = loadu(data.ptr + 32);
    var x4 = loadu(data.ptr + 48);
    if (copying) {
        storeu(dest.ptr, x1);
        storeu(dest.ptr + 16, x2);
        storeu(dest.ptr + 32, x3);
        storeu(dest.ptr + 48, x4);
    }
    x1[0] ^= crc_in;
    const k64 = K1K2;
    var off: usize = 64;
    while (off + 64 <= data.len) : (off += 64) {
        const y1 = loadu(data.ptr + off + 0);
        const y2 = loadu(data.ptr + off + 16);
        const y3 = loadu(data.ptr + off + 32);
        const y4 = loadu(data.ptr + off + 48);
        if (copying) {
            storeu(dest.ptr + off, y1);
            storeu(dest.ptr + off + 16, y2);
            storeu(dest.ptr + off + 32, y3);
            storeu(dest.ptr + off + 48, y4);
        }
        const a1 = clmul(x1, k64, 0x00);
        const a2 = clmul(x2, k64, 0x00);
        const a3 = clmul(x3, k64, 0x00);
        const a4 = clmul(x4, k64, 0x00);
        x1 = clmul(x1, k64, 0x11) ^ a1 ^ y1;
        x2 = clmul(x2, k64, 0x11) ^ a2 ^ y2;
        x3 = clmul(x3, k64, 0x11) ^ a3 ^ y3;
        x4 = clmul(x4, k64, 0x11) ^ a4 ^ y4;
    }
    const k16 = K3K4;
    var t = clmul(x1, k16, 0x00);
    x1 = clmul(x1, k16, 0x11) ^ x2 ^ t;
    t = clmul(x1, k16, 0x00);
    x1 = clmul(x1, k16, 0x11) ^ x3 ^ t;
    t = clmul(x1, k16, 0x00);
    x1 = clmul(x1, k16, 0x11) ^ x4 ^ t;
    while (off < data.len) : (off += 16) {
        const nxt = loadu(data.ptr + off);
        if (copying) storeu(dest.ptr + off, nxt);
        t = clmul(x1, k16, 0x00);
        x1 = clmul(x1, k16, 0x11) ^ nxt ^ t;
    }
    return reduce128(x1);
}

pub fn finish(crc_in: u32) u32 {
    return crc_in ^ 0xffffffff;
}

const HAVE_ARM_CRC = switch (builtin.cpu.arch) {
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

pub fn update(crc_in: u32, data: []const u8) u32 {
    if (comptime HAVE_ARM_CRC) return updateArm(crc_in, data);
    if (data.len == 0) return crc_in;
    if (comptime HAVE_PCLMUL) {
        if (data.len >= 64) {
            const bulk = data.len & ~@as(usize, 15);
            if (bulk >= 64) {
                return tail(pclmul64Body(false, data[0..bulk], crc_in, &.{}), data[bulk..]);
            }
        }
    }
    return updatePortable(crc_in, data);
}

/// Copies non-overlapping slices of equal length and updates the raw gzip CRC.
pub fn copyUpdate(crc_in: u32, data: []const u8, dest: []u8) u32 {
    std.debug.assert(data.len == dest.len);
    if (comptime HAVE_PCLMUL) {
        if (data.len >= 64) {
            const bulk = data.len & ~@as(usize, 15);
            const value = pclmul64Body(true, data[0..bulk], crc_in, dest[0..bulk]);
            @memcpy(dest[bulk..], data[bulk..]);
            return tail(value, data[bulk..]);
        }
    }
    @memcpy(dest, data);
    return update(crc_in, data);
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
                    native = update(native, part);
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
                    value = copyUpdate(value, bytes[prefix + i ..][0..n], copied[start + i ..][0..n]);
                    i += n;
                }
                value = copyUpdate(value, &.{}, copied[start..start]);
                try std.testing.expectEqual(expected, finish(value));
                try std.testing.expectEqualSlices(u8, bytes[prefix..][0..length], copied[start..][0..length]);
                for (copied[0..start]) |b| try std.testing.expectEqual(@as(u8, 0xa5), b);
                for (copied[start + length ..]) |b| try std.testing.expectEqual(@as(u8, 0xa5), b);
            }
        }
    }
}
