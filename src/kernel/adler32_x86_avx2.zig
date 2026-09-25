//! AVX2 Adler-32 update, imported directly when the target guarantees AVX2, otherwise built as an
//! object that exports a C symbol.

const options = @import("kernel_options");

const Bytes = @Vector(32, u8);
const Words = @Vector(16, i16);
const Dwords = @Vector(8, u32);

const MODULUS: u64 = 65_521;
const MAX_CHUNK: usize = 8_192;

const ZERO_BYTES: Bytes = @splat(0);
const MULTS_A: Words = .{ 64, 63, 62, 61, 60, 59, 58, 57, 56, 55, 54, 53, 52, 51, 50, 49 };
const MULTS_B: Words = .{ 48, 47, 46, 45, 44, 43, 42, 41, 40, 39, 38, 37, 36, 35, 34, 33 };
const MULTS_C: Words = .{ 32, 31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18, 17 };
const MULTS_D: Words = .{ 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 };

pub fn update(start: u32, bytes: []const u8) u32 {
    return updateRaw(start, bytes.ptr, bytes.len);
}

comptime {
    if (options.as_object) @export(&updateRaw, .{ .name = "zipir_adler32_x86_avx2_update" });
}

fn updateRaw(start: u32, bytes: [*]const u8, len: usize) callconv(.c) u32 {
    var a: u64 = start & 0xffff;
    var b: u64 = start >> 16;
    var offset: usize = 0;

    while (offset < len) {
        const chunk = @min(MAX_CHUNK, len - offset);
        const previous_a = a;
        const vector_chunk = chunk & ~@as(usize, 63);

        if (vector_chunk >= 64) {
            b += previous_a * vector_chunk;
            var sum: Dwords = @splat(0);
            var sum_of_sums: Dwords = @splat(0);
            var byte_a: Words = @splat(0);
            var byte_b: Words = @splat(0);
            var byte_c: Words = @splat(0);
            var byte_d: Words = @splat(0);

            var local: usize = 0;
            while (local < vector_chunk) : (local += 64) {
                const data_a = load(bytes, offset + local);
                const data_b = load(bytes, offset + local + 32);

                sum_of_sums += sum;
                byte_a += widenLowHalf(data_a);
                byte_b += widenHighHalf(data_a);
                byte_c += widenLowHalf(data_b);
                byte_d += widenHighHalf(data_b);
                sum += sadBytes(data_a);
                sum += sadBytes(data_b);
            }

            var weighted: Dwords = sum_of_sums << @as(@Vector(8, u5), @splat(6));
            weighted += madd16(byte_a, MULTS_A);
            weighted += madd16(byte_b, MULTS_B);
            weighted += madd16(byte_c, MULTS_C);
            weighted += madd16(byte_d, MULTS_D);
            a += @as(u64, @intCast(@reduce(.Add, sum)));
            var weighted_total: u64 = 0;
            inline for (0..8) |index| weighted_total += weighted[index];
            b += weighted_total;
            offset += vector_chunk;
        } else {
            while (offset < len and offset < offset + chunk) : (offset += 1) {
                a += bytes[offset];
                b += a;
            }
        }

        a %= MODULUS;
        b %= MODULUS;
    }
    return @as(u32, @intCast(a)) | (@as(u32, @intCast(b)) << 16);
}

fn load(bytes: [*]const u8, offset: usize) Bytes {
    return @bitCast(bytes[offset..][0..32].*);
}

fn widenLowHalf(data: Bytes) Words {
    const selected: @Vector(16, u8) = @shuffle(u8, data, undefined, [_]i32{
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    });
    return @intCast(selected);
}

fn widenHighHalf(data: Bytes) Words {
    const selected: @Vector(16, u8) = @shuffle(u8, data, undefined, [_]i32{
        16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
    });
    return @intCast(selected);
}

fn madd16(a: Words, b: Words) Dwords {
    return asm volatile ("vpmaddwd %[a], %[b], %[out]"
        : [out] "=x" (-> Dwords),
        : [a] "x" (a),
          [b] "x" (b),
    );
}

fn sadBytes(data: Bytes) Dwords {
    return asm volatile ("vpsadbw %[zero], %[data], %[out]"
        : [out] "=x" (-> Dwords),
        : [data] "x" (data),
          [zero] "x" (ZERO_BYTES),
    );
}
