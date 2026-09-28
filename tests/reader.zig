//! Checks the decompressors as `std.Io.Reader`s under the ways callers read: borrowed chunks, small copies,
//! lines, skips, limited streams, large peeks, faults after good bytes, reuse, and the input left behind.

const std = @import("std");
const zipir = @import("zipir");
const support = @import("support.zig");

const Format = zipir.Format;
const FORMATS = [_]Format{ .gzip, .zlib, .deflate };

// Lines of text, a long run, and a random stretch (stored blocks), about 700 KB with a final newline.
fn makePlain(allocator: std.mem.Allocator) ![]u8 {
    const plain = try allocator.alloc(u8, 700_001);
    var random = std.Random.DefaultPrng.init(17);
    for (plain, 0..) |*b, i| b.* = switch (i / 100_000) {
        0, 1, 2 => if (i % 61 == 60) '\n' else "ACGTNacgt"[(i * 7 + i / 13) % 9],
        3 => 'r',
        4 => random.random().int(u8),
        else => if (i % 97 == 96) '\n' else @as(u8, 'a' + @as(u8, @intCast(i % 26))),
    };
    plain[plain.len - 1] = '\n';
    return plain;
}

fn compress(allocator: std.mem.Allocator, comptime format: Format, plain: []const u8) ![]u8 {
    const encoder = try allocator.create(zipir.Compressor(format));
    defer allocator.destroy(encoder);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var input = std.Io.Reader.fixed(plain);
    _ = try support.compressAll(encoder, &input, &out.writer, .{});
    return out.toOwnedSlice();
}

const Pattern = union(enum) { borrow, copy: usize, lines, skip: usize, limited: usize };

// Reads the whole stream with one pattern and compares every byte.
fn readAll(reader: *std.Io.Reader, pattern: Pattern, expected: []const u8) !void {
    var got: usize = 0;
    switch (pattern) {
        .borrow => while (reader.peekGreedy(1)) |chunk| {
            try std.testing.expectEqualSlices(u8, expected[got..][0..chunk.len], chunk);
            got += chunk.len;
            reader.toss(chunk.len);
        } else |err| try std.testing.expectEqual(error.EndOfStream, err),
        .copy => |size| {
            var buffer: [65536]u8 = undefined;
            while (true) {
                const n = try reader.readSliceShort(buffer[0..size]);
                try std.testing.expectEqualSlices(u8, expected[got..][0..n], buffer[0..n]);
                got += n;
                if (n < size) break;
            }
        },
        .lines => while (reader.takeDelimiterInclusive('\n')) |line| {
            try std.testing.expectEqualSlices(u8, expected[got..][0..line.len], line);
            got += line.len;
        } else |err| try std.testing.expectEqual(error.EndOfStream, err),
        .skip => |n| {
            try reader.discardAll(n);
            got = n;
            var buffer: [4096]u8 = undefined;
            while (true) {
                const k = try reader.readSliceShort(&buffer);
                try std.testing.expectEqualSlices(u8, expected[got..][0..k], buffer[0..k]);
                got += k;
                if (k < buffer.len) break;
            }
        },
        .limited => |limit| {
            var buffer: [4096]u8 = undefined;
            while (true) {
                var w = std.Io.Writer.fixed(&buffer);
                const n = reader.stream(&w, .limited(limit)) catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return err,
                };
                try std.testing.expect(n <= limit);
                try std.testing.expectEqualSlices(u8, expected[got..][0..n], w.buffered());
                got += n;
            }
        },
    }
    try std.testing.expectEqual(expected.len, got);
}

test "[integration] - [reader]: every read pattern returns the decoded stream in every format" {
    const allocator = std.testing.allocator;
    const plain = try makePlain(allocator);
    defer allocator.free(plain);
    inline for (FORMATS) |format| {
        const stream = try compress(allocator, format, plain);
        defer allocator.free(stream);
        const decoder = try allocator.create(zipir.Decompressor(format));
        defer allocator.destroy(decoder);
        const patterns = [_]Pattern{ .borrow, .{ .copy = 7 }, .{ .copy = 4093 }, .{ .copy = 65536 }, .lines, .{ .skip = 333_333 }, .{ .limited = 1 }, .{ .limited = 1000 } };
        for (patterns) |pattern| {
            for ([_][2]usize{ .{ 16, 1 }, .{ 17, 5 }, .{ 4096, 4096 }, .{ 65536, 65536 } }) |shape| {
                // Tiny input reads only with borrowing and lines: they reach every refill path already.
                if (shape[1] < 4096 and pattern != .borrow and pattern != .lines) continue;
                var input: [65536]u8 = undefined;
                var source = support.Source.init(stream, input[0..shape[0]], shape[1]);
                decoder.init(&source.reader, .{});
                try readAll(&decoder.reader, pattern, plain);
                try std.testing.expect(decoder.err == null);
            }
        }
    }
}

test "[integration] - [reader]: one-byte copies return a stream" {
    const allocator = std.testing.allocator;
    const whole = try makePlain(allocator);
    defer allocator.free(whole);
    const plain = whole[0..150_000];
    const stream = try compress(allocator, .gzip, plain);
    defer allocator.free(stream);
    const decoder = try allocator.create(zipir.Decompressor(.gzip));
    defer allocator.destroy(decoder);
    var input = std.Io.Reader.fixed(stream);
    decoder.init(&input, .{});
    try readAll(&decoder.reader, .{ .copy = 1 }, plain);
}

test "[edge] - [reader]: a peek of 128 KiB always fits and a larger one that cannot fit fails cleanly" {
    const allocator = std.testing.allocator;
    const plain = try makePlain(allocator);
    defer allocator.free(plain);
    const stream = try compress(allocator, .gzip, plain);
    defer allocator.free(stream);
    const decoder = try allocator.create(zipir.Decompressor(.gzip));
    defer allocator.destroy(decoder);
    var input = std.Io.Reader.fixed(stream);
    decoder.init(&input, .{});
    const r = &decoder.reader;
    try r.discardAll(200_003);
    try std.testing.expectEqualSlices(u8, plain[200_003..][0..131072], try r.peek(131072));
    // Five bytes unread: with 32 KiB of history kept before them, 131077 bytes fit and 163840 do not.
    var at: usize = 200_003 + r.bufferedLen() - 5;
    r.toss(r.bufferedLen() - 5);
    try std.testing.expectEqualSlices(u8, plain[at..][0..131077], try r.peek(131077));
    at += r.bufferedLen() - 5;
    r.toss(r.bufferedLen() - 5);
    try std.testing.expectEqualSlices(u8, plain[at..][0..5], r.buffered());
    try std.testing.expectError(error.ReadFailed, r.peek(163840));
    try std.testing.expectEqual(@as(?zipir.gzip.DecompressError, error.PeekTooLarge), decoder.err);
}

test "[edge] - [reader]: a line longer than the buffer is StreamTooLong" {
    const allocator = std.testing.allocator;
    const plain = try allocator.alloc(u8, 300_000);
    defer allocator.free(plain);
    @memset(plain, 'x');
    const stream = try compress(allocator, .gzip, plain);
    defer allocator.free(stream);
    const decoder = try allocator.create(zipir.Decompressor(.gzip));
    defer allocator.destroy(decoder);
    var input = std.Io.Reader.fixed(stream);
    decoder.init(&input, .{});
    try std.testing.expectError(error.StreamTooLong, decoder.reader.takeDelimiterInclusive('\n'));
}

test "[failure] - [reader]: bytes before a fault are delivered, then the fault, which stays" {
    const allocator = std.testing.allocator;
    const plain = try makePlain(allocator);
    defer allocator.free(plain);
    const one = try compress(allocator, .gzip, plain[0..300_000]);
    defer allocator.free(one);
    const two = try compress(allocator, .gzip, plain[300_000..]);
    defer allocator.free(two);
    const joined = try std.mem.concat(allocator, u8, &.{ one, two });
    defer allocator.free(joined);
    const decoder = try allocator.create(zipir.Decompressor(.gzip));
    defer allocator.destroy(decoder);
    var sink: std.Io.Writer.Allocating = .init(allocator);
    defer sink.deinit();
    // A wrong CRC in the second member: every byte arrives, then CrcMismatch.
    joined[joined.len - 8] ^= 1;
    var input = std.Io.Reader.fixed(joined);
    decoder.init(&input, .{});
    try std.testing.expectError(error.ReadFailed, decoder.reader.streamRemaining(&sink.writer));
    try std.testing.expectEqual(@as(?zipir.gzip.DecompressError, error.CrcMismatch), decoder.err);
    try std.testing.expectEqualSlices(u8, plain, sink.written());
    try std.testing.expectError(error.ReadFailed, decoder.reader.peekGreedy(1));
    // Cut inside the second member: the first member and part of the second arrive, then Truncated.
    sink.clearRetainingCapacity();
    input = std.Io.Reader.fixed(joined[0 .. one.len + two.len / 2]);
    decoder.init(&input, .{});
    try std.testing.expectError(error.ReadFailed, decoder.reader.streamRemaining(&sink.writer));
    try std.testing.expectEqual(@as(?zipir.gzip.DecompressError, error.Truncated), decoder.err);
    try std.testing.expect(sink.written().len >= 300_000);
    try std.testing.expectEqualSlices(u8, plain[0..sink.written().len], sink.written());
}

test "[integration] - [reader]: a workspace restarts after an end, an error, and an abandoned stream" {
    const allocator = std.testing.allocator;
    const plain = try makePlain(allocator);
    defer allocator.free(plain);
    inline for (FORMATS) |format| {
        const stream = try compress(allocator, format, plain);
        defer allocator.free(stream);
        const decoder = try allocator.create(zipir.Decompressor(format));
        defer allocator.destroy(decoder);
        var input = std.Io.Reader.fixed(stream[0..100]);
        decoder.init(&input, .{});
        try std.testing.expectError(error.ReadFailed, decoder.reader.discardRemaining());
        input = std.Io.Reader.fixed(stream);
        decoder.init(&input, .{});
        try decoder.reader.discardAll(250_000);
        for (0..2) |_| {
            input = std.Io.Reader.fixed(stream);
            decoder.init(&input, .{});
            try readAll(&decoder.reader, .borrow, plain);
        }
    }
}

test "[edge] - [reader]: the input stands after the stream when trailing data is left" {
    const allocator = std.testing.allocator;
    const plain = "trailing data is kept\n";
    inline for (FORMATS) |format| {
        const stream = try compress(allocator, format, plain);
        defer allocator.free(stream);
        const joined = try std.mem.concat(allocator, u8, &.{ stream, "XYZ" });
        defer allocator.free(joined);
        const decoder = try allocator.create(zipir.Decompressor(format));
        defer allocator.destroy(decoder);
        var input = std.Io.Reader.fixed(joined);
        decoder.init(&input, .{ .trailing_data = .leave });
        try readAll(&decoder.reader, .borrow, plain);
        try std.testing.expectEqualSlices(u8, "XYZ", input.buffered());
        input = std.Io.Reader.fixed(joined);
        decoder.init(&input, .{});
        var discard: std.Io.Writer.Discarding = .init(&.{});
        try std.testing.expectError(error.ReadFailed, decoder.reader.streamRemaining(&discard.writer));
        try std.testing.expect(decoder.err.? == error.TrailingData);
    }
}

test "[failure] - [reader]: max_header_bytes bounds the optional gzip header" {
    // FNAME of 99 bytes plus its NUL: 100 optional header bytes.
    var member: [10 + 100 + 13]u8 = undefined;
    @memcpy(member[0..10], &[_]u8{ 0x1f, 0x8b, 8, 8, 0, 0, 0, 0, 0, 0xff });
    @memset(member[10..109], 'n');
    member[109] = 0;
    // An empty final stored block, CRC 0, ISIZE 0.
    @memcpy(member[110..], &[_]u8{ 0x01, 0x00, 0x00, 0xff, 0xff, 0, 0, 0, 0, 0, 0, 0, 0 });
    const decoder = try std.testing.allocator.create(zipir.Decompressor(.gzip));
    defer std.testing.allocator.destroy(decoder);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var input = std.Io.Reader.fixed(&member);
    try std.testing.expectEqual(@as(u64, 0), try support.decompressAll(decoder, &input, &discard.writer, .{ .max_header_bytes = 100 }));
    input = std.Io.Reader.fixed(&member);
    try std.testing.expectError(error.HeaderTooLong, support.decompressAll(decoder, &input, &discard.writer, .{ .max_header_bytes = 99 }));
}

fn compressBgzf(allocator: std.mem.Allocator, plain: []const u8) ![]u8 {
    const writer = try allocator.create(zipir.bgzf.Compressor);
    defer allocator.destroy(writer);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var input = std.Io.Reader.fixed(plain);
    try writer.init(&out.writer, .{ .split = .lines, .preset = .fast });
    _ = try input.streamRemaining(&writer.writer);
    _ = try writer.finish();
    return out.toOwnedSlice();
}

test "[integration] - [reader]: BGZF reads in every pattern, and peeks of 64 KiB always fit" {
    const allocator = std.testing.allocator;
    const plain = try makePlain(allocator);
    defer allocator.free(plain);
    const stream = try compressBgzf(allocator, plain);
    defer allocator.free(stream);
    const decoder = try allocator.create(zipir.bgzf.Decompressor);
    defer allocator.destroy(decoder);
    const patterns = [_]Pattern{ .borrow, .{ .copy = 7 }, .{ .copy = 65536 }, .lines, .{ .skip = 333_333 }, .{ .limited = 1000 } };
    for (patterns) |pattern| {
        var input: [4096]u8 = undefined;
        var source = support.Source.init(stream, &input, 4096);
        decoder.init(&source.reader, .{ .require_eof_marker = true });
        try readAll(&decoder.reader, pattern, plain);
        try std.testing.expect(decoder.framing.eof_marker);
    }
    var input = std.Io.Reader.fixed(stream);
    decoder.init(&input, .{});
    const r = &decoder.reader;
    var at: usize = 0;
    while (at + 65536 <= plain.len) {
        try std.testing.expectEqualSlices(u8, plain[at..][0..65536], try r.peek(65536));
        const step = 65536 - 3 * (at % 1000);
        r.toss(step);
        at += step;
    }
}

test "[failure] - [reader]: a damaged BGZF block's bytes are never readable" {
    const allocator = std.testing.allocator;
    const plain = try makePlain(allocator);
    defer allocator.free(plain);
    const stream = try compressBgzf(allocator, plain);
    defer allocator.free(stream);
    // The third block's CRC-32: blocks are found with the scanner.
    var fixed = std.Io.Reader.fixed(stream);
    var scanner = zipir.bgzf.scan(&fixed, .{});
    var third: zipir.bgzf.Block = undefined;
    var before: u64 = 0;
    for (0..3) |k| {
        third = (try scanner.next()).?;
        if (k < 2) before += third.data_size;
    }
    stream[@intCast(third.coffset + third.size - 8)] ^= 1;
    const decoder = try allocator.create(zipir.bgzf.Decompressor);
    defer allocator.destroy(decoder);
    var input = std.Io.Reader.fixed(stream);
    decoder.init(&input, .{});
    var sink: std.Io.Writer.Allocating = .init(allocator);
    defer sink.deinit();
    try std.testing.expectError(error.ReadFailed, decoder.reader.streamRemaining(&sink.writer));
    try std.testing.expect(decoder.err.? == error.CrcMismatch);
    try std.testing.expectEqualSlices(u8, plain[0..@intCast(before)], sink.written());
}
