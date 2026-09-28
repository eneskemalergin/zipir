//! Checks the compressors as `std.Io.Writer`s: output that depends only on the bytes written, never on the
//! write sizes; contiguous requests; flush; the end of a stream; and failure.

const std = @import("std");
const zipir = @import("zipir");
const support = @import("support.zig");

const Format = zipir.Format;
const formats = [_]Format{ .gzip, .zlib, .deflate };
const presets = [_]zipir.Preset{ .fast, .even, .dense };

fn makePlain(allocator: std.mem.Allocator, len: usize) ![]u8 {
    const plain = try allocator.alloc(u8, len);
    var random = std.Random.DefaultPrng.init(23);
    for (plain, 0..) |*b, i| b.* = switch ((i / 40_000) % 4) {
        0, 1 => if (i % 71 == 70) '\n' else "ACGTN"[(i * 13 + i / 7) % 5],
        2 => random.random().int(u8),
        else => @truncate(i / 300),
    };
    return plain;
}

const Pattern = union(enum) { sizes: usize, random, slices: usize, ints };

// Writes `plain` through the compressor with one pattern and returns the whole output.
fn write(allocator: std.mem.Allocator, encoder: anytype, plain: []const u8, preset: zipir.Preset, pattern: Pattern) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try encoder.init(&out.writer, .{ .preset = preset });
    const w = &encoder.writer;
    var at: usize = 0;
    var random = std.Random.DefaultPrng.init(plain.len);
    while (at < plain.len) {
        const n = switch (pattern) {
            .sizes => |size| @min(size, plain.len - at),
            .random => @min(random.random().intRangeAtMost(usize, 1, 70_000), plain.len - at),
            .slices => |size| @min(size, plain.len - at),
            .ints => @min(4, plain.len - at),
        };
        switch (pattern) {
            .slices => @memcpy(try w.writableSlice(n), plain[at..][0..n]),
            .ints => if (n == 4) try w.writeInt(u32, std.mem.readInt(u32, plain[at..][0..4], .little), .little) else try w.writeAll(plain[at..][0..n]),
            else => try w.writeAll(plain[at..][0..n]),
        }
        at += n;
    }
    try std.testing.expectEqual(@as(u64, plain.len), try encoder.finish());
    return out.toOwnedSlice();
}

fn decode(allocator: std.mem.Allocator, comptime format: Format, stream: []const u8) ![]u8 {
    const decoder = try allocator.create(zipir.Decompressor(format));
    defer allocator.destroy(decoder);
    var input = std.Io.Reader.fixed(stream);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    _ = try support.decompressAll(decoder, &input, &out.writer, .{});
    return out.toOwnedSlice();
}

test "[property] - [writer]: output depends only on the bytes, whatever the write sizes" {
    const allocator = std.testing.allocator;
    const plain = try makePlain(allocator, 230_000);
    defer allocator.free(plain);
    inline for (formats) |format| {
        const encoder = try allocator.create(zipir.Compressor(format));
        defer allocator.destroy(encoder);
        for (presets) |preset| {
            const whole = try write(allocator, encoder, plain, preset, .{ .sizes = plain.len });
            defer allocator.free(whole);
            const decoded = try decode(allocator, format, whole);
            defer allocator.free(decoded);
            try std.testing.expectEqualSlices(u8, plain, decoded);
            const patterns = [_]Pattern{ .{ .sizes = 13 }, .{ .sizes = 32767 }, .{ .sizes = 32768 }, .{ .sizes = 32769 }, .{ .sizes = 65536 }, .random, .{ .slices = 32768 }, .{ .slices = 1000 }, .ints };
            for (patterns) |pattern| {
                const got = try write(allocator, encoder, plain, preset, pattern);
                defer allocator.free(got);
                try std.testing.expectEqualSlices(u8, whole, got);
            }
        }
    }
}

test "[property] - [writer]: one-byte writes and window-sized inputs give the same output" {
    const allocator = std.testing.allocator;
    const plain = try makePlain(allocator, 98_305);
    defer allocator.free(plain);
    const encoder = try allocator.create(zipir.Compressor(.gzip));
    defer allocator.destroy(encoder);
    // Exactly one, two, and three windows, one byte either side, and nothing.
    for ([_]usize{ 0, 1, 32767, 32768, 32769, 65536, 98304, 98305 }) |len| {
        const whole = try write(allocator, encoder, plain[0..len], .even, .{ .sizes = len + 1 });
        defer allocator.free(whole);
        const bytes = try write(allocator, encoder, plain[0..len], .even, .{ .sizes = 1 });
        defer allocator.free(bytes);
        try std.testing.expectEqualSlices(u8, whole, bytes);
        const decoded = try decode(allocator, .gzip, whole);
        defer allocator.free(decoded);
        try std.testing.expectEqualSlices(u8, plain[0..len], decoded);
    }
}

test "[edge] - [writer]: a contiguous request of 32 KiB fits at every fill" {
    const allocator = std.testing.allocator;
    const plain = try makePlain(allocator, 100_000);
    defer allocator.free(plain);
    const encoder = try allocator.create(zipir.Compressor(.deflate));
    defer allocator.destroy(encoder);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    for ([_]usize{ 0, 1, 32767, 32768, 32769, 50000, 65535 }) |fill| {
        try encoder.init(&discard.writer, .{});
        try encoder.writer.writeAll(plain[0..fill]);
        const slice = try encoder.writer.writableSlice(32768);
        try std.testing.expectEqual(@as(usize, 32768), slice.len);
        @memcpy(slice, plain[fill..][0..32768]);
        _ = try encoder.finish();
    }
}

test "[integration] - [writer]: flush makes everything written so far decodable" {
    const allocator = std.testing.allocator;
    const plain = try makePlain(allocator, 150_000);
    defer allocator.free(plain);
    inline for (formats) |format| {
        const encoder = try allocator.create(zipir.Compressor(format));
        defer allocator.destroy(encoder);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try encoder.init(&out.writer, .{});
        try encoder.writer.writeAll(plain[0..70_000]);
        try encoder.writer.flush();
        const at_flush = out.written().len;
        // A reader of the output so far gets every byte written before the flush, then runs out of input.
        const decoder = try allocator.create(zipir.Decompressor(format));
        defer allocator.destroy(decoder);
        var partial = std.Io.Reader.fixed(out.written()[0..at_flush]);
        decoder.init(&partial, .{});
        try decoder.reader.discardAll(70_000);
        try std.testing.expectError(error.ReadFailed, decoder.reader.peekByte());
        try std.testing.expect(decoder.err.? == error.Truncated);
        try encoder.writer.flush();
        try encoder.writer.writeAll(plain[70_000..]);
        try std.testing.expectEqual(@as(u64, plain.len), try encoder.finish());
        const decoded = try decode(allocator, format, out.written());
        defer allocator.free(decoded);
        try std.testing.expectEqualSlices(u8, plain, decoded);
    }
}

test "[failure] - [writer]: the writer fails after finish and after a failed output" {
    const encoder = try std.testing.allocator.create(zipir.Compressor(.gzip));
    defer std.testing.allocator.destroy(encoder);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    try encoder.init(&discard.writer, .{});
    try encoder.writer.writeAll("abc");
    try std.testing.expectEqual(@as(u64, 3), try encoder.finish());
    try std.testing.expectError(error.WriteFailed, encoder.writer.writeAll("more"));
    try std.testing.expectError(error.WriteFailed, encoder.finish());
    // An output with room for the header only.
    var small: [12]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&small);
    try encoder.init(&fixed, .{});
    var random = std.Random.DefaultPrng.init(5);
    var noise: [70_000]u8 = undefined;
    random.fill(&noise);
    // The first windows may only be buffered, so the failure can come from the write or from `finish`.
    encoder.writer.writeAll(&noise) catch {};
    try std.testing.expectError(error.WriteFailed, encoder.finish());
    try std.testing.expectError(error.WriteFailed, encoder.writer.writeAll("x"));
    try encoder.init(&discard.writer, .{});
    try encoder.writer.writeAll("again");
    try std.testing.expectEqual(@as(u64, 5), try encoder.finish());
}

test "[property] - [writer]: BGZF output depends only on the bytes, and its errors are named" {
    const allocator = std.testing.allocator;
    const plain = try makePlain(allocator, 300_000);
    defer allocator.free(plain);
    const encoder = try allocator.create(zipir.bgzf.Compressor);
    defer allocator.destroy(encoder);
    var whole: std.Io.Writer.Allocating = .init(allocator);
    defer whole.deinit();
    try encoder.init(&whole.writer, .{ .split = .lines, .preset = .fast });
    try encoder.writer.writeAll(plain);
    _ = try encoder.finish();
    for ([_]usize{ 1, 4099, 65536, 130561 }) |size| {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try encoder.init(&out.writer, .{ .split = .lines, .preset = .fast });
        var at: usize = 0;
        while (at < plain.len) : (at += size) try encoder.writer.writeAll(plain[at..@min(plain.len, at + size)]);
        _ = try encoder.finish();
        try std.testing.expectEqualSlices(u8, whole.written(), out.written());
    }
    // An index with room for no entry: the second data block does not fit.
    var none: [0]zipir.bgzf.IndexEntry = .{};
    var index: zipir.bgzf.IndexBuilder = .init(&none);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    try encoder.init(&discard.writer, .{ .index = &index });
    try std.testing.expectError(error.WriteFailed, encoder.writer.writeAll(plain));
    try std.testing.expectEqual(@as(?zipir.bgzf.CompressError, error.IndexFull), encoder.err);
}
