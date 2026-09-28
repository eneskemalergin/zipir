//! What DEFLATE's decoder and encoder share (RFC 1951).

pub const CLEN_ORDER = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
pub const LEN_EXTRA = [_]u4{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
pub const DIST_EXTRA = [_]u4{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
pub const LEN_BASE = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
pub const DIST_BASE = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };

pub const WINDOW = 32768;

pub const FIXED_LIT_LENS: [288]u4 = blk: {
    var lengths: [288]u4 = undefined;
    @memset(lengths[0..144], 8);
    @memset(lengths[144..256], 9);
    @memset(lengths[256..280], 7);
    @memset(lengths[280..288], 8);
    break :blk lengths;
};
pub const FIXED_DIST_LENS = [_]u4{5} ** 32;

pub fn bitReverse(code: u16, n: u4) u16 {
    if (n == 0) return 0;
    return @bitReverse(code) >> @intCast(16 - @as(u16, n));
}

// `.symbols` also accepts an incomplete code of at most one symbol, as distance codes may be.
pub fn buildCodes(lens: []const u4, codes: []u16, kind: enum { codes, symbols }) !void {
    var bl_count: [16]u16 = .{0} ** 16;
    for (lens) |code_len| {
        if (code_len != 0) bl_count[code_len] += 1;
    }
    var next_code: [16]u16 = .{0} ** 16;
    var code: u32 = 0;
    var left: i32 = 1;
    for (1..16) |bit_len| {
        const code_len: u4 = @intCast(bit_len);
        code = (code + bl_count[code_len - 1]) << 1;
        left = left * 2 - bl_count[code_len];
        if (left < 0) return error.BadHuffman;
        next_code[code_len] = @intCast(code & 0xffff);
    }
    if (left != 0) {
        var symbols: usize = 0;
        for (bl_count[1..]) |count| symbols += count;
        if (kind == .codes or (symbols != 0 and !(symbols == 1 and bl_count[1] == 1))) return error.BadHuffman;
    }
    for (lens, codes) |len, *c| {
        if (len == 0) {
            c.* = 0;
            continue;
        }
        c.* = next_code[len];
        next_code[len] +%= 1;
    }
}
