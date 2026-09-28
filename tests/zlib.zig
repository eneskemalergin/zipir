//! Public zlib contracts. The zlib fixtures rewrap only the first gzip member of their source files.

const std = @import("std");
const support = @import("support.zig");
const zipir = @import("zipir");
const zlib = zipir.zlib;
const Compressor = zipir.Compressor(.zlib);

const COPY_GZIP = @embedFile("data/synthetic/copy-boundaries.gz");
const COPY_PLAIN = @embedFile("data/synthetic/copy-boundaries.plain");
const COPY_MEMBER = COPY_GZIP[0 .. COPY_GZIP.len / 2];
const COPY_MEMBER_PLAIN = COPY_PLAIN[0 .. COPY_PLAIN.len / 2];
const STORED_GZIP = @embedFile("data/synthetic/final-stored-concat.gz");
const STORED_PLAIN = @embedFile("data/synthetic/final-stored-concat.plain");
const STORED_MEMBER = STORED_GZIP[0 .. STORED_GZIP.len - @embedFile("data/synthetic/short6.gz").len];
const STORED_MEMBER_PLAIN = STORED_PLAIN[0 .. STORED_PLAIN.len - @embedFile("data/synthetic/short.plain").len];

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
    options: zlib.DecompressOptions,
) !void {
    var source = support.Source.init(input_bytes, input_buffer, chunk);
    var scratch: [13]u8 = undefined;
    var sink = support.Sink{ .output = &scratch, .sink = output_buffer, .max_drain = 7 };
    const produced = try support.decompressAll(decoder, &source.reader, &sink.writer, options);
    try std.testing.expectEqual(@as(u64, expected.len), produced);
    try std.testing.expectEqual(expected.len, sink.count);
    try std.testing.expectEqualSlices(u8, expected, output_buffer[0..sink.count]);
}

test "[integration] - [zlib decompressor]: valid streams decode through short input and output I/O" {
    const cases = .{
        .{ @embedFile("data/synthetic/empty-single.gz"), "" },
        .{ @embedFile("data/synthetic/short6.gz"), @embedFile("data/synthetic/short.plain") },
        .{ @embedFile("data/synthetic/fixed-codes.gz"), @embedFile("data/synthetic/fixed-codes.plain") },
        .{ @embedFile("data/synthetic/long-codes.gz"), @embedFile("data/synthetic/long-codes.plain") },
        .{ STORED_MEMBER, STORED_MEMBER_PLAIN },
        .{ COPY_MEMBER, COPY_MEMBER_PLAIN },
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

test "[failure] - [zlib decompressor]: malformed wrapper, payload, trailer, and truncation fail" {
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
        try std.testing.expectError(case[1], support.decompressAll(decoder, &source.reader, &sink.writer, .{}));
    }
}

test "[failure] - [zlib decompressor]: invalid history, trees, and fixed symbols fail" {
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
            try std.testing.expectError(case[1], support.decompressAll(decoder, &source.reader, &sink.writer, .{}));
        }
    }
}

test "[failure] - [zlib decompressor]: I/O errors propagate and the workspace decodes again" {
    const stream = try wrapGzip(std.testing.allocator, STORED_MEMBER, STORED_MEMBER_PLAIN);
    defer std.testing.allocator.free(stream);
    const decoder = try std.testing.allocator.create(zlib.Decompressor);
    defer std.testing.allocator.destroy(decoder);
    var input_buffer: [17]u8 = undefined;
    var output: [4096]u8 = undefined;
    for ([_]usize{ 0, 1, 2, 20, stream.len - 3 }) |offset| {
        var source = support.Source.init(stream, &input_buffer, 3);
        source.fail_at = offset;
        var sink: support.Sink = .{ .output = &output };
        try std.testing.expectError(error.ReadFailed, support.decompressAll(decoder, &source.reader, &sink.writer, .{}));
    }
    for ([_]usize{ 0, 4096, 131072 }) |offset| {
        var source = support.Source.init(stream, &input_buffer, 17);
        var sink: support.Sink = .{ .output = &output, .fail_at = offset };
        try std.testing.expectError(error.WriteFailed, support.decompressAll(decoder, &source.reader, &sink.writer, .{}));
    }
    var source = support.Source.init(stream, &input_buffer, 17);
    var sink: support.Sink = .{ .output = &output };
    try std.testing.expectEqual(@as(u64, STORED_MEMBER_PLAIN.len), try support.decompressAll(decoder, &source.reader, &sink.writer, .{}));
}

test "[property] - [zlib decompressor]: splits pass while truncations and bit flips stay bounded" {
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
        try std.testing.expectEqual(@as(u64, 1), try support.decompressAll(decoder, &source.reader, &sink.writer, .{}));
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
            try std.testing.expectError(error.Truncated, support.decompressAll(decoder, &source.reader, &sink.writer, .{}));
        }
        for (0..256) |_| {
            @memcpy(mutated, stream);
            const position = random.random().uintLessThan(usize, stream.len);
            mutated[position] ^= @as(u8, 1) << random.random().int(u3);
            var reader = std.Io.Reader.fixed(mutated);
            var sink: std.Io.Writer.Discarding = .init(&.{});
            _ = support.decompressAll(decoder, &reader, &sink.writer, .{ .max_output_bytes = 262144 }) catch {};
            try std.testing.expect(sink.fullCount() <= 262144);
        }
    }
}

test "[edge] - [zlib decompressor]: strict and leaving trailing bytes preserve the reader contract" {
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
    try std.testing.expectError(error.TrailingData, support.decompressAll(decoder, &source.reader, &sink.writer, .{}));

    source = support.Source.init(input, &input_buffer, 1);
    sink = .{ .output = &scratch, .sink = output, .max_drain = 7 };
    try std.testing.expectEqual(expected.len, try support.decompressAll(decoder, &source.reader, &sink.writer, .{ .trailing_data = .leave }));
    try std.testing.expectEqualSlices(u8, "tail", try source.reader.take(4));

    const concatenated = try std.testing.allocator.alloc(u8, stream.len * 2);
    defer std.testing.allocator.free(concatenated);
    @memcpy(concatenated[0..stream.len], stream);
    @memcpy(concatenated[stream.len..], stream);
    source = support.Source.init(concatenated, &input_buffer, 1);
    sink = .{ .output = &scratch, .sink = output, .max_drain = 7 };
    try std.testing.expectError(error.TrailingData, support.decompressAll(decoder, &source.reader, &sink.writer, .{}));

    source = support.Source.init(concatenated, &input_buffer, 1);
    sink = .{ .output = &scratch, .sink = output, .max_drain = 7 };
    try std.testing.expectEqual(expected.len, try support.decompressAll(decoder, &source.reader, &sink.writer, .{ .trailing_data = .leave }));
    for (stream) |byte| try std.testing.expectEqual(byte, try source.reader.takeByte());
}

test "[failure] - [zlib decompressor]: output limits cover matches, stored blocks, and staging edges" {
    const cases = .{
        .{ @embedFile("data/synthetic/short6.gz"), @embedFile("data/synthetic/short.plain") },
        .{ STORED_MEMBER, STORED_MEMBER_PLAIN },
        .{ COPY_MEMBER, COPY_MEMBER_PLAIN },
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
                try std.testing.expectError(error.OutputLimitExceeded, support.decompressAll(decoder, &reader, &sink.writer, .{ .max_output_bytes = limit }));
                try std.testing.expect(sink.fullCount() <= limit);
            } else {
                try std.testing.expectEqual(size, try support.decompressAll(decoder, &reader, &sink.writer, .{ .max_output_bytes = limit }));
                try std.testing.expectEqual(size, sink.fullCount());
            }
        }
    }
}

test "[failure] - [zlib decompressor]: rejects undersized input buffers and preset dictionaries" {
    const stream = @embedFile("data/synthetic/short6.gz");
    const expected = @embedFile("data/synthetic/short.plain");
    const valid = try wrapGzip(std.testing.allocator, stream, expected);
    defer std.testing.allocator.free(valid);
    const decoder = try std.testing.allocator.create(zlib.Decompressor);
    defer std.testing.allocator.destroy(decoder);
    var input_buffer: [15]u8 = undefined;
    var source = support.Source.init(valid, &input_buffer, 1);
    var sink = std.Io.Writer.Discarding.init(&.{});
    try std.testing.expectError(error.InputBufferTooSmall, support.decompressAll(decoder, &source.reader, &sink.writer, .{}));

    const dictionary_header = [_]u8{ 0x78, 0x20, 0, 0, 0, 1 };
    var dictionary_buffer: [17]u8 = undefined;
    source = support.Source.init(&dictionary_header, &dictionary_buffer, 1);
    try std.testing.expectError(error.DictionaryUnsupported, support.decompressAll(decoder, &source.reader, &sink.writer, .{}));
}

fn encodeRoundtrip(encoder: *Compressor, plain: []const u8, options: zlib.CompressOptions, chunk: usize, capacity: usize, encoded: []u8) ![]const u8 {
    const stream = try support.encodeRoundtrip(zlib, encoder, .zlib, plain, options, chunk, capacity, encoded);
    try std.testing.expectEqual(@as(u16, 0), (@as(u16, stream[0]) << 8 | stream[1]) % 31);
    var adler: std.hash.Adler32 = .{};
    adler.update(plain);
    try std.testing.expectEqual(adler.adler, std.mem.readInt(u32, stream[stream.len - 4 ..][0..4], .big));
    return stream;
}

test "[edge] - [zlib compressor]: empty input writes the preset's header, an empty final block, and Adler-32 one" {
    const encoder = try std.testing.allocator.create(Compressor);
    defer std.testing.allocator.destroy(encoder);
    const cases = .{
        .{ zlib.CompressOptions{ .preset = .fast }, "\x78\x01\x03\x00\x00\x00\x00\x01" },
        .{ zlib.CompressOptions{}, "\x78\x5e\x03\x00\x00\x00\x00\x01" },
        .{ zlib.CompressOptions{ .preset = .dense }, "\x78\xda\x03\x00\x00\x00\x00\x01" },
    };
    inline for (cases) |case| {
        var bytes: [case[1].len]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        var reader = std.Io.Reader.fixed("");
        try std.testing.expectEqual(@as(u64, 0), try support.compressAll(encoder, &reader, &writer, case[0]));
        try std.testing.expectEqualSlices(u8, case[1], writer.buffered());
    }
}

test "[property] - [zlib compressor]: payload equals the gzip payload across block and window boundaries" {
    const encoder = try std.testing.allocator.create(Compressor);
    defer std.testing.allocator.destroy(encoder);
    const gzip_encoder = try std.testing.allocator.create(zipir.Compressor(.gzip));
    defer std.testing.allocator.destroy(gzip_encoder);
    const decoder = try std.testing.allocator.create(zlib.Decompressor);
    defer std.testing.allocator.destroy(decoder);
    var plain: [131073]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(1313);
    for (&plain) |*b| b.* = 'a' + rng.random().uintLessThan(u8, 4);
    rng.random().bytes(plain[65536..98304]);
    const encoded = try std.testing.allocator.alloc(u8, plain.len + 64);
    defer std.testing.allocator.free(encoded);
    var gzip_bytes: [131073 + 64]u8 = undefined;
    var input_buffer: [17]u8 = undefined;
    for ([_]zlib.CompressOptions{ .{ .preset = .fast }, .{}, .{ .preset = .dense } }) |options| {
        for ([_]usize{ 1, 257, 32767, 32768, 32769, 65537, 131073 }) |n| {
            const stream = try encodeRoundtrip(encoder, plain[0..n], options, 997, 17, encoded);
            var reader = std.Io.Reader.fixed(plain[0..n]);
            var writer = std.Io.Writer.fixed(&gzip_bytes);
            _ = try support.compressAll(gzip_encoder, &reader, &writer, options);
            const member = writer.buffered();
            try std.testing.expectEqualSlices(u8, member[10 .. member.len - 8], stream[2 .. stream.len - 4]);
            const output = try std.testing.allocator.alloc(u8, n);
            defer std.testing.allocator.free(output);
            try decode(decoder, stream, plain[0..n], &input_buffer, output, 257, .{});
        }
        for ([_]usize{ 0, 1 }) |capacity| _ = try encodeRoundtrip(encoder, plain[0..65537], options, 997, capacity, encoded);
    }
}

test "[failure] - [zlib compressor]: I/O errors propagate and the workspace compresses again" {
    const encoder = try std.testing.allocator.create(Compressor);
    defer std.testing.allocator.destroy(encoder);
    var plain: [65537]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(145);
    rng.random().bytes(&plain);
    var encoded: [128]u8 = undefined;
    for ([_]usize{ 0, 1, 32768, 65536 }) |fail| {
        var buffer: [17]u8 = undefined;
        var source = support.Source.init(&plain, &buffer, 200);
        source.fail_at = fail;
        var scratch: [29]u8 = undefined;
        var sink = support.Sink{ .output = &scratch };
        try std.testing.expectError(error.ReadFailed, support.compressAll(encoder, &source.reader, &sink.writer, .{ .preset = .dense }));
        _ = try encodeRoundtrip(encoder, "reused after read failure", .{ .preset = .dense }, 1, 17, &encoded);
    }
    for ([_]usize{ 0, 1, 2, 500, 65543 }) |fail| {
        var source = std.Io.Reader.fixed(&plain);
        var scratch: [29]u8 = undefined;
        var sink = support.Sink{ .output = &scratch, .fail_at = fail };
        try std.testing.expectError(error.WriteFailed, support.compressAll(encoder, &source, &sink.writer, .{ .preset = .fast }));
        _ = try encodeRoundtrip(encoder, "reused after write failure", .{ .preset = .fast }, 1, 17, &encoded);
    }
}

test "[unit] - [zlib]: the public error set names exactly the documented errors" {
    const expected = [_][]const u8{ "BadAdler", "BadBlock", "BadDistance", "BadHeader", "BadHuffman", "BadStored", "BadSymbol", "DictionaryUnsupported", "InputBufferTooSmall", "OutputLimitExceeded", "PeekTooLarge", "ReadFailed", "TrailingData", "Truncated", "UnsupportedMethod", "WindowTooLarge" };
    try support.expectErrorNames(zlib.DecompressError, &expected);
}
