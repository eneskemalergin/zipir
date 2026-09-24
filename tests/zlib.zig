//! Public zlib decompression contracts.

const std = @import("std");
const support = @import("support.zig");
const zlib = @import("zipir").zlib;

// Only the first gzip member is rewrapped: copy-boundaries repeats one member and
// final-stored-concat ends with the short6 member.
const copy_gzip = @embedFile("data/synthetic/copy-boundaries.gz");
const copy_plain = @embedFile("data/synthetic/copy-boundaries.plain");
const copy_member = copy_gzip[0 .. copy_gzip.len / 2];
const copy_member_plain = copy_plain[0 .. copy_plain.len / 2];
const stored_gzip = @embedFile("data/synthetic/final-stored-concat.gz");
const stored_plain = @embedFile("data/synthetic/final-stored-concat.plain");
const stored_member = stored_gzip[0 .. stored_gzip.len - @embedFile("data/synthetic/short6.gz").len];
const stored_member_plain = stored_plain[0 .. stored_plain.len - @embedFile("data/synthetic/short.plain").len];

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
        .{ stored_member, stored_member_plain },
        .{ copy_member, copy_member_plain },
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
    var bad_window = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(bad_window);
    bad_window[0] = 0x88;
    const bad_stored = [_]u8{ 0x78, 0x9c, 0x01, 0, 0, 0, 0, 0, 0, 0, 1 };
    const bad_block = [_]u8{ 0x78, 0x9c, 0x07 };
    const dictionary_header = [_]u8{ 0x78, 0x20, 0, 0, 0, 1 };
    const cases = .{
        .{ "", error.Truncated },
        .{ valid[0..1], error.Truncated },
        .{ truncated, error.Truncated },
        .{ bad_method[0..], error.UnsupportedMethod },
        .{ bad_window[0..], error.WindowTooLarge },
        .{ bad_check[0..], error.BadHeader },
        .{ bad_stored[0..], error.BadStored },
        .{ bad_block[0..], error.BadBlock },
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

test "[failure] - [zlib decoder]: invalid history, trees, and fixed symbols fail" {
    const cases = .{
        .{ "invalid-history", error.BadDistance },
        .{ "incomplete-literal", error.BadHuffman },
        .{ "incomplete-distance", error.BadHuffman },
        .{ "incomplete-code-length", error.BadHuffman },
        .{ "oversubscribed-literal", error.BadHuffman },
        .{ "fixed-invalid-286", error.BadSymbol },
        .{ "fixed-invalid-287", error.BadSymbol },
        .{ "fixed-invalid-30", error.BadSymbol },
        .{ "fixed-invalid-31", error.BadSymbol },
    };
    const decoder = try std.testing.allocator.create(zlib.Decompressor);
    defer std.testing.allocator.destroy(decoder);
    var input_buffer: [17]u8 = undefined;
    inline for (cases) |case| {
        const stream = try wrapGzip(std.testing.allocator, @embedFile("data/synthetic/" ++ case[0] ++ ".gz"), "");
        defer std.testing.allocator.free(stream);
        for ([_]usize{ 1, 17 }) |chunk| {
            var source = support.Source.init(stream, &input_buffer, chunk);
            var sink: std.Io.Writer.Discarding = .init(&.{});
            try std.testing.expectError(case[1], decoder.decompress(&source.reader, &sink.writer, .{}));
        }
    }
}

test "[failure] - [zlib decoder]: I/O errors propagate and the workspace decodes again" {
    const stream = try wrapGzip(std.testing.allocator, stored_member, stored_member_plain);
    defer std.testing.allocator.free(stream);
    const decoder = try std.testing.allocator.create(zlib.Decompressor);
    defer std.testing.allocator.destroy(decoder);
    var input_buffer: [17]u8 = undefined;
    var output: [4096]u8 = undefined;
    for ([_]usize{ 0, 1, 2, 20, stream.len - 3 }) |offset| {
        var source = support.Source.init(stream, &input_buffer, 3);
        source.fail_at = offset;
        var sink: support.Sink = .{ .output = &output };
        try std.testing.expectError(error.ReadFailed, decoder.decompress(&source.reader, &sink.writer, .{}));
    }
    for ([_]usize{ 0, 4096, 131072 }) |offset| {
        var source = support.Source.init(stream, &input_buffer, 17);
        var sink: support.Sink = .{ .output = &output, .fail_at = offset };
        try std.testing.expectError(error.WriteFailed, decoder.decompress(&source.reader, &sink.writer, .{}));
    }
    var source = support.Source.init(stream, &input_buffer, 17);
    var sink: support.Sink = .{ .output = &output };
    try std.testing.expectEqual(@as(u64, stored_member_plain.len), try decoder.decompress(&source.reader, &sink.writer, .{}));
}

test "[property] - [zlib decoder]: splits pass while truncations and bit flips stay bounded" {
    const decoder = try std.testing.allocator.create(zlib.Decompressor);
    defer std.testing.allocator.destroy(decoder);
    const small = try wrapGzip(std.testing.allocator, @embedFile("data/synthetic/repeat-zero.gz"), "A");
    defer std.testing.allocator.free(small);
    var input_buffer: [16]u8 = undefined;
    var one: [1]u8 = undefined;
    for (0..small.len + 1) |split| {
        var source = support.Source.init(small, &input_buffer, 65536);
        source.split_at = split;
        var sink: support.Sink = .{ .output = &one };
        try std.testing.expectEqual(@as(u64, 1), try decoder.decompress(&source.reader, &sink.writer, .{}));
        try std.testing.expectEqual(@as(u8, 'A'), one[0]);
    }

    var random = std.Random.DefaultPrng.init(0x2179);
    const seeds = .{
        .{ @embedFile("data/synthetic/repeat-zero.gz"), "A" },
        .{ @embedFile("data/synthetic/short6.gz"), @embedFile("data/synthetic/short.plain") },
        .{ @embedFile("data/synthetic/long-codes.gz"), @embedFile("data/synthetic/long-codes.plain") },
    };
    inline for (seeds) |seed| {
        const stream = try wrapGzip(std.testing.allocator, seed[0], seed[1]);
        defer std.testing.allocator.free(stream);
        const mutated = try std.testing.allocator.dupe(u8, stream);
        defer std.testing.allocator.free(mutated);
        const first_cut = if (stream.len > 64) stream.len - 32 else 0;
        for (first_cut..stream.len) |cut| {
            var source = support.Source.init(stream[0..cut], &input_buffer, 3);
            var sink: std.Io.Writer.Discarding = .init(&.{});
            try std.testing.expectError(error.Truncated, decoder.decompress(&source.reader, &sink.writer, .{}));
        }
        for (0..256) |_| {
            @memcpy(mutated, stream);
            const position = random.random().uintLessThan(usize, stream.len);
            mutated[position] ^= @as(u8, 1) << random.random().int(u3);
            var reader = std.Io.Reader.fixed(mutated);
            var sink: std.Io.Writer.Discarding = .init(&.{});
            _ = decoder.decompress(&reader, &sink.writer, .{ .max_output_bytes = 262144 }) catch {};
            try std.testing.expect(sink.fullCount() <= 262144);
        }
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

test "[failure] - [zlib decoder]: output limits cover matches, stored blocks, and staging edges" {
    const cases = .{
        .{ @embedFile("data/synthetic/short6.gz"), @embedFile("data/synthetic/short.plain") },
        .{ stored_member, stored_member_plain },
        .{ copy_member, copy_member_plain },
    };
    const decoder = try std.testing.allocator.create(zlib.Decompressor);
    defer std.testing.allocator.destroy(decoder);
    inline for (cases) |case| {
        const stream = try wrapGzip(std.testing.allocator, case[0], case[1]);
        defer std.testing.allocator.free(stream);
        const size: u64 = case[1].len;
        for ([_]u64{ 0, 1, 257, 32768, 131071, 131072, 131073, size - 1, size, size + 1 }) |limit| {
            var reader = std.Io.Reader.fixed(stream);
            var sink: std.Io.Writer.Discarding = .init(&.{});
            if (limit < size) {
                try std.testing.expectError(error.OutputLimitExceeded, decoder.decompress(&reader, &sink.writer, .{ .max_output_bytes = limit }));
                try std.testing.expect(sink.fullCount() <= limit);
            } else {
                try std.testing.expectEqual(size, try decoder.decompress(&reader, &sink.writer, .{ .max_output_bytes = limit }));
                try std.testing.expectEqual(size, sink.fullCount());
            }
        }
    }
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
