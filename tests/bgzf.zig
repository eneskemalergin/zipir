//! Public BGZF reading contracts: structure checks, EOF policy, scan, single blocks, and virtual offsets.

const std = @import("std");
const support = @import("support.zig");
const zipir = @import("zipir");
const bgzf = zipir.bgzf;

const EOF = &bgzf.EOF_MARKER;

// Builds a block independently of the BGZF code: a zipir gzip member whose 10-byte header is replaced by one
// with FEXTRA, `extra` subfields, then `BC`; `bsize_delta` falsifies BSIZE.
fn block(out: []u8, plain: []const u8, extra: []const u8, bsize_delta: i32) ![]u8 {
    var member_buffer: [70000]u8 = undefined;
    var reader = std.Io.Reader.fixed(plain);
    var writer = std.Io.Writer.fixed(&member_buffer);
    var encoder: zipir.Compressor(.gzip) = undefined;
    _ = try encoder.compress(&reader, &writer, .{});
    const body = writer.buffered()[10..];
    const xlen = extra.len + 6;
    const size = 12 + xlen + body.len;
    @memcpy(out[0..10], "\x1f\x8b\x08\x04\x00\x00\x00\x00\x00\xff");
    std.mem.writeInt(u16, out[10..12], @intCast(xlen), .little);
    @memcpy(out[12..][0..extra.len], extra);
    @memcpy(out[12 + extra.len ..][0..4], "BC\x02\x00");
    std.mem.writeInt(u16, out[16 + extra.len ..][0..2], @intCast(@as(i32, @intCast(size)) - 1 + bsize_delta), .little);
    @memcpy(out[12 + xlen ..][0..body.len], body);
    return out[0..size];
}

const Fixture = struct {
    bytes: [140000]u8 = undefined,
    len: usize = 0,
    plain: [70000]u8 = undefined,
    plain_len: usize = 0,
    starts: [8]u64 = undefined,
    blocks: usize = 0,

    fn add(self: *Fixture, plain: []const u8, extra: []const u8) !void {
        self.starts[self.blocks] = self.len;
        self.blocks += 1;
        const b = try block(self.bytes[self.len..], plain, extra, 0);
        self.len += b.len;
        @memcpy(self.plain[self.plain_len..][0..plain.len], plain);
        self.plain_len += plain.len;
    }

    fn addEof(self: *Fixture) void {
        self.starts[self.blocks] = self.len;
        self.blocks += 1;
        @memcpy(self.bytes[self.len..][0..EOF.len], EOF);
        self.len += EOF.len;
    }

    fn stream(self: *const Fixture) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn standard() !*Fixture {
    const f = try std.testing.allocator.create(Fixture);
    f.* = .{};
    var text: [60000]u8 = undefined;
    for (&text, 0..) |*b, i| b.* = "ACGT\n"[(i * 7 + i / 13) % 5];
    try f.add(text[0..60000], "");
    try f.add("second block", "XY\x03\x00abc");
    // An empty block that is not the EOF marker: the extra subfield changes its header.
    try f.add("", "ZZ\x00\x00");
    f.addEof();
    return f;
}

fn decode(reader: *bgzf.Reader, bytes: []const u8, chunk: usize, options: bgzf.ReaderOptions, expected: []const u8) !bgzf.Summary {
    var buffer: [32]u8 = undefined;
    var source = support.Source.init(bytes, &buffer, chunk);
    var oracle = std.Io.Reader.fixed(expected);
    var scratch: [13]u8 = undefined;
    var sink = support.Sink{ .output = &scratch, .oracle = &oracle, .max_drain = 7 };
    const summary = try reader.decompress(&source.reader, &sink.writer, options);
    try std.testing.expect(!sink.mismatch);
    try std.testing.expectEqual(expected.len, sink.count);
    try std.testing.expectEqual(@as(u64, expected.len), summary.bytes);
    return summary;
}

test "[integration] - [bgzf reader]: blocks decode through short I/O and report the EOF marker" {
    const f = try standard();
    defer std.testing.allocator.destroy(f);
    const reader = try std.testing.allocator.create(bgzf.Reader);
    defer std.testing.allocator.destroy(reader);
    for ([_]usize{ 1, 7, 4099 }) |chunk| {
        const summary = try decode(reader, f.stream(), chunk, .{}, f.plain[0..f.plain_len]);
        try std.testing.expectEqual(@as(u64, 4), summary.blocks);
        try std.testing.expect(summary.eof_marker);
    }
    const eof_only = try decode(reader, EOF, 1, .{ .require_eof_marker = true }, "");
    try std.testing.expect(eof_only.eof_marker);
    var gzip_decoder: zipir.Decompressor(.gzip) = undefined;
    var fixed = std.Io.Reader.fixed(f.stream());
    var discard: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expectEqual(@as(u64, f.plain_len), try gzip_decoder.decompress(&fixed, &discard.writer, .{}));
}

test "[failure] - [bgzf reader]: structure, size, and end-of-file errors are documented" {
    const f = try standard();
    defer std.testing.allocator.destroy(f);
    const reader = try std.testing.allocator.create(bgzf.Reader);
    defer std.testing.allocator.destroy(reader);
    const plain = f.plain[0..f.plain_len];
    const no_eof = f.stream()[0 .. f.len - EOF.len];
    const summary = try decode(reader, no_eof, 5, .{}, plain);
    try std.testing.expect(!summary.eof_marker);
    try std.testing.expectError(error.MissingEofMarker, decode(reader, no_eof, 5, .{ .require_eof_marker = true }, plain));
    var bytes: [70000]u8 = undefined;
    for ([_]i32{ -1, 1 }) |delta| {
        const bad = try block(&bytes, "size field off by one", "", delta);
        try std.testing.expectError(error.BlockSizeMismatch, decode(reader, bad, 3, .{}, "size field off by one"));
    }
    var gzip_member: [64]u8 = undefined;
    var plain_reader = std.Io.Reader.fixed("A");
    var member_writer = std.Io.Writer.fixed(&gzip_member);
    const encoder = try std.testing.allocator.create(zipir.Compressor(.gzip));
    defer std.testing.allocator.destroy(encoder);
    _ = try encoder.compress(&plain_reader, &member_writer, .{});
    try std.testing.expectError(error.NotBgzf, decode(reader, member_writer.buffered(), 3, .{}, "A"));
    for (1..f.starts[1]) |cut| try std.testing.expectError(error.Truncated, decode(reader, f.stream()[0..cut], 11, .{}, plain));
    var trailing: [140010]u8 = undefined;
    @memcpy(trailing[0..f.len], f.stream());
    @memcpy(trailing[f.len..][0..4], "junk");
    try std.testing.expectError(error.TrailingData, decode(reader, trailing[0 .. f.len + 4], 9, .{}, plain));
    _ = try decode(reader, trailing[0 .. f.len + 4], 9, .{ .trailing_data = .leave }, plain);
}

test "[failure] - [bgzf reader]: a block decoding past 65536 bytes is too large whatever its ISIZE claims" {
    const reader = try std.testing.allocator.create(bgzf.Reader);
    defer std.testing.allocator.destroy(reader);
    const zeros = try std.testing.allocator.alloc(u8, 65537);
    defer std.testing.allocator.free(zeros);
    @memset(zeros, 0);
    var bytes: [70000]u8 = undefined;
    const big = try block(&bytes, zeros, "", 0);
    try std.testing.expectError(error.BlockTooLarge, decode(reader, big, 4096, .{}, zeros));
    try std.testing.expectError(error.OutputLimitExceeded, decode(reader, big, 4096, .{ .max_output_bytes = 100 }, zeros));
    var out: [bgzf.MAX_BLOCK]u8 = undefined;
    var decoder: bgzf.BlockDecoder = undefined;
    try std.testing.expectError(error.BlockTooLarge, decoder.decodeBlock(big, &out));
}

test "[failure] - [bgzf reader]: an extra subfield that overruns XLEN is BadHeader in every reader" {
    const reader = try std.testing.allocator.create(bgzf.Reader);
    defer std.testing.allocator.destroy(reader);
    var bytes: [70000]u8 = undefined;
    var out: [bgzf.MAX_BLOCK]u8 = undefined;
    var decoder: bgzf.BlockDecoder = undefined;
    // After the 4-byte `XY` head, XLEN leaves 8 bytes: 9 overruns them, and 5 leaves 3, too few for a subfield.
    for ([_][]const u8{ "XY\x09\x00ab", "XY\x05\x00ab" }) |extra| {
        const bad = try block(&bytes, "subfield", extra, 0);
        try std.testing.expectError(error.BadHeader, decode(reader, bad, 3, .{}, "subfield"));
        try std.testing.expectError(error.BadHeader, decoder.decodeBlock(bad, &out));
        var buffer: [16]u8 = undefined;
        var source = support.Source.init(bad, &buffer, 3);
        var scanner = bgzf.scan(&source.reader, .{});
        try std.testing.expectError(error.BadHeader, scanner.next());
    }
}

test "[property] - [bgzf scan]: blocks, sizes, the EOF marker, and trailing data match the built stream without decoding" {
    const f = try standard();
    defer std.testing.allocator.destroy(f);
    const sizes = [_]u32{ 60000, 12, 0, 0 };
    var buffer: [16]u8 = undefined;
    var source = support.Source.init(f.stream(), &buffer, 3);
    var scanner = bgzf.scan(&source.reader, .{ .require_eof_marker = true });
    var i: usize = 0;
    while (try scanner.next()) |b| : (i += 1) {
        try std.testing.expectEqual(f.starts[i], b.coffset);
        const end = if (i + 1 < f.blocks) f.starts[i + 1] else f.len;
        try std.testing.expectEqual(end - f.starts[i], b.size);
        try std.testing.expectEqual(sizes[i], b.data_size);
    }
    try std.testing.expectEqual(f.blocks, i);
    try std.testing.expect(scanner.eof_marker);
    source = support.Source.init(f.stream()[0 .. f.len - EOF.len], &buffer, 5);
    scanner = bgzf.scan(&source.reader, .{ .require_eof_marker = true });
    while (scanner.next()) |b| {
        if (b == null) return error.MarkerNotRequired;
    } else |err| try std.testing.expectEqual(error.MissingEofMarker, err);
    source = support.Source.init(f.stream()[0 .. f.len - 1], &buffer, 5);
    scanner = bgzf.scan(&source.reader, .{});
    while (scanner.next()) |b| {
        if (b == null) return error.TruncationAccepted;
    } else |err| try std.testing.expectEqual(error.Truncated, err);
    var trailing: [140010]u8 = undefined;
    @memcpy(trailing[0..f.len], f.stream());
    @memcpy(trailing[f.len..][0..4], "junk");
    for ([_]usize{ 1, 4 }) |junk| {
        source = support.Source.init(trailing[0 .. f.len + junk], &buffer, 5);
        scanner = bgzf.scan(&source.reader, .{ .trailing_data = .leave });
        i = 0;
        while (try scanner.next()) |_| i += 1;
        try std.testing.expectEqual(f.blocks, i);
        source = support.Source.init(trailing[0 .. f.len + junk], &buffer, 5);
        scanner = bgzf.scan(&source.reader, .{});
        while (scanner.next()) |b| {
            if (b == null) return error.TrailingDataAccepted;
        } else |err| try std.testing.expectEqual(error.TrailingData, err);
    }
}

test "[property] - [bgzf block decoder]: every block decoded alone concatenates to the stream's output" {
    const f = try standard();
    defer std.testing.allocator.destroy(f);
    const decoder = try std.testing.allocator.create(bgzf.BlockDecoder);
    defer std.testing.allocator.destroy(decoder);
    var out: [bgzf.MAX_BLOCK]u8 = undefined;
    var at: usize = 0;
    for (0..f.blocks) |i| {
        const end = if (i + 1 < f.blocks) f.starts[i + 1] else f.len;
        const n = try decoder.decodeBlock(f.bytes[f.starts[i]..end], &out);
        try std.testing.expectEqualSlices(u8, f.plain[at..][0..n], out[0..n]);
        at += n;
    }
    try std.testing.expectEqual(f.plain_len, at);
    try std.testing.expectError(error.BlockSizeMismatch, decoder.decodeBlock(f.bytes[0 .. f.starts[1] + 1], &out));
}

test "[property] - [bgzf reader]: reads at every block start and inside blocks match the full output" {
    const io = std.testing.io;
    const f = try standard();
    defer std.testing.allocator.destroy(f);
    const reader = try std.testing.allocator.create(bgzf.Reader);
    defer std.testing.allocator.destroy(reader);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.gz", .data = f.stream() });
    const file = try tmp.dir.openFile(io, "f.gz", .{});
    defer file.close(io);
    var buffer: [64]u8 = undefined;
    var source = file.reader(io, &buffer);
    const plain = f.plain[0..f.plain_len];
    const block_plain = [_]u64{ 0, 60000, 60012, 60012 };
    var out: [70000]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(1616);
    for (0..200) |k| {
        const b = k % 2;
        const uoffset: u16 = if (b == 0) rng.random().uintAtMost(u16, 60000) else rng.random().uintAtMost(u16, 12);
        const length = rng.random().uintAtMost(u64, 70000);
        var writer = std.Io.Writer.fixed(&out);
        const n = try reader.readAt(&source, .{ .coffset = @intCast(f.starts[b]), .uoffset = uoffset }, &writer, length);
        const from = block_plain[b] + uoffset;
        try std.testing.expectEqual(@min(length, plain.len - from), n);
        try std.testing.expectEqualSlices(u8, plain[from..][0..n], writer.buffered());
    }
    var sink: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expectError(error.BadVirtualOffset, reader.readAt(&source, .{ .coffset = @intCast(f.starts[1]), .uoffset = 13 }, &sink.writer, 1));
    try std.testing.expectError(error.BadVirtualOffset, reader.readAt(&source, .{ .coffset = 5, .uoffset = 0 }, &sink.writer, 1));
    try std.testing.expectError(error.BadVirtualOffset, reader.readAt(&source, .{ .coffset = @intCast(f.len), .uoffset = 0 }, &sink.writer, 1));
}

test "[failure] - [bgzf reader]: a read stops after its range, so damage in a later block fails only reads that reach it" {
    const io = std.testing.io;
    const f = try standard();
    defer std.testing.allocator.destroy(f);
    const reader = try std.testing.allocator.create(bgzf.Reader);
    defer std.testing.allocator.destroy(reader);
    // The second block's stored CRC-32 no longer matches its data.
    f.bytes[f.starts[2] - 8] ^= 1;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.gz", .data = f.stream() });
    const file = try tmp.dir.openFile(io, "f.gz", .{});
    defer file.close(io);
    var buffer: [64]u8 = undefined;
    var source = file.reader(io, &buffer);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expectEqual(@as(u64, 60000), try reader.readAt(&source, .{ .coffset = 0, .uoffset = 0 }, &sink.writer, 60000));
    try std.testing.expectEqual(@as(u64, 10), try reader.readAt(&source, .{ .coffset = 0, .uoffset = 59990 }, &sink.writer, 10));
    try std.testing.expectError(error.CrcMismatch, reader.readAt(&source, .{ .coffset = 0, .uoffset = 59990 }, &sink.writer, 11));
}

test "[property] - [bgzf reader]: bounded bit flips and truncations end in success or a documented error" {
    const f = try standard();
    defer std.testing.allocator.destroy(f);
    const reader = try std.testing.allocator.create(bgzf.Reader);
    defer std.testing.allocator.destroy(reader);
    const small = f.stream()[f.starts[1]..];
    const mutated = try std.testing.allocator.dupe(u8, small);
    defer std.testing.allocator.free(mutated);
    var rng = std.Random.DefaultPrng.init(1617);
    var scratch: [64]u8 = undefined;
    for (0..3000) |k| {
        @memcpy(mutated, small);
        mutated[rng.random().uintLessThan(usize, mutated.len)] ^= @as(u8, 1) << rng.random().int(u3);
        const input = if (k % 3 == 0) mutated[0..rng.random().uintLessThan(usize, mutated.len)] else mutated;
        var buffer: [32]u8 = undefined;
        var source = support.Source.init(input, &buffer, 7);
        var sink = support.Sink{ .output = &scratch };
        if (reader.decompress(&source.reader, &sink.writer, .{ .max_output_bytes = 1 << 20 })) |summary| {
            try std.testing.expect(summary.bytes <= 1 << 20);
        } else |err| if (err == error.WriteFailed or err == error.ReadFailed) return err;
        var scan_buffer: [16]u8 = undefined;
        var scan_source = support.Source.init(input, &scan_buffer, 7);
        var scanner = bgzf.scan(&scan_source.reader, .{});
        while (scanner.next() catch null) |_| {}
    }
}

// --- Writing ---

fn compress(writer: *bgzf.Writer, plain: []const u8, options: bgzf.WriterOptions, chunk: usize, out: []u8) ![]u8 {
    var buffer: [16]u8 = undefined;
    var source = support.Source.init(plain, &buffer, chunk);
    var sink = std.Io.Writer.fixed(out);
    writer.start(&sink, options);
    try writer.write(&source.reader);
    const totals = try writer.finish();
    try std.testing.expectEqual(@as(u64, plain.len), totals.uncompressed);
    try std.testing.expectEqual(@as(u64, sink.end), totals.compressed);
    return sink.buffered();
}

fn blockSizes(stream: []const u8, sizes: []u32) ![]u32 {
    var reader = std.Io.Reader.fixed(stream);
    var scanner = bgzf.scan(&reader, .{ .require_eof_marker = true });
    var n: usize = 0;
    while (try scanner.next()) |b| : (n += 1) sizes[n] = b.data_size;
    return sizes[0..n];
}

test "[edge] - [bgzf writer]: empty input is exactly the EOF marker, and a full random block fits" {
    const writer = try std.testing.allocator.create(bgzf.Writer);
    defer std.testing.allocator.destroy(writer);
    var out: [140000]u8 = undefined;
    try std.testing.expectEqualSlices(u8, EOF, try compress(writer, "", .{}, 1, &out));
    var plain: [bgzf.BLOCK_INPUT]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(1717);
    rng.random().bytes(&plain);
    for ([_]zipir.gzip.CompressOptions{ .{ .level = .fast }, .{}, .{ .level = .dense } }) |options| {
        const stream = try compress(writer, &plain, .{ .level = options.level }, 4099, &out);
        var sizes: [4]u32 = undefined;
        try std.testing.expectEqualSlices(u32, &.{ bgzf.BLOCK_INPUT, 0 }, try blockSizes(stream, &sizes));
        try std.testing.expect(stream.len - EOF.len <= 65317);
    }
}

test "[property] - [bgzf writer]: output decodes with the BGZF and gzip readers at every level and block edge" {
    const writer = try std.testing.allocator.create(bgzf.Writer);
    defer std.testing.allocator.destroy(writer);
    const reader = try std.testing.allocator.create(bgzf.Reader);
    defer std.testing.allocator.destroy(reader);
    const plain = try std.testing.allocator.alloc(u8, 200000);
    defer std.testing.allocator.free(plain);
    for (plain, 0..) |*b, i| b.* = "ACGTN\n"[(i * i / 7 + i) % 6];
    const out = try std.testing.allocator.alloc(u8, 260000);
    defer std.testing.allocator.free(out);
    for ([_]bgzf.Split{ .fill, .lines }) |split| {
        for ([_]usize{ 1, 65279, 65280, 65281, 130560, 130561, 200000 }) |n| {
            const stream = try compress(writer, plain[0..n], .{ .split = split, .level = .fast }, 997, out);
            const summary = try decode(reader, stream, 4099, .{ .require_eof_marker = true }, plain[0..n]);
            try std.testing.expect(summary.eof_marker);
            var gzip_decoder: zipir.Decompressor(.gzip) = undefined;
            var fixed = std.Io.Reader.fixed(stream);
            var discard: std.Io.Writer.Discarding = .init(&.{});
            try std.testing.expectEqual(@as(u64, n), try gzip_decoder.decompress(&fixed, &discard.writer, .{}));
        }
    }
}

test "[property] - [bgzf writer]: splitter plus block encoder writes exactly what the writer writes" {
    const writer = try std.testing.allocator.create(bgzf.Writer);
    defer std.testing.allocator.destroy(writer);
    const encoder = try std.testing.allocator.create(bgzf.BlockEncoder);
    defer std.testing.allocator.destroy(encoder);
    const plain = try std.testing.allocator.alloc(u8, 300000);
    defer std.testing.allocator.free(plain);
    var rng = std.Random.DefaultPrng.init(1718);
    for (plain) |*b| b.* = if (rng.random().uintLessThan(u8, 40) == 0) '\n' else 'a' + rng.random().uintLessThan(u8, 4);
    @memset(plain[100000..180000], 'x');
    @memcpy(plain[0..12], "#h1\n@h2\n#h3\n");
    const out = try std.testing.allocator.alloc(u8, 400000);
    defer std.testing.allocator.free(out);
    const parallel = try std.testing.allocator.alloc(u8, 400000);
    defer std.testing.allocator.free(parallel);
    var encoded: [bgzf.MAX_BLOCK]u8 = undefined;
    for ([_]bgzf.Split{ .fill, .lines }) |split| {
        const stream = try compress(writer, plain, .{ .split = split }, 65536, out);
        var splitter: bgzf.BlockSplitter = .init(split);
        var at: usize = 0;
        var len: usize = 0;
        while (splitter.next(plain[at..], true)) |n| : (at += n) {
            const size = encoder.compressBlock(plain[at..][0..n], &encoded, .even);
            @memcpy(parallel[len..][0..size], encoded[0..size]);
            len += size;
        }
        @memcpy(parallel[len..][0..EOF.len], EOF);
        try std.testing.expectEqualSlices(u8, stream, parallel[0 .. len + EOF.len]);
    }
}

test "[unit] - [bgzf splitter]: line mode gives header lines their own blocks and ends blocks after a newline" {
    var sizes: [8]usize = undefined;
    const cases = .{
        .{ "#one\n#two\nrow 1\nrow 2\n", &[_]usize{ 10, 12 } },
        .{ "@read\nACGT\n+\nIIII\n", &[_]usize{ 6, 12 } },
        .{ "plain text without a final newline", &[_]usize{34} },
        .{ "a\nb", &[_]usize{ 2, 1 } },
    };
    inline for (cases) |case| {
        var splitter: bgzf.BlockSplitter = .init(.lines);
        var at: usize = 0;
        var n: usize = 0;
        while (splitter.next(case[0][at..], true)) |len| : (at += len) {
            sizes[n] = len;
            n += 1;
        }
        try std.testing.expectEqualSlices(usize, case[1], sizes[0..n]);
    }
    var fill: bgzf.BlockSplitter = .init(.fill);
    try std.testing.expectEqual(@as(?usize, null), fill.next("short", false));
    try std.testing.expectEqual(@as(?usize, 5), fill.next("short", true));
    var lines: bgzf.BlockSplitter = .init(.lines);
    try std.testing.expectEqual(@as(?usize, null), lines.next("#h\nrow\n", false));
    try std.testing.expectEqual(@as(?usize, 3), lines.next("#h\nrow\n", true));
}

test "[failure] - [bgzf writer]: flush ends a block early and write failures propagate" {
    const writer = try std.testing.allocator.create(bgzf.Writer);
    defer std.testing.allocator.destroy(writer);
    var out: [4096]u8 = undefined;
    var sink = std.Io.Writer.fixed(&out);
    writer.start(&sink, .{});
    var first = std.Io.Reader.fixed("record one;");
    try writer.write(&first);
    try writer.flush();
    var second = std.Io.Reader.fixed("record two;");
    try writer.write(&second);
    _ = try writer.finish();
    var sizes: [4]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 11, 11, 0 }, try blockSizes(sink.buffered(), &sizes));
    var small: [20]u8 = undefined;
    var failing = std.Io.Writer.fixed(&small);
    writer.start(&failing, .{});
    var input = std.Io.Reader.fixed("does not fit in twenty bytes once compressed");
    try writer.write(&input);
    try std.testing.expectError(error.WriteFailed, writer.finish());
}

// --- Indexes ---

test "[property] - [bgzf index]: entries built by scan and while writing agree and follow htslib's rule" {
    const writer = try std.testing.allocator.create(bgzf.Writer);
    defer std.testing.allocator.destroy(writer);
    const plain = try std.testing.allocator.alloc(u8, 200000);
    defer std.testing.allocator.free(plain);
    for (plain, 0..) |*b, i| b.* = @truncate(i * 31 / 7);
    const out = try std.testing.allocator.alloc(u8, 260000);
    defer std.testing.allocator.free(out);
    var written_storage: [8]bgzf.IndexEntry = undefined;
    var written: bgzf.IndexBuilder = .init(&written_storage);
    var sink = std.Io.Writer.fixed(out);
    writer.start(&sink, .{ .index = &written });
    var source = std.Io.Reader.fixed(plain);
    try writer.write(&source);
    _ = try writer.finish();
    const expected = [_]bgzf.IndexEntry{ .{ .coffset = 0, .uoffset = 65280 }, .{ .coffset = 0, .uoffset = 130560 }, .{ .coffset = 0, .uoffset = 195840 } };
    try std.testing.expectEqual(expected.len, written.len);
    var scanned_storage: [8]bgzf.IndexEntry = undefined;
    var scanned: bgzf.IndexBuilder = .init(&scanned_storage);
    var reader = std.Io.Reader.fixed(sink.buffered());
    var scanner = bgzf.scan(&reader, .{});
    while (try scanner.next()) |b| try scanned.add(b.coffset, b.data_size);
    try std.testing.expectEqualSlices(bgzf.IndexEntry, scanned.slice(), written.slice());
    for (expected, written.slice()) |e, w| try std.testing.expectEqual(e.uoffset, w.uoffset);
    var full: bgzf.IndexBuilder = .init(written_storage[0..2]);
    try full.add(0, 5);
    try full.add(28, 5);
    try full.add(56, 0);
    try full.add(84, 5);
    try std.testing.expectError(error.IndexFull, full.add(112, 5));
}

test "[failure] - [bgzf index]: a written index reads back, and damaged indexes are BadIndex" {
    const entries = [_]bgzf.IndexEntry{ .{ .coffset = 100, .uoffset = 65280 }, .{ .coffset = 250, .uoffset = 130560 } };
    var bytes: [40]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try bgzf.writeIndex(&writer, &entries);
    try std.testing.expectEqual(@as(usize, 40), writer.end);
    var reader = std.Io.Reader.fixed(&bytes);
    var index = try bgzf.IndexReader.init(&reader, 300);
    for (entries) |e| try std.testing.expectEqual(e, (try index.next()).?);
    try std.testing.expectEqual(@as(?bgzf.IndexEntry, null), try index.next());
    const Case = struct { bytes: []const u8, file_size: u64 };
    var backwards = bytes;
    std.mem.writeInt(u64, backwards[24..32], 50, .little);
    var trailing: [41]u8 = undefined;
    @memcpy(trailing[0..40], &bytes);
    trailing[40] = 0;
    for ([_]Case{ .{ .bytes = &backwards, .file_size = 300 }, .{ .bytes = &bytes, .file_size = 250 }, .{ .bytes = bytes[0..30], .file_size = 300 }, .{ .bytes = bytes[0..5], .file_size = 300 }, .{ .bytes = &trailing, .file_size = 300 } }) |case| {
        var r = std.Io.Reader.fixed(case.bytes);
        const result = blk: {
            var ix = bgzf.IndexReader.init(&r, case.file_size) catch |err| break :blk err;
            while (ix.next() catch |err| break :blk err) |_| {}
            break :blk error.Accepted;
        };
        try std.testing.expectEqual(error.BadIndex, result);
    }
}

test "[property] - [bgzf reader]: reads at uncompressed offsets through a full, sparse, or empty index match the full output" {
    const io = std.testing.io;
    const writer = try std.testing.allocator.create(bgzf.Writer);
    defer std.testing.allocator.destroy(writer);
    const decoder = try std.testing.allocator.create(bgzf.Reader);
    defer std.testing.allocator.destroy(decoder);
    const plain = try std.testing.allocator.alloc(u8, 300000);
    defer std.testing.allocator.free(plain);
    var rng = std.Random.DefaultPrng.init(1818);
    for (plain) |*b| b.* = "ACGT\n"[rng.random().uintLessThan(u8, 5)];
    const out = try std.testing.allocator.alloc(u8, 400000);
    defer std.testing.allocator.free(out);
    var storage: [8]bgzf.IndexEntry = undefined;
    var index: bgzf.IndexBuilder = .init(&storage);
    var sink = std.Io.Writer.fixed(out);
    writer.start(&sink, .{ .split = .lines, .index = &index, .level = .fast });
    var source = std.Io.Reader.fixed(plain);
    try writer.write(&source);
    _ = try writer.finish();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.gz", .data = sink.buffered() });
    const file = try tmp.dir.openFile(io, "f.gz", .{});
    defer file.close(io);
    var buffer: [64]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const got = try std.testing.allocator.alloc(u8, 70000);
    defer std.testing.allocator.free(got);
    for (0..100) |k| {
        const at = if (k < 8) (if (k < index.len) index.slice()[k].uoffset else plain.len) else rng.random().uintAtMost(u64, plain.len);
        const length = rng.random().uintAtMost(u64, 70000);
        var w = std.Io.Writer.fixed(got);
        const n = try decoder.readAtUncompressed(&reader, index.slice(), at, &w, length);
        try std.testing.expectEqual(@min(length, plain.len - at), n);
        try std.testing.expectEqualSlices(u8, plain[@intCast(at)..][0..@intCast(n)], w.buffered());
    }
    // Starting blocks earlier than the offset's own, the skip spans whole blocks.
    for ([_][]const bgzf.IndexEntry{ index.slice()[1..2], &.{} }) |sparse| {
        for (0..20) |_| {
            const at = rng.random().uintAtMost(u64, plain.len);
            const length = rng.random().uintAtMost(u64, 70000);
            var w = std.Io.Writer.fixed(got);
            const n = try decoder.readAtUncompressed(&reader, sparse, at, &w, length);
            try std.testing.expectEqual(@min(length, plain.len - at), n);
            try std.testing.expectEqualSlices(u8, plain[@intCast(at)..][0..@intCast(n)], w.buffered());
        }
    }
}

test "[unit] - [bgzf]: the public error set names exactly the documented errors" {
    const expected = [_][]const u8{ "BadBlock", "BadBlockSize", "BadDistance", "BadHeader", "BadIndex", "BadHuffman", "BadStored", "BadSymbol", "BadVirtualOffset", "BlockSizeMismatch", "BlockTooLarge", "CrcMismatch", "HeaderCrcMismatch", "InputBufferTooSmall", "IsizeMismatch", "MissingEofMarker", "NotBgzf", "OutputLimitExceeded", "ReadFailed", "ReservedFlag", "TrailingData", "Truncated", "UnsupportedMethod", "WriteFailed" };
    try support.expectErrorNames(bgzf.Error, &expected);
}
