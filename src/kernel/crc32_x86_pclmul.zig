//! PCLMUL CRC-32 fold for 64 or more bytes in whole 16-byte blocks, imported directly when the
//! target guarantees PCLMUL and SSE4.1, otherwise built as an object that exports C symbols. The fold and Barrett
//! constants are the reflected IEEE CRC-32 ones of Intel's PCLMUL CRC paper, as zlib's SSE path uses them.

const std = @import("std");
const options = @import("kernel_options");

pub fn update(crc_in: u32, data: []const u8) u32 {
    return pclmul64Body(false, data, crc_in, &.{});
}

pub fn copyUpdate(crc_in: u32, data: []const u8, dest: []u8) u32 {
    return pclmul64Body(true, data, crc_in, dest);
}

comptime {
    if (options.as_object) {
        @export(&updateExport, .{ .name = "zipir_crc32_x86_pclmul_update" });
        @export(&copyUpdateExport, .{ .name = "zipir_crc32_x86_pclmul_copy_update" });
    }
}

fn updateExport(crc_in: u32, data: [*]const u8, len: usize) callconv(.c) u32 {
    return update(crc_in, data[0..len]);
}

fn copyUpdateExport(crc_in: u32, data: [*]const u8, dest: [*]u8, len: usize) callconv(.c) u32 {
    return copyUpdate(crc_in, data[0..len], dest[0..len]);
}

const X = @Vector(2, u64);

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
        else => @compileError("unsupported pclmulqdq immediate"),
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
