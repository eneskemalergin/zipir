//! CPU feature detection for the kernel dispatchers, run once per process and cached.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("kernel_options");

pub const Feature = enum { sse4_1, pclmul, avx2 };

pub const Features = packed struct(u8) {
    sse4_1: bool = false,
    pclmul: bool = false,
    avx2: bool = false,
    _: u5 = 0,
};

var cached_features: std.atomic.Value(u16) = .init(0);

pub inline fn has(comptime feature: Feature) bool {
    if (comptime options.kernel_backend == .portable) return false;
    if (comptime guaranteed(feature)) return true;
    if (comptime builtin.cpu.arch != .x86_64) return false;
    return @field(features(), @tagName(feature));
}

fn guaranteed(comptime feature: Feature) bool {
    if (builtin.cpu.arch != .x86_64) return false;
    return std.Target.x86.featureSetHas(builtin.cpu.features, @field(std.Target.x86.Feature, @tagName(feature)));
}

pub fn features() Features {
    const cached = cached_features.load(.monotonic);
    if (cached != 0) return @bitCast(@as(u8, @truncate(cached)));

    const detected = detectFeatures();
    cached_features.store(@as(u16, @as(u8, @bitCast(detected))) | 0x100, .monotonic);
    return detected;
}

fn detectFeatures() Features {
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

fn detectX86Features() Features {
    const maximum = cpuid(0, 0).eax;
    if (maximum < 1) return .{};

    const leaf1 = cpuid(1, 0);
    const has_osxsave = leaf1.ecx & (1 << 27) != 0;
    const has_avx = leaf1.ecx & (1 << 28) != 0;
    const xcr0 = if (has_osxsave and has_avx) xgetbv0() else 0;
    const avx_state = avxStateEnabled(has_osxsave, has_avx, xcr0);

    return .{
        .sse4_1 = leaf1.ecx & (1 << 19) != 0,
        .pclmul = leaf1.ecx & (1 << 1) != 0,
        .avx2 = maximum >= 7 and avx_state and cpuid(7, 0).ebx & (1 << 5) != 0,
    };
}

test "[unit] - [cpu]: AVX state requires OSXSAVE and XMM/YMM state" {
    try std.testing.expect(!avxStateEnabled(false, true, 0x6));
    try std.testing.expect(!avxStateEnabled(true, false, 0x6));
    try std.testing.expect(!avxStateEnabled(true, true, 0x2));
    try std.testing.expect(avxStateEnabled(true, true, 0x6));
}

test "[unit] - [cpu]: detection agrees with every feature the build target guarantees" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const detected = features();
    inline for (std.meta.fields(Feature)) |field| {
        if (comptime guaranteed(@enumFromInt(field.value))) try std.testing.expect(@field(detected, field.name));
    }
    try std.testing.expectEqual(detected, features());
}

test "[unit] - [cpu]: has() follows the portable override, then target guarantees, then detection" {
    const detected = features();
    inline for (std.meta.fields(Feature)) |field| {
        const feature: Feature = @enumFromInt(field.value);
        const expected = if (options.kernel_backend == .portable)
            false
        else
            guaranteed(feature) or (builtin.cpu.arch == .x86_64 and @field(detected, field.name));
        try std.testing.expectEqual(expected, has(feature));
    }
}
