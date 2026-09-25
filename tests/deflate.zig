//! Public raw DEFLATE contracts: no wrapper, no checksum, engine errors only.

const std = @import("std");
const support = @import("support.zig");
const zipir = @import("zipir");
const deflate = zipir.deflate;

const Compressor = zipir.Compressor(.deflate);
const Decompressor = zipir.Decompressor(.deflate);

fn decode(decoder: *Decompressor, stream: []const u8, expected: []const u8, chunk: usize, options: deflate.Options) !void {
    var input_buffer: [17]u8 = undefined;
    var source = support.Source.init(stream, &input_buffer, chunk);
    var oracle = std.Io.Reader.fixed(expected);
    var scratch: [13]u8 = undefined;
    var sink = support.Sink{ .output = &scratch, .oracle = &oracle, .max_drain = 7 };
    try std.testing.expectEqual(@as(u64, expected.len), try decoder.decompress(&source.reader, &sink.writer, options));
    try std.testing.expect(!sink.mismatch);
    try std.testing.expectEqual(expected.len, sink.count);
}

test "[edge] - [raw deflate]: empty input is one empty final fixed block at every level" {
    const encoder = try std.testing.allocator.create(Compressor);
    defer std.testing.allocator.destroy(encoder);
    const decoder = try std.testing.allocator.create(Decompressor);
    defer std.testing.allocator.destroy(decoder);
    for ([_]deflate.CompressOptions{ .{ .level = .fast }, .{}, .{ .level = .dense } }) |options| {
        var bytes: [2]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        var reader = std.Io.Reader.fixed("");
        try std.testing.expectEqual(@as(u64, 0), try encoder.compress(&reader, &writer, options));
        try std.testing.expectEqualSlices(u8, "\x03\x00", writer.buffered());
    }
    try decode(decoder, "\x03\x00", "", 1, .{});
}

test "[property] - [raw deflate]: output equals the gzip payload and decodes with std and zipir through short I/O" {
    const encoder = try std.testing.allocator.create(Compressor);
    defer std.testing.allocator.destroy(encoder);
    const gzip_encoder = try std.testing.allocator.create(zipir.Compressor(.gzip));
    defer std.testing.allocator.destroy(gzip_encoder);
    const decoder = try std.testing.allocator.create(Decompressor);
    defer std.testing.allocator.destroy(decoder);
    // A four-letter alphabet gives long hash chains; the random middle forces stored blocks.
    var plain: [131073]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(1414);
    for (&plain) |*b| b.* = 'a' + rng.random().uintLessThan(u8, 4);
    rng.random().bytes(plain[65536..98304]);
    const raw = try std.testing.allocator.alloc(u8, plain.len + 64);
    defer std.testing.allocator.free(raw);
    const member = try std.testing.allocator.alloc(u8, plain.len + 64);
    defer std.testing.allocator.free(member);
    for ([_]deflate.CompressOptions{ .{ .level = .fast }, .{}, .{ .level = .dense } }) |options| {
        for ([_]usize{ 1, 257, 32768, 32769, 65537, 131073 }) |n| {
            const stream = try support.encodeRoundtrip(deflate, encoder, .raw, plain[0..n], options, 997, 17, raw);
            var reader = std.Io.Reader.fixed(plain[0..n]);
            var gzip_writer = std.Io.Writer.fixed(member);
            _ = try gzip_encoder.compress(&reader, &gzip_writer, options);
            try std.testing.expectEqualSlices(u8, gzip_writer.buffered()[10 .. gzip_writer.buffered().len - 8], stream);
            try decode(decoder, stream, plain[0..n], 257, .{});
        }
    }
}

test "[integration] - [raw deflate decoder]: streams from std's compressor decode through short I/O" {
    const decoder = try std.testing.allocator.create(Decompressor);
    defer std.testing.allocator.destroy(decoder);
    var plain: [70001]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(1415);
    for (&plain) |*b| b.* = "ACGTN\n"[rng.random().uintLessThan(u8, 6)];
    const compressor = try std.testing.allocator.create(std.compress.flate.Compress);
    defer std.testing.allocator.destroy(compressor);
    const window = try std.testing.allocator.alloc(u8, std.compress.flate.max_window_len);
    defer std.testing.allocator.free(window);
    const stream = try std.testing.allocator.alloc(u8, plain.len + 1024);
    defer std.testing.allocator.free(stream);
    for ([_]std.compress.flate.Compress.Options{ .level_1, .level_6, .level_9 }) |options| {
        var writer = std.Io.Writer.fixed(stream);
        compressor.* = try .init(&writer, window, .raw, options);
        try compressor.writer.writeAll(&plain);
        try compressor.finish();
        for ([_]usize{ 1, 17, 4099 }) |chunk| try decode(decoder, writer.buffered(), &plain, chunk, .{});
    }
}

test "[edge] - [raw deflate decoder]: bytes after the final block are rejected or left unread" {
    const decoder = try std.testing.allocator.create(Decompressor);
    defer std.testing.allocator.destroy(decoder);
    const stream = "\x03\x00" ++ "bytes after the stream";
    var buffer: [17]u8 = undefined;
    var source = support.Source.init(stream, &buffer, 1);
    var scratch: [1]u8 = undefined;
    var sink = support.Sink{ .output = &scratch };
    try std.testing.expectError(error.TrailingData, decoder.decompress(&source.reader, &sink.writer, .{}));
    var reader = std.Io.Reader.fixed(stream);
    try std.testing.expectEqual(@as(u64, 0), try decoder.decompress(&reader, &sink.writer, .{ .trailing_data = .leave }));
    try std.testing.expectEqualStrings("bytes after the stream", try reader.take(stream.len - 2));
}

test "[failure] - [raw deflate decoder]: every prefix is truncated, and limits and small buffers give documented errors" {
    const decoder = try std.testing.allocator.create(Decompressor);
    defer std.testing.allocator.destroy(decoder);
    const encoder = try std.testing.allocator.create(Compressor);
    defer std.testing.allocator.destroy(encoder);
    var plain: [5000]u8 = undefined;
    for (&plain, 0..) |*b, i| b.* = @truncate(i * 7 / 3);
    var raw: [6000]u8 = undefined;
    var writer = std.Io.Writer.fixed(&raw);
    var reader = std.Io.Reader.fixed(&plain);
    _ = try encoder.compress(&reader, &writer, .{});
    const stream = writer.buffered();
    var scratch: [64]u8 = undefined;
    var buffer: [17]u8 = undefined;
    for (0..stream.len) |n| {
        var source = support.Source.init(stream[0..n], &buffer, 5);
        var sink = support.Sink{ .output = &scratch };
        try std.testing.expectError(error.Truncated, decoder.decompress(&source.reader, &sink.writer, .{}));
    }
    var source = support.Source.init(stream, &buffer, 5);
    var sink = support.Sink{ .output = &scratch };
    try std.testing.expectError(error.OutputLimitExceeded, decoder.decompress(&source.reader, &sink.writer, .{ .max_output_bytes = plain.len - 1 }));
    var small: [15]u8 = undefined;
    source = support.Source.init(stream, &small, 5);
    try std.testing.expectError(error.InputBufferTooSmall, decoder.decompress(&source.reader, &sink.writer, .{}));
    try decode(decoder, stream, &plain, 5, .{ .max_output_bytes = plain.len });
}

test "[property] - [raw deflate decoder]: bounded bit flips end in success or a documented error within the limit" {
    const decoder = try std.testing.allocator.create(Decompressor);
    defer std.testing.allocator.destroy(decoder);
    const seed = @embedFile("data/synthetic/copy-boundaries.gz");
    const stream = seed[10 .. seed.len / 2 - 8];
    const mutated = try std.testing.allocator.dupe(u8, stream);
    defer std.testing.allocator.free(mutated);
    var rng = std.Random.DefaultPrng.init(91240);
    var scratch: [64]u8 = undefined;
    var buffer: [17]u8 = undefined;
    for (0..2000) |_| {
        @memcpy(mutated, stream);
        mutated[rng.random().uintLessThan(usize, mutated.len)] ^= @as(u8, 1) << rng.random().int(u3);
        var source = support.Source.init(mutated, &buffer, 7);
        var sink = support.Sink{ .output = &scratch };
        const limit = 1 << 20;
        if (decoder.decompress(&source.reader, &sink.writer, .{ .max_output_bytes = limit })) |n| {
            try std.testing.expect(n <= limit);
        } else |err| switch (err) {
            error.Truncated, error.BadHuffman, error.BadSymbol, error.BadDistance, error.BadStored, error.BadBlock, error.OutputLimitExceeded, error.TrailingData => {},
            else => return err,
        }
    }
}

test "[unit] - [raw deflate]: the public error set names exactly the documented errors" {
    const expected = [_][]const u8{ "BadBlock", "BadDistance", "BadHuffman", "BadStored", "BadSymbol", "InputBufferTooSmall", "OutputLimitExceeded", "ReadFailed", "TrailingData", "Truncated", "WriteFailed" };
    try support.expectErrorNames(deflate.Error, &expected);
}
