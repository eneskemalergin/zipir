//! The DEFLATE fast decode loop as a leaf routine: it decodes from `State` while one worst-case step fits in both
//! buffers and reports why it stopped. A build whose target lacks BMI2 also carries the loop compiled with it and
//! takes that copy when the running CPU has BMI1 and BMI2. Table entries are libdeflate's (MIT; notice in `LICENSE`):
//! low byte the bits to consume, bits 8 to 11 the code length, bit 31 a literal in bits 16 to 23, and with `PAIR` a
//! second literal in bits 8 to 15 and the first code's length in bits 24 to 27. The caller assumes nothing about
//! `out[0..]` past the returned position.

const std = @import("std");
const options = @import("kernel_options");
const cpu = @import("cpu.zig");

extern fn zipir_huff_loop_x86_bmi2_run(state: *State, variant: u32) callconv(.c) u32;

pub const LIT_TABLEBITS = 11;
pub const DIST_TABLEBITS = 8;

pub const LITERAL: u32 = 0x8000_0000;
pub const EXCEPTIONAL: u32 = 0x8000;
pub const SUBTABLE: u32 = 0x4000;
pub const END_OF_BLOCK: u32 = 0x2000;
pub const PAIR: u32 = 0x4000_0000;

pub const ROOM = 4 + 258 + 5 * 8 - 1;

pub const READ = (63 + 2 * LIT_TABLEBITS + 20 + 28 + 7) / 8 + 8;

pub const State = extern struct {
    src: [*]const u8,
    src_len: usize,
    at: usize,
    out: [*]u8,
    out_len: usize,
    out_pos: usize,
    lit: [*]const u32,
    dist: [*]const u32,
    mask: u64,
    history: u64,
    bits: u64,
    nbits: u32,
};

pub const Result = enum(u32) { more, end, bad_symbol, bad_distance };

pub const has_backend = options.huff_loop_x86_bmi2 == .object;

pub fn useBackend() bool {
    return cpu.has(.bmi2) and cpu.has(.bmi);
}

pub fn backend(state: *State, comptime full_history: bool, comptime pairs: bool) Error!bool {
    const variant = @as(u32, @intFromBool(full_history)) | @as(u32, @intFromBool(pairs)) << 1;
    return switch (@as(Result, @enumFromInt(zipir_huff_loop_x86_bmi2_run(state, variant)))) {
        .more => false,
        .end => true,
        .bad_symbol => error.BadSymbol,
        .bad_distance => error.BadDistance,
    };
}

pub inline fn varbits(word: u64, count: u32) u64 {
    return word & ((@as(u64, 1) << @as(u6, @truncate(count))) - 1);
}

pub inline fn subtableEntry(table: [*]const u32, entry: u32, bits: u64) u32 {
    return table[(entry >> 16) + @as(u32, @intCast(varbits(bits, (entry >> 8) & 0x3f)))];
}

inline fn putLiteral(out: [*]u8, entry: anytype, comptime pairs: bool) [*]u8 {
    if (!pairs) {
        out[0] = entry;
        return out + 1;
    }
    std.mem.writeInt(u16, out[0..2], @truncate(entry >> 8), .big);
    return out + (entry >> 30) - 1;
}

pub const Error = error{ BadSymbol, BadDistance };

pub fn run(ctx: anytype, lit_in: [*]const u32, dist_in: [*]const u32, mask_in: u64, comptime full_history: bool, comptime pairs: bool) Error!bool {
    const br = ctx.br;
    const output = ctx.out;
    const input = br.src;
    if (output.len - ctx.out_pos < ROOM or input.len - br.i < READ or br.nbits >= 64) return false;
    var bitbuf = br.bits;
    var bitsleft: u32 = br.nbits;
    var in: [*]const u8 = input.ptr + br.i;
    const in_stop: [*]const u8 = input.ptr + (input.len - READ);
    var out: [*]u8 = output.ptr + ctx.out_pos;
    const out_start = out;
    const out_stop: [*]u8 = output.ptr + (output.len - ROOM);
    const history = ctx.position() - ctx.stream_start;
    const lit = lit_in;
    const dist = dist_in;
    const mask = mask_in;
    const Held = if (pairs) u32 else u8;
    defer {
        br.bits = bitbuf;
        br.nbits = bitsleft & 0xff;
        br.i = @intFromPtr(in) - @intFromPtr(input.ptr);
        ctx.out_pos = @intFromPtr(out) - @intFromPtr(output.ptr);
    }
    bitbuf |= std.mem.readInt(u64, in[0..8], .little) << @as(u6, @truncate(bitsleft));
    in += 7 - ((bitsleft >> 3) & 7);
    bitsleft |= 56;
    var entry = lit[@intCast(bitbuf & mask)];
    while (@intFromPtr(in) <= @intFromPtr(in_stop) and @intFromPtr(out) <= @intFromPtr(out_stop)) {
        var saved = bitbuf;
        bitbuf >>= @as(u6, @truncate(entry));
        bitsleft -%= entry;
        if (entry & LITERAL != 0) {
            var literal: Held = if (pairs) entry else @truncate(entry >> 16);
            entry = lit[@intCast(bitbuf & mask)];
            saved = bitbuf;
            bitbuf >>= @as(u6, @truncate(entry));
            bitsleft -%= entry;
            out = putLiteral(out, literal, pairs);
            if (entry & LITERAL != 0) {
                literal = if (pairs) entry else @truncate(entry >> 16);
                entry = lit[@intCast(bitbuf & mask)];
                saved = bitbuf;
                bitbuf >>= @as(u6, @truncate(entry));
                bitsleft -%= entry;
                out = putLiteral(out, literal, pairs);
                if (entry & LITERAL != 0) {
                    literal = if (pairs) entry else @truncate(entry >> 16);
                    entry = lit[@intCast(bitbuf & mask)];
                    bitbuf |= std.mem.readInt(u64, in[0..8], .little) << @as(u6, @truncate(bitsleft));
                    in += 7 - ((bitsleft >> 3) & 7);
                    bitsleft |= 56;
                    out = putLiteral(out, literal, pairs);
                    continue;
                }
            }
        }
        if (entry & EXCEPTIONAL != 0) {
            if (entry & SUBTABLE == 0) {
                if (entry & END_OF_BLOCK != 0) return true;
                return error.BadSymbol;
            }
            entry = subtableEntry(lit, entry, bitbuf);
            saved = bitbuf;
            bitbuf >>= @as(u6, @truncate(entry));
            bitsleft -%= entry;
            if (entry & LITERAL != 0) {
                const byte: u8 = @truncate(entry >> 16);
                entry = lit[@intCast(bitbuf & mask)];
                bitbuf |= std.mem.readInt(u64, in[0..8], .little) << @as(u6, @truncate(bitsleft));
                in += 7 - ((bitsleft >> 3) & 7);
                bitsleft |= 56;
                out[0] = byte;
                out += 1;
                continue;
            }
            if (entry & EXCEPTIONAL != 0) {
                if (entry & END_OF_BLOCK != 0) return true;
                return error.BadSymbol;
            }
        }
        const length: usize = (entry >> 16) + @as(u32, @intCast(varbits(saved, entry) >> @as(u6, @truncate(entry >> 8))));
        entry = dist[@intCast(bitbuf & 0xff)];
        if (entry & EXCEPTIONAL != 0) {
            if (entry & SUBTABLE == 0) return error.BadSymbol;
            if (@as(u8, @truncate(bitsleft)) < 28 + LIT_TABLEBITS - 1) {
                bitbuf |= std.mem.readInt(u64, in[0..8], .little) << @as(u6, @truncate(bitsleft));
                in += 7 - ((bitsleft >> 3) & 7);
                bitsleft |= 56;
            }
            bitbuf >>= DIST_TABLEBITS;
            bitsleft -%= DIST_TABLEBITS;
            entry = subtableEntry(dist, entry, bitbuf);
            if (entry & EXCEPTIONAL != 0) return error.BadSymbol;
        } else if (@as(u8, @truncate(bitsleft)) < 21 + LIT_TABLEBITS - 1) {
            bitbuf |= std.mem.readInt(u64, in[0..8], .little) << @as(u6, @truncate(bitsleft));
            in += 7 - ((bitsleft >> 3) & 7);
            bitsleft |= 56;
        }
        saved = bitbuf;
        bitbuf >>= @as(u6, @truncate(entry));
        bitsleft -%= entry;
        const distance: usize = (entry >> 16) + @as(u32, @intCast(varbits(saved, entry) >> @as(u6, @truncate(entry >> 8))));
        if (!full_history and distance > history + (@intFromPtr(out) - @intFromPtr(out_start))) return error.BadDistance;
        var src = out - distance;
        var dst = out;
        out += length;
        entry = lit[@intCast(bitbuf & mask)];
        bitbuf |= std.mem.readInt(u64, in[0..8], .little) << @as(u6, @truncate(bitsleft));
        in += 7 - ((bitsleft >> 3) & 7);
        bitsleft |= 56;
        if (distance >= 8) {
            inline for (0..5) |_| {
                dst[0..8].* = src[0..8].*;
                src += 8;
                dst += 8;
            }
            while (@intFromPtr(dst) < @intFromPtr(out)) {
                inline for (0..5) |_| {
                    dst[0..8].* = src[0..8].*;
                    src += 8;
                    dst += 8;
                }
            }
        } else if (distance == 1) {
            const v: @Vector(8, u8) = @splat(src[0]);
            inline for (0..4) |_| {
                dst[0..8].* = v;
                dst += 8;
            }
            while (@intFromPtr(dst) < @intFromPtr(out)) {
                inline for (0..4) |_| {
                    dst[0..8].* = v;
                    dst += 8;
                }
            }
        } else {
            inline for (0..2) |_| {
                std.mem.writeInt(u64, dst[0..8], std.mem.readInt(u64, src[0..8], .little), .little);
                src += distance;
                dst += distance;
            }
            while (true) {
                inline for (0..2) |_| {
                    std.mem.writeInt(u64, dst[0..8], std.mem.readInt(u64, src[0..8], .little), .little);
                    src += distance;
                    dst += distance;
                }
                if (@intFromPtr(dst) >= @intFromPtr(out)) break;
            }
        }
    }
    return false;
}
