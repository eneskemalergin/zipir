//! Public zlib decompression contracts.

const std = @import("std");
const support = @import("support.zig");
const zlib = @import("z_flate").zlib;

fn wrapGzip(
    allocator: std.mem.Allocator,
    gzip_bytes: []const u8,
    plain: []const u8,
) ![]u8 {
    if (gzip_bytes.len < 18 or gzip_bytes[0] != 0x1f or gzip_bytes[1] != 0x8b or
        gzip_bytes[3] != 0)
    {
        return error.InvalidFixture;
    }
    const raw = gzip_bytes[10 .. gzip_bytes.len - 8];
    const result = try allocator.alloc(u8, 2 + raw.len + 4);
    errdefer allocator.free(result);
    result[0] = 0x78;
    result[1] = 0x9c;
    @memcpy(result[2..][0..raw.len], raw);
    var adler: std.hash.Adler32 = .{};
    adler.update(plain);
    std.mem.writeInt(u32, result[2 + raw.len ..][0..4], adler.adler, .big);
    return result;
}

fn decode(
    decoder: *zlib.Decompressor,
    input_bytes: []const u8,
    expected: []const u8,
    input_buffer: []u8,
    output_buffer: []u8,
    chunk: usize,
    options: zlib.Options,
) !void {
    var source = support.Source.init(input_bytes, input_buffer, chunk);
    var scratch: [13]u8 = undefined;
    var sink = support.Sink{ .output = &scratch, .sink = output_buffer, .max_drain = 7 };
    const produced = try decoder.decompress(&source.reader, &sink.writer, options);
    try std.testing.expectEqual(@as(u64, expected.len), produced);
    try std.testing.expectEqual(expected.len, sink.count);
    try std.testing.expectEqualSlices(u8, expected, output_buffer[0..sink.count]);
}

test "[integration] - [zlib decoder]: valid streams decode through short input and output I/O" {
    const cases = .{
        .{ @embedFile("data/synthetic/empty-single.gz"), "" },
        .{ @embedFile("data/synthetic/short6.gz"), @embedFile("data/synthetic/short.plain") },
        .{ @embedFile("data/synthetic/fixed-codes.gz"), @embedFile("data/synthetic/fixed-codes.plain") },
        .{ @embedFile("data/synthetic/long-codes.gz"), @embedFile("data/synthetic/long-codes.plain") },
    };
    const decoder = try std.testing.allocator.create(zlib.Decompressor);
    defer std.testing.allocator.destroy(decoder);
    var input_buffer: [17]u8 = undefined;
    inline for (cases) |case| {
        const stream = try wrapGzip(std.testing.allocator, case[0], case[1]);
        defer std.testing.allocator.free(stream);
        const output = try std.testing.allocator.alloc(u8, case[1].len);
        defer std.testing.allocator.free(output);
        for ([_]usize{ 1, 3, 17, 257 }) |chunk| {
            try decode(decoder, stream, case[1], &input_buffer, output, chunk, .{});
        }
    }
}

test "[failure] - [zlib decoder]: malformed wrapper, payload, trailer, and truncation fail" {
    const gzip_bytes = @embedFile("data/synthetic/short6.gz");
    const plain = @embedFile("data/synthetic/short.plain");
    const valid = try wrapGzip(std.testing.allocator, gzip_bytes, plain);
    defer std.testing.allocator.free(valid);

    const truncated = valid[0 .. valid.len - 1];
    var bad_method = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(bad_method);
    bad_method[0] = 0x79;
    var bad_check = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(bad_check);
    bad_check[1] ^= 1;
    var bad_adler = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(bad_adler);
    bad_adler[bad_adler.len - 1] ^= 1;
    const bad_stored = [_]u8{ 0x78, 0x9c, 0x01, 0, 0, 0, 0, 0, 0, 0, 1 };
    const dictionary_header = [_]u8{ 0x78, 0x20, 0, 0, 0, 1 };
    const cases = .{
        .{ truncated, error.Truncated },
        .{ bad_method[0..], error.UnsupportedMethod },
        .{ bad_check[0..], error.BadHeader },
        .{ bad_stored[0..], error.BadStored },
        .{ bad_adler[0..], error.BadAdler },
        .{ dictionary_header[0..], error.DictionaryUnsupported },
    };
    const decoder = try std.testing.allocator.create(zlib.Decompressor);
    defer std.testing.allocator.destroy(decoder);
    var input_buffer: [17]u8 = undefined;
    var output: [131072]u8 = undefined;
    inline for (cases) |case| {
        var source = support.Source.init(case[0], &input_buffer, 3);
        var scratch: [13]u8 = undefined;
        var sink = support.Sink{ .output = &scratch, .sink = &output, .max_drain = 7 };
        try std.testing.expectError(case[1], decoder.decompress(&source.reader, &sink.writer, .{}));
    }
}

test "[edge] - [zlib decoder]: strict and leaving trailing bytes preserve the reader contract" {
    const gzip_bytes = @embedFile("data/synthetic/short6.gz");
    const expected = @embedFile("data/synthetic/short.plain");
    const stream = try wrapGzip(std.testing.allocator, gzip_bytes, expected);
    defer std.testing.allocator.free(stream);
    const input = try std.testing.allocator.alloc(u8, stream.len + 4);
    defer std.testing.allocator.free(input);
    @memcpy(input[0..stream.len], stream);
    @memcpy(input[stream.len..], "tail");

    const decoder = try std.testing.allocator.create(zlib.Decompressor);
    defer std.testing.allocator.destroy(decoder);
    var input_buffer: [17]u8 = undefined;
    var source = support.Source.init(input, &input_buffer, 1);
    const output = try std.testing.allocator.alloc(u8, expected.len);
    defer std.testing.allocator.free(output);
    var scratch: [13]u8 = undefined;
    var sink = support.Sink{ .output = &scratch, .sink = output, .max_drain = 7 };
    try std.testing.expectError(error.TrailingData, decoder.decompress(&source.reader, &sink.writer, .{}));

    source = support.Source.init(input, &input_buffer, 1);
    sink = .{ .output = &scratch, .sink = output, .max_drain = 7 };
    try std.testing.expectEqual(expected.len, try decoder.decompress(&source.reader, &sink.writer, .{ .trailing_data = .leave }));
    try std.testing.expectEqualSlices(u8, "tail", try source.reader.take(4));

    const concatenated = try std.testing.allocator.alloc(u8, stream.len * 2);
    defer std.testing.allocator.free(concatenated);
    @memcpy(concatenated[0..stream.len], stream);
    @memcpy(concatenated[stream.len..], stream);
    source = support.Source.init(concatenated, &input_buffer, 1);
    sink = .{ .output = &scratch, .sink = output, .max_drain = 7 };
    try std.testing.expectError(error.TrailingData, decoder.decompress(&source.reader, &sink.writer, .{}));

    source = support.Source.init(concatenated, &input_buffer, 1);
    sink = .{ .output = &scratch, .sink = output, .max_drain = 7 };
    try std.testing.expectEqual(expected.len, try decoder.decompress(&source.reader, &sink.writer, .{ .trailing_data = .leave }));
    for (stream) |byte| try std.testing.expectEqual(byte, try source.reader.takeByte());
}

test "[failure] - [zlib decoder]: output cap stops before exceeding the caller limit" {
    const gzip_bytes = @embedFile("data/synthetic/short6.gz");
    const expected = @embedFile("data/synthetic/short.plain");
    const stream = try wrapGzip(std.testing.allocator, gzip_bytes, expected);
    defer std.testing.allocator.free(stream);
    const decoder = try std.testing.allocator.create(zlib.Decompressor);
    defer std.testing.allocator.destroy(decoder);
    var input_buffer: [17]u8 = undefined;
    var source = support.Source.init(stream, &input_buffer, 3);
    var output: [expected.len]u8 = undefined;
    var scratch: [13]u8 = undefined;
    var sink = support.Sink{ .output = &scratch, .sink = &output, .max_drain = 7 };
    const limit: u64 = expected.len - 1;
    try std.testing.expectError(error.OutputLimitExceeded, decoder.decompress(&source.reader, &sink.writer, .{ .max_output_bytes = limit }));
    try std.testing.expect(sink.count <= limit);
}

test "[failure] - [zlib decoder]: rejects undersized input buffers and preset dictionaries" {
    const stream = @embedFile("data/synthetic/short6.gz");
    const expected = @embedFile("data/synthetic/short.plain");
    const valid = try wrapGzip(std.testing.allocator, stream, expected);
    defer std.testing.allocator.free(valid);
    const decoder = try std.testing.allocator.create(zlib.Decompressor);
    defer std.testing.allocator.destroy(decoder);
    var input_buffer: [15]u8 = undefined;
    var source = support.Source.init(valid, &input_buffer, 1);
    var sink = std.Io.Writer.Discarding.init(&.{});
    try std.testing.expectError(error.InputBufferTooSmall, decoder.decompress(&source.reader, &sink.writer, .{}));

    const dictionary_header = [_]u8{ 0x78, 0x20, 0, 0, 0, 1 };
    var dictionary_buffer: [17]u8 = undefined;
    source = support.Source.init(&dictionary_header, &dictionary_buffer, 1);
    try std.testing.expectError(error.DictionaryUnsupported, decoder.decompress(&source.reader, &sink.writer, .{}));
}
