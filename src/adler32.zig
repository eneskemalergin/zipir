//! Streaming Adler-32 with a runtime-selected accelerated backend.

const std = @import("std");
const builtin = @import("builtin");
const adler_options = @import("adler_options");

const MODULUS: u32 = 65_521;
const NMAX: usize = 5_552;
const AVX2_MIN_LENGTH: usize = 128;
const USE_SCALAR = std.mem.eql(u8, adler_options.backend, "scalar");

const Backend = enum(u8) {
    portable,
    x86_avx2,
};

extern fn adler32_x86_avx2_update(start: u32, bytes: [*]const u8, len: usize) callconv(.c) u32;

var cached_features: std.atomic.Value(u8) = .init(0);

const FeatureBits = struct {
    x86_avx2: bool = false,

    fn encode(self: FeatureBits) u8 {
        return @intFromBool(self.x86_avx2);
    }

    fn decode(value: u8) FeatureBits {
        return .{ .x86_avx2 = value & 1 != 0 };
    }
};

pub const Stream = struct {
    checksum: u32 = 1,

    pub fn init() Stream {
        return .{};
    }

    pub fn update(self: *Stream, bytes: []const u8) void {
        if (comptime USE_SCALAR) {
            self.updatePortable(bytes);
        } else {
            self.checksum = updateDispatched(self.checksum, bytes);
        }
    }

    fn updatePortable(self: *Stream, bytes: []const u8) void {
        self.checksum = updatePortableChunk(self.checksum, bytes);
    }

    pub fn final(self: *const Stream) u32 {
        return self.checksum;
    }
};

// --- Backend dispatch ---

fn cpuFeatures() FeatureBits {
    const cached = cached_features.load(.monotonic);
    if (cached != 0) return FeatureBits.decode(cached - 1);

    const detected = detectFeatures();
    cached_features.store(detected.encode() + 1, .monotonic);
    return detected;
}

fn chooseBackend(features: FeatureBits) Backend {
    if (comptime builtin.cpu.arch == .x86_64) {
        if (features.x86_avx2) return .x86_avx2;
    }
    return .portable;
}

fn updateWithBackend(start: u32, bytes: []const u8, backend: Backend) u32 {
    return switch (backend) {
        .portable => updatePortableChunk(start, bytes),
        .x86_avx2 => {
            if (comptime builtin.cpu.arch != .x86_64) return updatePortableChunk(start, bytes);
            if (bytes.len < AVX2_MIN_LENGTH) return updatePortableChunk(start, bytes);
            return adler32_x86_avx2_update(start, bytes.ptr, bytes.len);
        },
    };
}

fn updateDispatched(start: u32, bytes: []const u8) u32 {
    if (bytes.len == 0) return start;
    if (bytes.len < AVX2_MIN_LENGTH) return updatePortableChunk(start, bytes);
    return updateWithBackend(start, bytes, chooseBackend(cpuFeatures()));
}

// --- Portable update ---

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

// --- CPU feature detection ---

fn detectFeatures() FeatureBits {
    if (comptime builtin.cpu.arch == .x86_64) return detectX86Features();
    return .{};
}

const CpuidLeaf = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

fn cpuid(leaf_id: u32, subid: u32) CpuidLeaf {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf_id),
          [_] "{ecx}" (subid),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn xgetbv0() u32 {
    return asm volatile (
        \\xorl %%ecx, %%ecx
        \\xgetbv
        : [_] "={eax}" (-> u32),
        :
        : .{ .ecx = true, .edx = true });
}

fn avxStateEnabled(has_osxsave: bool, has_avx: bool, xcr0: u32) bool {
    return has_osxsave and has_avx and xcr0 & 0x6 == 0x6;
}

fn detectX86Features() FeatureBits {
    const maximum = cpuid(0, 0).eax;
    if (maximum < 1) return .{};

    const leaf1 = cpuid(1, 0);
    const has_osxsave = leaf1.ecx & (1 << 27) != 0;
    const has_avx = leaf1.ecx & (1 << 28) != 0;
    const xcr0 = if (has_osxsave and has_avx) xgetbv0() else 0;
    const avx_state = avxStateEnabled(has_osxsave, has_avx, xcr0);

    const has_avx2 = maximum >= 7 and avx_state and cpuid(7, 0).ebx & (1 << 5) != 0;
    return .{ .x86_avx2 = has_avx2 };
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
    const stream = Stream.init();
    try std.testing.expectEqual(@as(u32, 1), stream.final());
    try std.testing.expectEqual(@sizeOf(std.hash.Adler32), @sizeOf(Stream));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Stream));
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
        var stream = Stream.init();
        var offset: usize = 0;
        while (offset < bytes.len) {
            const amount = @min(chunk_size, bytes.len - offset);
            stream.updatePortable(bytes[offset .. offset + amount]);
            offset += amount;
        }
        try std.testing.expectEqual(reference(&bytes), stream.final());
    }
}

test "[property] - [adler]: portable and dispatched streams produce the same checksum" {
    var bytes: [8_193]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x2468_1357);
    random.fill(&bytes);

    var portable = Stream.init();
    var dispatched = Stream.init();
    portable.updatePortable(bytes[0..31]);
    portable.updatePortable(bytes[31..4096]);
    portable.updatePortable(bytes[4096..]);
    dispatched.update(bytes[0..31]);
    dispatched.update(bytes[31..4096]);
    dispatched.update(bytes[4096..]);

    try std.testing.expectEqual(portable.final(), dispatched.final());
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(@TypeOf(portable)));
}

test "[edge] - [adler]: tiny updates stay on the portable path" {
    var stream = Stream.init();
    stream.update("a");
    try std.testing.expectEqual(@as(u32, 0x0062_0062), stream.final());
}

test "[edge] - [adler]: empty updates do not change state" {
    var stream = Stream.init();
    stream.update("");
    try std.testing.expectEqual(@as(u32, 1), stream.final());
}

test "[unit] - [adler]: known vectors match Adler-32" {
    var stream = Stream.init();
    stream.updatePortable("a");
    try std.testing.expectEqual(@as(u32, 0x0062_0062), stream.final());

    stream = Stream.init();
    stream.updatePortable("example");
    try std.testing.expectEqual(@as(u32, 0x0bc0_02ed), stream.final());

    stream = Stream.init();
    stream.updatePortable("123456789");
    try std.testing.expectEqual(@as(u32, 0x091e_01de), stream.final());
}

test "[unit] - [adler]: AVX state requires OSXSAVE and XMM/YMM state" {
    try std.testing.expect(!avxStateEnabled(false, true, 0x6));
    try std.testing.expect(!avxStateEnabled(true, false, 0x6));
    try std.testing.expect(!avxStateEnabled(true, true, 0x2));
    try std.testing.expect(avxStateEnabled(true, true, 0x6));
}

test "[unit] - [adler]: backend selection keeps the portable fallback" {
    try std.testing.expectEqual(Backend.portable, chooseBackend(.{}));
    if (comptime builtin.cpu.arch == .x86_64) {
        try std.testing.expectEqual(Backend.x86_avx2, chooseBackend(.{ .x86_avx2 = true }));
    } else {
        try std.testing.expectEqual(Backend.portable, chooseBackend(.{ .x86_avx2 = true }));
    }
}
