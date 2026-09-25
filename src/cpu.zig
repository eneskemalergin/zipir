//! CPU feature detection for the kernel dispatchers, run once per process and cached.

const std = @import("std");
const builtin = @import("builtin");

var cached_features: std.atomic.Value(u8) = .init(0);

pub const Features = struct {
    x86_avx2: bool = false,

    fn encode(self: Features) u8 {
        return @intFromBool(self.x86_avx2);
    }

    fn decode(value: u8) Features {
        return .{ .x86_avx2 = value & 1 != 0 };
    }
};

pub fn features() Features {
    const cached = cached_features.load(.monotonic);
    if (cached != 0) return Features.decode(cached - 1);

    const detected = detectFeatures();
    cached_features.store(detected.encode() + 1, .monotonic);
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

    const has_avx2 = maximum >= 7 and avx_state and cpuid(7, 0).ebx & (1 << 5) != 0;
    return .{ .x86_avx2 = has_avx2 };
}

test "[unit] - [cpu]: AVX state requires OSXSAVE and XMM/YMM state" {
    try std.testing.expect(!avxStateEnabled(false, true, 0x6));
    try std.testing.expect(!avxStateEnabled(true, false, 0x6));
    try std.testing.expect(!avxStateEnabled(true, true, 0x2));
    try std.testing.expect(avxStateEnabled(true, true, 0x6));
}
