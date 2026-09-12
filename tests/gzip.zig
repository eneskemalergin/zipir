//! Checks the public gzip streaming API at refill, output and failure boundaries.

const std = @import("std");
const z_flate = @import("z_flate");
const Decoder = z_flate.Decompressor(.gzip);
const support = @import("support.zig");

test "[integration] - [gzip]: bounded refills and partial drains preserve members and long headers" {
    const cases = .{
        .{ @embedFile("data/synthetic/short6.gz"), @embedFile("data/synthetic/short.plain") },
        .{ @embedFile("data/synthetic/long-header.gz"), @embedFile("data/synthetic/short.plain") },
        .{ @embedFile("data/synthetic/final-stored-concat.gz"), @embedFile("data/synthetic/final-stored-concat.plain") },
        .{ @embedFile("data/synthetic/long-codes.gz"), @embedFile("data/synthetic/long-codes.plain") },
        .{ @embedFile("data/synthetic/copy-boundaries.gz"), @embedFile("data/synthetic/copy-boundaries.plain") },
    };
    const work = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(work);
    var input: [32768]u8 = undefined;
    var output: [65536]u8 = undefined;
    inline for (cases) |case| {
        const got = try std.testing.allocator.alloc(u8, case[1].len);
        defer std.testing.allocator.free(got);
        for ([_][3]usize{ .{ 16, 1, 1 }, .{ 17, 3, 17 }, .{ 257, 257, 4096 }, .{ 32768, 65536, 65536 } }) |shape| {
            var source = support.Source.init(case[0], input[0..shape[0]], shape[1]);
            var sink: support.Sink = .{ .output = output[0..shape[2]], .sink = got, .max_drain = 317 };
            const n = try work.decompress(&source.reader, &sink.writer, .{});
            try std.testing.expectEqual(case[1].len, n);
            try std.testing.expectEqualSlices(u8, case[1], got);
        }
    }
}

test "[integration] - [gzip]: optional headers without FHCRC preserve refills and payload CRC" {
    const seed = @embedFile("data/synthetic/long-header.gz");
    const plain = @embedFile("data/synthetic/short.plain");
    const header_end = 10 + 2 + 65535 + 70001 + 66001;
    const compressed = try std.testing.allocator.alloc(u8, seed.len - 2);
    defer std.testing.allocator.free(compressed);
    @memcpy(compressed[0..header_end], seed[0..header_end]);
    @memcpy(compressed[header_end..], seed[header_end + 2 ..]);
    compressed[3] &= ~@as(u8, 2);
    const work = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(work);
    const got = try std.testing.allocator.alloc(u8, plain.len);
    defer std.testing.allocator.free(got);
    var input: [32768]u8 = undefined;
    var output: [4096]u8 = undefined;
    for ([_]usize{ 16, 32768 }) |size| {
        var source = support.Source.init(compressed, input[0..size], if (size == 16) 1 else size);
        var sink: support.Sink = .{ .output = &output, .sink = got };
        try std.testing.expectEqual(plain.len, try work.decompress(&source.reader, &sink.writer, .{}));
        try std.testing.expectEqualSlices(u8, plain, got);
        compressed[compressed.len - 8] ^= 1;
        source = support.Source.init(compressed, input[0..size], size);
        sink = .{ .output = &output };
        try std.testing.expectError(error.CrcMismatch, work.decompress(&source.reader, &sink.writer, .{}));
        compressed[compressed.len - 8] ^= 1;
    }
}

test "[property] - [gzip]: every small input split and truncated prefix is checked" {
    const seed = @embedFile("data/synthetic/repeat-zero.gz");
    const work = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(work);
    var input: [16]u8 = undefined;
    var output: [1]u8 = undefined;
    for (0..seed.len + 1) |split| {
        var source = support.Source.init(seed, &input, 65536);
        source.split_at = split;
        var sink: support.Sink = .{ .output = &output };
        try std.testing.expectEqual(@as(usize, 1), try work.decompress(&source.reader, &sink.writer, .{}));
        try std.testing.expectEqual(@as(u8, 'A'), output[0]);
        if (split == seed.len) continue;
        source = support.Source.init(seed[0..split], &input, 1);
        sink.count = 0;
        if (work.decompress(&source.reader, &sink.writer, .{})) |_| return error.AcceptedTruncation else |_| {}
    }
}

test "[failure] - [gzip]: corrupt history and headers fail across refills" {
    const work = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(work);
    var input: [17]u8 = undefined;
    var output: [4096]u8 = undefined;
    inline for (.{ .{ @embedFile("data/synthetic/invalid-history.gz"), error.BadDistance }, .{ @embedFile("data/synthetic/invalid-fhcrc.gz"), error.HeaderCrcMismatch } }) |case| {
        var source = support.Source.init(case[0], &input, 1);
        var sink: support.Sink = .{ .output = &output };
        try std.testing.expectError(case[1], work.decompress(&source.reader, &sink.writer, .{}));
    }
    const seed = @embedFile("data/synthetic/long-header.gz");
    const damaged = try std.testing.allocator.dupe(u8, seed);
    defer std.testing.allocator.free(damaged);
    damaged[70000] ^= 1;
    var source = support.Source.init(damaged, &input, 3);
    var sink: support.Sink = .{ .output = &output };
    try std.testing.expectError(error.HeaderCrcMismatch, work.decompress(&source.reader, &sink.writer, .{}));
}

test "[failure] - [gzip]: I/O errors propagate and workspace can be reused" {
    const seed = @embedFile("data/synthetic/final-stored-concat.gz");
    const work = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(work);
    var input: [17]u8 = undefined;
    var output: [4096]u8 = undefined;
    for ([_]usize{ 0, 9, 20, seed.len - 3 }) |offset| {
        var source = support.Source.init(seed, &input, 3);
        source.fail_at = offset;
        var sink: support.Sink = .{ .output = &output };
        try std.testing.expectError(error.ReadFailed, work.decompress(&source.reader, &sink.writer, .{}));
    }
    var source = support.Source.init(seed, &input, 17);
    var sink: support.Sink = .{ .output = &output, .fail_at = 4096 };
    try std.testing.expectError(error.WriteFailed, work.decompress(&source.reader, &sink.writer, .{}));
    source = support.Source.init(seed, &input, 17);
    sink = .{ .output = &output };
    try std.testing.expectEqual(@as(usize, 231823), try work.decompress(&source.reader, &sink.writer, .{}));
}

test "[edge] - [gzip]: buffer minimum and unread trailing bytes preserve the caller contract" {
    const seed = @embedFile("data/synthetic/repeat-zero.gz");
    const work = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(work);
    var input: [32]u8 = undefined;
    var output: [4096]u8 = undefined;
    for ([_]usize{ 0, 1, 15 }) |capacity| {
        var source = support.Source.init(seed, input[0..capacity], 1);
        var sink: support.Sink = .{ .output = &output };
        try std.testing.expectError(error.InputBufferTooSmall, work.decompress(&source.reader, &sink.writer, .{}));
    }
    var source = support.Source.init(seed.* ++ "tail", &input, 3);
    var sink: support.Sink = .{ .output = &output };
    try std.testing.expectEqual(@as(usize, 1), try work.decompress(&source.reader, &sink.writer, .{ .trailing_data = .leave }));
    try std.testing.expectEqualSlices(u8, "tail", try source.reader.take(4));
    const header = @embedFile("data/synthetic/long-header.gz");
    for ([_]usize{ 10, 11, 12, 65545, 65547, 70000, 135548, 201549, header.len - 1 }) |cut| {
        source = support.Source.init(header[0..cut], &input, 17);
        sink.count = 0;
        if (work.decompress(&source.reader, &sink.writer, .{})) |_| return error.AcceptedTruncation else |_| {}
    }
}

test "[failure] - [gzip]: output limits cover matches stored blocks and member boundaries" {
    const cases = .{
        .{ @embedFile("data/synthetic/short6.gz"), @as(usize, 100750) },
        .{ @embedFile("data/synthetic/final-stored-concat.gz"), @as(usize, 231823) },
        .{ @embedFile("data/synthetic/copy-boundaries.gz"), @as(usize, 1041056) },
    };
    const decoder = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(decoder);
    inline for (cases) |case| {
        for ([_]usize{ 0, 1, 257, 32768, 131071, 131072, case[1] - 1, case[1], case[1] + 1 }) |limit| {
            var reader = std.Io.Reader.fixed(case[0]);
            var writer: std.Io.Writer.Discarding = .init(&.{});
            if (limit < case[1]) {
                try std.testing.expectError(error.OutputLimitExceeded, decoder.decompress(&reader, &writer.writer, .{ .max_output_bytes = limit }));
                try std.testing.expect(writer.fullCount() <= limit);
            } else {
                try std.testing.expectEqual(case[1], try decoder.decompress(&reader, &writer.writer, .{ .max_output_bytes = limit }));
                try std.testing.expectEqual(case[1], writer.fullCount());
            }
        }
    }
}

test "[failure] - [gzip]: validates headers blocks CRC and ISIZE" {
    const seed = @embedFile("data/synthetic/short6.gz");
    const decoder = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(decoder);
    const damaged = try std.testing.allocator.dupe(u8, seed);
    defer std.testing.allocator.free(damaged);
    const cases = .{
        .{ 0, @as(u8, 1), error.BadHeader },
        .{ 2, @as(u8, 1), error.UnsupportedMethod },
        .{ 3, @as(u8, 32), error.ReservedFlag },
        .{ 10, @as(u8, 2), error.BadBlock },
        .{ seed.len - 8, @as(u8, 1), error.CrcMismatch },
        .{ seed.len - 4, @as(u8, 1), error.IsizeMismatch },
    };
    inline for (cases) |case| {
        @memcpy(damaged, seed);
        damaged[case[0]] ^= case[1];
        var reader = std.Io.Reader.fixed(damaged);
        var writer: std.Io.Writer.Discarding = .init(&.{});
        try std.testing.expectError(case[2], decoder.decompress(&reader, &writer.writer, .{}));
    }
}

test "[edge] - [gzip]: strict trailing data empty members and fixed output capacity" {
    const seed = @embedFile("data/synthetic/repeat-zero.gz");
    const empty = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    const decoder = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(decoder);
    var reader = std.Io.Reader.fixed(empty);
    var writer = std.Io.Writer.fixed(&.{});
    try std.testing.expectEqual(@as(u64, 0), try decoder.decompress(&reader, &writer, .{ .max_output_bytes = 0 }));
    reader = std.Io.Reader.fixed(seed);
    try std.testing.expectError(error.WriteFailed, decoder.decompress(&reader, &writer, .{}));
    inline for (.{ "x", "tail", "\x00", "\x1f" }) |suffix| {
        var input: [16]u8 = undefined;
        var source = support.Source.init(seed.* ++ suffix, &input, 1);
        var sink: std.Io.Writer.Discarding = .init(&.{});
        try std.testing.expectError(error.TrailingData, decoder.decompress(&source.reader, &sink.writer, .{}));
        source = support.Source.init(seed.* ++ suffix, &input, 1);
        sink = .init(&.{});
        try std.testing.expectEqual(@as(u64, 1), try decoder.decompress(&source.reader, &sink.writer, .{ .trailing_data = .leave }));
        try std.testing.expectEqualSlices(u8, suffix, try source.reader.take(suffix.len));
    }
    var one: [1]u8 = undefined;
    reader = std.Io.Reader.fixed(empty ++ seed.* ++ empty);
    writer = .fixed(&one);
    try std.testing.expectEqual(@as(u64, 1), try decoder.decompress(&reader, &writer, .{ .max_output_bytes = 1 }));
    try std.testing.expectEqualStrings("A", writer.buffered());
}

test "[failure] - [gzip]: incomplete and oversubscribed Huffman trees are rejected" {
    const decoder = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(decoder);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var reader = std.Io.Reader.fixed(@embedFile("data/synthetic/empty-single.gz"));
    try std.testing.expectEqual(@as(u64, 0), try decoder.decompress(&reader, &sink.writer, .{}));
    inline for (.{ "incomplete-literal", "incomplete-distance", "incomplete-code-length", "oversubscribed-literal" }) |name| {
        reader = .fixed(@embedFile("data/synthetic/" ++ name ++ ".gz"));
        try std.testing.expectError(error.BadHuffman, decoder.decompress(&reader, &sink.writer, .{}));
    }
}

test "[property] - [gzip]: bounded mutations and truncations never escape validation" {
    const decoder = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(decoder);
    var random = std.Random.DefaultPrng.init(91239);
    const seeds = .{ @embedFile("data/synthetic/repeat-zero.gz"), @embedFile("data/synthetic/short6.gz"), @embedFile("data/synthetic/long-codes.gz") };
    inline for (seeds) |seed| {
        const mutated = try std.testing.allocator.dupe(u8, seed);
        defer std.testing.allocator.free(mutated);
        const first_cut = if (seed.len > 1500) seed.len - 32 else 16;
        for (first_cut..seed.len) |cut| {
            var reader = std.Io.Reader.fixed(seed[0..cut]);
            var sink: std.Io.Writer.Discarding = .init(&.{});
            if (decoder.decompress(&reader, &sink.writer, .{})) |_| return error.AcceptedTruncation else |_| {}
        }
        for (0..256) |_| {
            @memcpy(mutated, seed);
            const position = random.random().uintLessThan(usize, seed.len);
            mutated[position] ^= @as(u8, 1) << random.random().int(u3);
            var reader = std.Io.Reader.fixed(mutated);
            var sink: std.Io.Writer.Discarding = .init(&.{});
            _ = decoder.decompress(&reader, &sink.writer, .{ .max_output_bytes = 262144 }) catch {};
            try std.testing.expect(sink.fullCount() <= 262144);
        }
    }
    var bytes: [256]u8 = undefined;
    for (0..256) |length| {
        random.fill(&bytes);
        if (length >= 10) @memcpy(bytes[0..10], "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03");
        var buffer: [16]u8 = undefined;
        var source = support.Source.init(bytes[0..length], &buffer, 3);
        var sink: std.Io.Writer.Discarding = .init(&.{});
        _ = decoder.decompress(&source.reader, &sink.writer, .{ .max_output_bytes = 262144 }) catch {};
        try std.testing.expect(sink.fullCount() <= 262144);
    }
}

test "[regression] - [gzip]: fixed tables preserve all slots across dynamic members" {
    const fixed = @embedFile("data/synthetic/fixed-codes.gz");
    const fixed_plain = @embedFile("data/synthetic/fixed-codes.plain");
    const compressed = fixed.* ++ @embedFile("data/synthetic/long-codes.gz").* ++ fixed.*;
    const plain = fixed_plain.* ++ @embedFile("data/synthetic/long-codes.plain").* ++ fixed_plain.*;
    const decoder = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(decoder);
    const got = try std.testing.allocator.alloc(u8, plain.len);
    defer std.testing.allocator.free(got);
    var input: [32768]u8 = undefined;
    var output: [4096]u8 = undefined;
    for ([_]usize{ 16, 17, 32768 }) |size| {
        var source = support.Source.init(&compressed, input[0..size], size);
        var sink: support.Sink = .{ .output = &output, .sink = got };
        try std.testing.expectEqual(plain.len, try decoder.decompress(&source.reader, &sink.writer, .{}));
        try std.testing.expectEqualSlices(u8, &plain, got);
        inline for (.{ "286", "287", "30", "31" }) |symbol| {
            source = support.Source.init(@embedFile("data/synthetic/fixed-invalid-" ++ symbol ++ ".gz"), input[0..size], size);
            sink = .{ .output = &output };
            try std.testing.expectError(error.BadSymbol, decoder.decompress(&source.reader, &sink.writer, .{}));
        }
    }
}

// --- Compression ---

fn encodeRoundtrip(encoder: *z_flate.gzip.Compressor, plain: []const u8, options: z_flate.gzip.CompressOptions, chunk: usize, capacity: usize) !usize {
    var in_buffer: [17]u8 = undefined;
    var source = support.Source.init(plain, in_buffer[0..capacity], chunk);
    const encoded = try std.testing.allocator.alloc(u8, plain.len + 64);
    defer std.testing.allocator.free(encoded);
    var out_buffer: [13]u8 = undefined;
    var output = support.Sink{ .output = &out_buffer, .sink = encoded, .max_drain = 7 };
    try std.testing.expectEqual(@as(u64, plain.len), try encoder.compress(&source.reader, &output.writer, options));
    const trailer = encoded[output.count - 8 ..][0..8];
    try std.testing.expectEqual(std.hash.Crc32.hash(plain), std.mem.readInt(u32, trailer[0..4], .little));
    try std.testing.expectEqual(@as(u32, @truncate(plain.len)), std.mem.readInt(u32, trailer[4..8], .little));
    var compressed = std.Io.Reader.fixed(encoded[0..output.count]);
    var oracle = std.Io.Reader.fixed(plain);
    var decoded_buffer: [1031]u8 = undefined;
    var sink = support.Sink{ .output = &decoded_buffer, .oracle = &oracle };
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d: std.compress.flate.Decompress = .init(&compressed, .gzip, &window);
    try std.testing.expectEqual(@as(u64, plain.len), try d.reader.streamRemaining(&sink.writer));
    try std.testing.expect(!sink.mismatch);
    try std.testing.expectEqual(plain.len, sink.count);
    return output.count;
}

test "[integration] - [gzip compressor]: empty and repeated calls produce independent members" {
    const empty = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    const one = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff\x73\x04\x00\x8b\x9e\xd9\xd3\x01\x00\x00\x00";
    const encoder = try std.testing.allocator.create(z_flate.Compressor(.gzip));
    defer std.testing.allocator.destroy(encoder);
    const decoder = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(decoder);
    var bytes: [empty.len + one.len]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var reader = std.Io.Reader.fixed("");
    try std.testing.expectEqual(@as(u64, 0), try encoder.compress(&reader, &writer, .{}));
    reader = .fixed("A");
    try std.testing.expectEqual(@as(u64, 1), try encoder.compress(&reader, &writer, .{}));
    try std.testing.expectEqualSlices(u8, empty ++ one, writer.buffered());
    reader = .fixed(writer.buffered());
    var output: [1]u8 = undefined;
    var decoded = std.Io.Writer.fixed(&output);
    try std.testing.expectEqual(@as(u64, 1), try decoder.decompress(&reader, &decoded, .{}));
    try std.testing.expectEqualSlices(u8, "A", decoded.buffered());
}

test "[property] - [gzip compressor]: block and window boundaries survive short I/O" {
    const encoder = try std.testing.allocator.create(z_flate.Compressor(.gzip));
    defer std.testing.allocator.destroy(encoder);
    var plain: [131073]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(904);
    rng.random().bytes(&plain);
    for ([_]z_flate.gzip.CompressOptions{ .{ .level = .fast }, .{}, .{ .level = .dense } }) |options| {
        for ([_]usize{ 0, 1, 2, 3, 257, 258, 259, 32767, 32768, 32769, 65535, 65536, 65537, 131073 }) |n| {
            const size = try encodeRoundtrip(encoder, plain[0..n], options, 997, 17);
            if (n == 0) try std.testing.expectEqual(@as(usize, 20), size);
            if (n >= 32767) try std.testing.expect(size <= n + 18 + 5 * ((n + 32767) / 32768));
        }
        _ = try encodeRoundtrip(encoder, plain[0..1031], options, 1, 17);
        for ([_]usize{ 0, 1 }) |capacity| {
            _ = try encodeRoundtrip(encoder, plain[0..65537], options, 997, capacity);
        }
    }
}

test "[property] - [gzip compressor]: periodic overlap and maximum history preserve bytes" {
    const encoder = try std.testing.allocator.create(z_flate.Compressor(.gzip));
    defer std.testing.allocator.destroy(encoder);
    var plain: [131073]u8 = undefined;
    for ([_]usize{ 1, 2, 3, 7, 16, 257, 32767, 32768 }) |period| {
        var rng = std.Random.DefaultPrng.init(880);
        rng.random().bytes(plain[0..period]);
        for (period..plain.len) |i| plain[i] = plain[i - period];
        for ([_]z_flate.gzip.CompressOptions{ .{ .level = .fast }, .{}, .{ .level = .dense } }) |options| _ = try encodeRoundtrip(encoder, &plain, options, 8191, 17);
    }
}

test "[failure] - [gzip compressor]: I/O errors propagate and workspace resets" {
    const encoder = try std.testing.allocator.create(z_flate.Compressor(.gzip));
    defer std.testing.allocator.destroy(encoder);
    var plain: [65537]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(144);
    rng.random().bytes(&plain);
    for ([_]usize{ 0, 1, 32768, 32769, 65536 }) |fail| {
        var buffer: [17]u8 = undefined;
        var source = support.Source.init(&plain, &buffer, 200);
        source.fail_at = fail;
        var scratch: [29]u8 = undefined;
        var sink = support.Sink{ .output = &scratch };
        try std.testing.expectError(error.ReadFailed, encoder.compress(&source.reader, &sink.writer, .{ .level = .dense }));
        _ = try encodeRoundtrip(encoder, "reused after read failure", .{ .level = .dense }, 1, 17);
    }
    for ([_]usize{ 0, 10, 16, 500, 65555 }) |fail| {
        var source = std.Io.Reader.fixed(&plain);
        var scratch: [29]u8 = undefined;
        var sink = support.Sink{ .output = &scratch, .fail_at = fail };
        try std.testing.expectError(error.WriteFailed, encoder.compress(&source, &sink.writer, .{ .level = .fast }));
        if (fail == 0) try std.testing.expectEqual(@as(usize, 0), source.seek);
        if (fail <= 500) try std.testing.expect(source.seek <= 32769);
        _ = try encodeRoundtrip(encoder, "reused after write failure", .{ .level = .fast }, 1, 17);
    }
}
