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

test "[unit] - [bgzf]: the public error set names exactly the documented errors" {
    const expected = [_][]const u8{ "BadBlock", "BadBlockSize", "BadDistance", "BadHeader", "BadHuffman", "BadStored", "BadSymbol", "BadVirtualOffset", "BlockSizeMismatch", "BlockTooLarge", "CrcMismatch", "HeaderCrcMismatch", "InputBufferTooSmall", "IsizeMismatch", "MissingEofMarker", "NotBgzf", "OutputLimitExceeded", "ReadFailed", "ReservedFlag", "TrailingData", "Truncated", "UnsupportedMethod", "WriteFailed" };
    try support.expectErrorNames(bgzf.Error, &expected);
}
