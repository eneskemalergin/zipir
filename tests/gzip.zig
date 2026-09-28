//! Checks the public gzip streaming API at refill, output and failure boundaries.

const std = @import("std");
const zipir = @import("zipir");
const support = @import("support.zig");
const Decoder = zipir.Decompressor(.gzip);

test "[integration] - [gzip decompressor]: bounded refills and partial drains preserve members and long headers" {
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
            const n = try support.decompressAll(work, &source.reader, &sink.writer, .{});
            try std.testing.expectEqual(case[1].len, n);
            try std.testing.expectEqualSlices(u8, case[1], got);
        }
    }
}

test "[integration] - [gzip decompressor]: optional headers without FHCRC preserve refills and payload CRC" {
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
        try std.testing.expectEqual(plain.len, try support.decompressAll(work, &source.reader, &sink.writer, .{}));
        try std.testing.expectEqualSlices(u8, plain, got);
        compressed[compressed.len - 8] ^= 1;
        source = support.Source.init(compressed, input[0..size], size);
        sink = .{ .output = &output };
        try std.testing.expectError(error.CrcMismatch, support.decompressAll(work, &source.reader, &sink.writer, .{}));
        compressed[compressed.len - 8] ^= 1;
    }
}

test "[property] - [gzip decompressor]: every small input split and truncated prefix is checked" {
    const seed = @embedFile("data/synthetic/repeat-zero.gz");
    const work = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(work);
    var input: [16]u8 = undefined;
    var output: [1]u8 = undefined;
    for (0..seed.len + 1) |split| {
        var source = support.Source.init(seed, &input, 65536);
        source.split_at = split;
        var sink: support.Sink = .{ .output = &output };
        try std.testing.expectEqual(@as(usize, 1), try support.decompressAll(work, &source.reader, &sink.writer, .{}));
        try std.testing.expectEqual(@as(u8, 'A'), output[0]);
        if (split == seed.len) continue;
        source = support.Source.init(seed[0..split], &input, 1);
        sink.count = 0;
        if (support.decompressAll(work, &source.reader, &sink.writer, .{})) |_| return error.AcceptedTruncation else |_| {}
    }
}

test "[failure] - [gzip decompressor]: corrupt history and headers fail across refills" {
    const work = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(work);
    var input: [17]u8 = undefined;
    var output: [4096]u8 = undefined;
    inline for (.{ .{ @embedFile("data/synthetic/invalid-history.gz"), error.BadDistance }, .{ @embedFile("data/synthetic/invalid-fhcrc.gz"), error.HeaderCrcMismatch } }) |case| {
        var source = support.Source.init(case[0], &input, 1);
        var sink: support.Sink = .{ .output = &output };
        try std.testing.expectError(case[1], support.decompressAll(work, &source.reader, &sink.writer, .{}));
    }
    const seed = @embedFile("data/synthetic/long-header.gz");
    const damaged = try std.testing.allocator.dupe(u8, seed);
    defer std.testing.allocator.free(damaged);
    damaged[70000] ^= 1;
    var source = support.Source.init(damaged, &input, 3);
    var sink: support.Sink = .{ .output = &output };
    try std.testing.expectError(error.HeaderCrcMismatch, support.decompressAll(work, &source.reader, &sink.writer, .{}));
}

test "[failure] - [gzip decompressor]: I/O errors propagate and workspace can be reused" {
    const seed = @embedFile("data/synthetic/final-stored-concat.gz");
    const work = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(work);
    var input: [17]u8 = undefined;
    var output: [4096]u8 = undefined;
    for ([_]usize{ 0, 9, 20, seed.len - 3 }) |offset| {
        var source = support.Source.init(seed, &input, 3);
        source.fail_at = offset;
        var sink: support.Sink = .{ .output = &output };
        try std.testing.expectError(error.ReadFailed, support.decompressAll(work, &source.reader, &sink.writer, .{}));
    }
    var source = support.Source.init(seed, &input, 17);
    var sink: support.Sink = .{ .output = &output, .fail_at = 4096 };
    try std.testing.expectError(error.WriteFailed, support.decompressAll(work, &source.reader, &sink.writer, .{}));
    source = support.Source.init(seed, &input, 17);
    sink = .{ .output = &output };
    try std.testing.expectEqual(@as(usize, 231823), try support.decompressAll(work, &source.reader, &sink.writer, .{}));
}

test "[edge] - [gzip decompressor]: buffer minimum and unread trailing bytes preserve the caller contract" {
    const seed = @embedFile("data/synthetic/repeat-zero.gz");
    const work = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(work);
    var input: [32]u8 = undefined;
    var output: [4096]u8 = undefined;
    for ([_]usize{ 0, 1, 15 }) |capacity| {
        var source = support.Source.init(seed, input[0..capacity], 1);
        var sink: support.Sink = .{ .output = &output };
        try std.testing.expectError(error.InputBufferTooSmall, support.decompressAll(work, &source.reader, &sink.writer, .{}));
    }
    var source = support.Source.init(seed.* ++ "tail", &input, 3);
    var sink: support.Sink = .{ .output = &output };
    try std.testing.expectEqual(@as(usize, 1), try support.decompressAll(work, &source.reader, &sink.writer, .{ .trailing_data = .leave }));
    try std.testing.expectEqualSlices(u8, "tail", try source.reader.take(4));
    const header = @embedFile("data/synthetic/long-header.gz");
    for ([_]usize{ 10, 11, 12, 65545, 65547, 70000, 135548, 201549, header.len - 1 }) |cut| {
        source = support.Source.init(header[0..cut], &input, 17);
        sink.count = 0;
        if (support.decompressAll(work, &source.reader, &sink.writer, .{})) |_| return error.AcceptedTruncation else |_| {}
    }
}

test "[failure] - [gzip decompressor]: output limits cover matches stored blocks and member boundaries" {
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
                try std.testing.expectError(error.OutputLimitExceeded, support.decompressAll(decoder, &reader, &writer.writer, .{ .max_output_bytes = limit }));
                try std.testing.expect(writer.fullCount() <= limit);
            } else {
                try std.testing.expectEqual(case[1], try support.decompressAll(decoder, &reader, &writer.writer, .{ .max_output_bytes = limit }));
                try std.testing.expectEqual(case[1], writer.fullCount());
            }
        }
    }
}

test "[failure] - [gzip decompressor]: validates headers blocks CRC and ISIZE" {
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
        try std.testing.expectError(case[2], support.decompressAll(decoder, &reader, &writer.writer, .{}));
    }
}

test "[edge] - [gzip decompressor]: strict trailing data empty members and fixed output capacity" {
    const seed = @embedFile("data/synthetic/repeat-zero.gz");
    const empty = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    const decoder = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(decoder);
    var reader = std.Io.Reader.fixed(empty);
    var writer = std.Io.Writer.fixed(&.{});
    try std.testing.expectEqual(@as(u64, 0), try support.decompressAll(decoder, &reader, &writer, .{ .max_output_bytes = 0 }));
    reader = std.Io.Reader.fixed(seed);
    try std.testing.expectError(error.WriteFailed, support.decompressAll(decoder, &reader, &writer, .{}));
    inline for (.{ "x", "tail", "\x00", "\x1f" }) |suffix| {
        var input: [16]u8 = undefined;
        var source = support.Source.init(seed.* ++ suffix, &input, 1);
        var sink: std.Io.Writer.Discarding = .init(&.{});
        try std.testing.expectError(error.TrailingData, support.decompressAll(decoder, &source.reader, &sink.writer, .{}));
        source = support.Source.init(seed.* ++ suffix, &input, 1);
        sink = .init(&.{});
        try std.testing.expectEqual(@as(u64, 1), try support.decompressAll(decoder, &source.reader, &sink.writer, .{ .trailing_data = .leave }));
        try std.testing.expectEqualSlices(u8, suffix, try source.reader.take(suffix.len));
    }
    var one: [1]u8 = undefined;
    reader = std.Io.Reader.fixed(empty ++ seed.* ++ empty);
    writer = .fixed(&one);
    try std.testing.expectEqual(@as(u64, 1), try support.decompressAll(decoder, &reader, &writer, .{ .max_output_bytes = 1 }));
    try std.testing.expectEqualStrings("A", writer.buffered());
}

test "[failure] - [gzip decompressor]: incomplete and oversubscribed Huffman trees are rejected" {
    const decoder = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(decoder);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var reader = std.Io.Reader.fixed(@embedFile("data/synthetic/empty-single.gz"));
    try std.testing.expectEqual(@as(u64, 0), try support.decompressAll(decoder, &reader, &sink.writer, .{}));
    inline for (.{ "incomplete-literal", "incomplete-distance", "incomplete-code-length", "oversubscribed-literal" }) |name| {
        reader = .fixed(@embedFile("data/synthetic/" ++ name ++ ".gz"));
        try std.testing.expectError(error.BadHuffman, support.decompressAll(decoder, &reader, &sink.writer, .{}));
    }
}

test "[property] - [gzip decompressor]: bounded mutations and truncations never escape validation" {
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
            if (support.decompressAll(decoder, &reader, &sink.writer, .{})) |_| return error.AcceptedTruncation else |_| {}
        }
        for (0..256) |_| {
            @memcpy(mutated, seed);
            const position = random.random().uintLessThan(usize, seed.len);
            mutated[position] ^= @as(u8, 1) << random.random().int(u3);
            var reader = std.Io.Reader.fixed(mutated);
            var sink: std.Io.Writer.Discarding = .init(&.{});
            _ = support.decompressAll(decoder, &reader, &sink.writer, .{ .max_output_bytes = 262144 }) catch {};
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
        _ = support.decompressAll(decoder, &source.reader, &sink.writer, .{ .max_output_bytes = 262144 }) catch {};
        try std.testing.expect(sink.fullCount() <= 262144);
    }
}

test "[regression] - [gzip decompressor]: fixed tables preserve all slots across dynamic members" {
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
        try std.testing.expectEqual(plain.len, try support.decompressAll(decoder, &source.reader, &sink.writer, .{}));
        try std.testing.expectEqualSlices(u8, &plain, got);
        inline for (.{ "286", "287", "30", "31" }) |symbol| {
            source = support.Source.init(@embedFile("data/synthetic/fixed-invalid-" ++ symbol ++ ".gz"), input[0..size], size);
            sink = .{ .output = &output };
            try std.testing.expectError(error.BadSymbol, support.decompressAll(decoder, &source.reader, &sink.writer, .{}));
        }
    }
}

// --- Compression ---

fn encodeRoundtrip(encoder: *zipir.gzip.Compressor, plain: []const u8, options: zipir.gzip.CompressOptions, chunk: usize, capacity: usize) !usize {
    const encoded = try std.testing.allocator.alloc(u8, plain.len + 64);
    defer std.testing.allocator.free(encoded);
    const member = try support.encodeRoundtrip(zipir.gzip, encoder, .gzip, plain, options, chunk, capacity, encoded);
    const trailer = member[member.len - 8 ..][0..8];
    try std.testing.expectEqual(std.hash.Crc32.hash(plain), std.mem.readInt(u32, trailer[0..4], .little));
    try std.testing.expectEqual(@as(u32, @truncate(plain.len)), std.mem.readInt(u32, trailer[4..8], .little));
    return member.len;
}

test "[integration] - [gzip compressor]: empty and repeated calls produce independent members" {
    const empty = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    const one = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff\x73\x04\x00\x8b\x9e\xd9\xd3\x01\x00\x00\x00";
    const encoder = try std.testing.allocator.create(zipir.Compressor(.gzip));
    defer std.testing.allocator.destroy(encoder);
    const decoder = try std.testing.allocator.create(Decoder);
    defer std.testing.allocator.destroy(decoder);
    var bytes: [empty.len + one.len]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var reader = std.Io.Reader.fixed("");
    try std.testing.expectEqual(@as(u64, 0), try support.compressAll(encoder, &reader, &writer, .{}));
    reader = .fixed("A");
    try std.testing.expectEqual(@as(u64, 1), try support.compressAll(encoder, &reader, &writer, .{}));
    try std.testing.expectEqualSlices(u8, empty ++ one, writer.buffered());
    reader = .fixed(writer.buffered());
    var output: [1]u8 = undefined;
    var decoded = std.Io.Writer.fixed(&output);
    try std.testing.expectEqual(@as(u64, 1), try support.decompressAll(decoder, &reader, &decoded, .{}));
    try std.testing.expectEqualSlices(u8, "A", decoded.buffered());
}

test "[property] - [gzip compressor]: reused workspaces match fresh output across preset changes" {
    const encoder = try std.testing.allocator.create(zipir.Compressor(.gzip));
    defer std.testing.allocator.destroy(encoder);
    const fresh = try std.testing.allocator.create(zipir.Compressor(.gzip));
    defer std.testing.allocator.destroy(fresh);
    // A four-letter alphabet gives long hash chains and lazy decisions in every block.
    var plain: [98305]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(611);
    for (&plain) |*b| b.* = 'a' + rng.random().uintLessThan(u8, 4);
    var expected: [100000]u8 = undefined;
    var actual: [100000]u8 = undefined;
    for ([_]zipir.gzip.CompressOptions{ .{ .preset = .fast }, .{ .preset = .dense }, .{ .preset = .fast }, .{}, .{ .preset = .dense } }) |options| {
        var reader = std.Io.Reader.fixed(&plain);
        var writer = std.Io.Writer.fixed(&expected);
        _ = try support.compressAll(fresh, &reader, &writer, options);
        const want = writer.buffered();
        fresh.* = undefined;
        reader = .fixed(&plain);
        writer = .fixed(&actual);
        _ = try support.compressAll(encoder, &reader, &writer, options);
        try std.testing.expectEqualSlices(u8, want, writer.buffered());
    }
}

test "[property] - [gzip compressor]: block and window boundaries survive short I/O" {
    const encoder = try std.testing.allocator.create(zipir.Compressor(.gzip));
    defer std.testing.allocator.destroy(encoder);
    var plain: [131073]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(904);
    rng.random().bytes(&plain);
    for ([_]zipir.gzip.CompressOptions{ .{ .preset = .fast }, .{}, .{ .preset = .dense } }) |options| {
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
    const encoder = try std.testing.allocator.create(zipir.Compressor(.gzip));
    defer std.testing.allocator.destroy(encoder);
    var plain: [131073]u8 = undefined;
    for ([_]usize{ 1, 2, 3, 7, 16, 257, 32767, 32768 }) |period| {
        var rng = std.Random.DefaultPrng.init(880);
        rng.random().bytes(plain[0..period]);
        for (period..plain.len) |i| plain[i] = plain[i - period];
        for ([_]zipir.gzip.CompressOptions{ .{ .preset = .fast }, .{}, .{ .preset = .dense } }) |options| _ = try encodeRoundtrip(encoder, &plain, options, 8191, 17);
    }
}

test "[property] - [gzip compressor]: long-distance matches survive small writer buffers" {
    // Random bytes with segments copied from far back: tokens of 40 bits and more, emitted while the writer
    // has only a few bytes of room.
    const encoder = try std.testing.allocator.create(zipir.Compressor(.gzip));
    defer std.testing.allocator.destroy(encoder);
    var plain: [3 * 32768 + 777]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(271);
    const random = rng.random();
    random.bytes(&plain);
    var i: usize = 32768;
    while (i + 64 < plain.len) : (i += 61) {
        const len = 4 + random.uintLessThan(usize, 50);
        const dist = 16384 + random.uintLessThan(usize, 16384);
        for (plain[i..][0..len], 0..) |*byte, k| byte.* = plain[i - dist + k];
    }
    const encoded = try std.testing.allocator.alloc(u8, plain.len + 64);
    defer std.testing.allocator.free(encoded);
    // Writer buffers around the emitters' 8- and 16-byte room checks, drained 7 bytes at a time or whole (a
    // whole drain leaves room while bits from a writer-limited step are still pending).
    for ([_]usize{ 13, 16, 17, 23, 24, 31, 40, 64 }) |out_capacity| {
        for ([_]usize{ 7, std.math.maxInt(usize) }) |max_drain| {
            for ([_]zipir.gzip.CompressOptions{ .{ .preset = .fast }, .{}, .{ .preset = .dense } }) |options| {
                _ = try support.encodeRoundtripOut(zipir.gzip, encoder, .gzip, &plain, options, 8191, 17, out_capacity, max_drain, encoded);
            }
        }
    }
}

test "[property] - [gzip compressor]: robustness shapes round-trip at every preset" {
    // The shapes of tmp/levels/inputs.py at test size: incompressible bytes (stored blocks, and the search turned
    // off), long runs and short periods (self-overlapping matches), four-letter near-repeats (long chains), and
    // random bytes followed by text (the search has to turn back on).
    const encoder = try std.testing.allocator.create(zipir.Compressor(.gzip));
    defer std.testing.allocator.destroy(encoder);
    const size = 200 * 1024 + 321;
    const plain = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(plain);
    var rng = std.Random.DefaultPrng.init(0x5a1);
    const random = rng.random();
    for (0..5) |shape| {
        switch (shape) {
            0 => random.bytes(plain),
            1 => {
                var i: usize = 0;
                while (i < size) {
                    const n = @min(size - i, 1000 + random.uintLessThan(usize, 60000));
                    @memset(plain[i..][0..n], random.int(u8));
                    i += n;
                }
            },
            2 => {
                var i: usize = 0;
                while (i < size) {
                    var unit: [31]u8 = undefined;
                    const period = 2 + random.uintLessThan(usize, 30);
                    random.bytes(unit[0..period]);
                    const n = @min(size - i, 4096 + random.uintLessThan(usize, 30000));
                    for (plain[i..][0..n], 0..) |*byte, k| byte.* = unit[k % period];
                    i += n;
                }
            },
            3 => {
                var base: [4096]u8 = undefined;
                for (&base) |*byte| byte.* = "ACGT"[random.uintLessThan(usize, 4)];
                var i: usize = 0;
                while (i < size) : (i += base.len) {
                    const n = @min(size - i, base.len);
                    @memcpy(plain[i..][0..n], base[0..n]);
                    for (0..8) |_| plain[i + random.uintLessThan(usize, n)] = "ACGT"[random.uintLessThan(usize, 4)];
                }
            },
            else => {
                random.bytes(plain[0 .. size / 2]);
                for (plain[size / 2 ..], 0..) |*byte, k| byte.* = "the quick brown fox jumps over the lazy dog\n"[k % 44];
            },
        }
        for ([_]zipir.gzip.CompressOptions{ .{ .preset = .fast }, .{ .preset = .even }, .{ .preset = .dense } }) |options| {
            const len = try encodeRoundtrip(encoder, plain, options, 8191, 17);
            switch (shape) {
                // Stored blocks: at most 0.1% over the input plus the gzip header and trailer.
                0 => try std.testing.expect(len <= size + size / 1000 + 18),
                1, 2 => try std.testing.expect(len * 50 < size),
                // The text half compresses although the first half turned the search off.
                4 => try std.testing.expect(len < size / 2 + size / 20),
                else => {},
            }
        }
    }
}

test "[failure] - [gzip compressor]: I/O errors propagate and workspace resets" {
    const encoder = try std.testing.allocator.create(zipir.Compressor(.gzip));
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
        try std.testing.expectError(error.ReadFailed, support.compressAll(encoder, &source.reader, &sink.writer, .{ .preset = .dense }));
        _ = try encodeRoundtrip(encoder, "reused after read failure", .{ .preset = .dense }, 1, 17);
    }
    for ([_]usize{ 0, 10, 16, 500, 65555 }) |fail| {
        var source = std.Io.Reader.fixed(&plain);
        var scratch: [29]u8 = undefined;
        var sink = support.Sink{ .output = &scratch, .fail_at = fail };
        try std.testing.expectError(error.WriteFailed, support.compressAll(encoder, &source, &sink.writer, .{ .preset = .fast }));
        if (fail == 0) try std.testing.expectEqual(@as(usize, 0), source.seek);
        // fast writes one block per two 32 KiB windows, so at most two windows and the lookahead byte are read.
        if (fail <= 500) try std.testing.expect(source.seek <= 65537);
        _ = try encodeRoundtrip(encoder, "reused after write failure", .{ .preset = .fast }, 1, 17);
    }
}

test "[unit] - [gzip]: the public error set names exactly the documented errors" {
    const expected = [_][]const u8{ "BadBlock", "BadDistance", "BadHeader", "BadHuffman", "BadStored", "BadSymbol", "CrcMismatch", "HeaderCrcMismatch", "HeaderTooLong", "InputBufferTooSmall", "IsizeMismatch", "OutputLimitExceeded", "PeekTooLarge", "ReadFailed", "ReservedFlag", "TrailingData", "Truncated", "UnsupportedMethod" };
    try support.expectErrorNames(zipir.gzip.DecompressError, &expected);
}
