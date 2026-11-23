//! Coverage-guided fuzz targets over zipir's public parsers and codecs. Without `--fuzz` each target runs its seed
//! inputs once; with `-Doptimize=ReleaseSafe --fuzz=N` it runs a campaign, and a found input is saved under
//! `.zig-cache/f/` while the run still exits 0, so `fuzz.sh` checks for it. Properties: a decoder given any bytes,
//! read sizes, and buffer sizes ends in success within its output limit or a documented error; the slice decoder and
//! the reader agree; a BGZF block decodes as its gzip member does (pair tables against none); zipir and std's flate
//! give the same bytes where both decode; every compressor round-trips. `-Dplanted` builds only a target with a planted
//! crash, which `fuzz.sh --self-check` requires a campaign to find.

const std = @import("std");
const zipir = @import("zipir");
const support = @import("support");
const fixtures = @import("fixtures");
const planted_build = @import("fuzz_options").planted;

const Smith = std.testing.Smith;
const LIMIT = 1 << 20;
const bgzf = zipir.bgzf;

const STREAMS = &[_][]const u8{
    fixtures.short6,
    fixtures.long_codes,
    fixtures.repeat_zero,
    fixtures.fixed_codes,
    fixtures.empty_single,
    fixtures.final_stored,
};

fn input(smith: *Smith, buffer: []u8) []u8 {
    return buffer[0..smith.slice(buffer)];
}

fn readerShape(smith: *Smith) [2]usize {
    const sizes = [_]usize{ 16, 17, 64, 4096 };
    return .{ sizes[smith.index(sizes.len)], @as(usize, smith.valueRangeAtMost(u32, 1, 64)) };
}

fn decodeAny(comptime Decoder: type, decoder: *Decoder, bytes: []const u8, smith: *Smith) !void {
    const shape = readerShape(smith);
    var buffer: [4096]u8 = undefined;
    var source = support.Source.init(bytes, buffer[0..shape[0]], shape[1]);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    if (support.decompressAll(decoder, &source.reader, &sink.writer, .{ .max_output_bytes = LIMIT })) |n| {
        try std.testing.expect(n <= LIMIT);
    } else |err| try support.expectDataError(Decoder.DecompressError, err);
}

fn decoders(_: void, smith: *Smith) anyerror!void {
    var buffer: [8192]u8 = undefined;
    const bytes = input(smith, &buffer);
    switch (smith.index(4)) {
        0 => {
            const decoder = try std.testing.allocator.create(zipir.gzip.Decompressor);
            defer std.testing.allocator.destroy(decoder);
            try decodeAny(zipir.gzip.Decompressor, decoder, bytes, smith);
        },
        1 => {
            const decoder = try std.testing.allocator.create(zipir.zlib.Decompressor);
            defer std.testing.allocator.destroy(decoder);
            try decodeAny(zipir.zlib.Decompressor, decoder, bytes, smith);
        },
        2 => {
            const decoder = try std.testing.allocator.create(zipir.deflate.Decompressor);
            defer std.testing.allocator.destroy(decoder);
            try decodeAny(zipir.deflate.Decompressor, decoder, bytes, smith);
        },
        else => {
            const decoder = try std.testing.allocator.create(bgzf.Decompressor);
            defer std.testing.allocator.destroy(decoder);
            try decodeAny(bgzf.Decompressor, decoder, bytes, smith);
        },
    }
}

test "[fuzz] - [decompressors]: any bytes end within the limit or in a documented error" {
    try std.testing.fuzz({}, decoders, .{ .corpus = STREAMS ++ &[_][]const u8{ fixtures.zlib_a, fixtures.raw_a, &bgzf.EOF_MARKER } });
}

fn slices(_: void, smith: *Smith) anyerror!void {
    var buffer: [8192]u8 = undefined;
    const bytes = input(smith, &buffer);
    const room = @as(usize, smith.valueRangeAtMost(u32, 0, 20_000));
    const output = try std.testing.allocator.alloc(u8, room);
    defer std.testing.allocator.free(output);
    const scratch = try std.testing.allocator.alloc(u8, room);
    defer std.testing.allocator.free(scratch);
    inline for (.{ zipir.zlib, zipir.deflate }) |Namespace| {
        const slicer = try std.testing.allocator.create(Namespace.SliceDecoder);
        defer std.testing.allocator.destroy(slicer);
        const reader = try std.testing.allocator.create(Namespace.Decompressor);
        defer std.testing.allocator.destroy(reader);
        try support.expectSliceMatchesReader(Namespace, slicer, reader, bytes, output, scratch);
    }
}

test "[fuzz] - [slice decoders]: any bytes decode as the reader decodes them" {
    try std.testing.fuzz({}, slices, .{ .corpus = &.{ fixtures.zlib_a, fixtures.raw_a } });
}

fn blocks(_: void, smith: *Smith) anyerror!void {
    const plain = try std.testing.allocator.alloc(u8, bgzf.BLOCK_INPUT);
    defer std.testing.allocator.free(plain);
    const encoder = try std.testing.allocator.create(bgzf.BlockEncoder);
    defer std.testing.allocator.destroy(encoder);
    const decoder = try std.testing.allocator.create(bgzf.BlockDecoder);
    defer std.testing.allocator.destroy(decoder);
    const gzip = try std.testing.allocator.create(zipir.gzip.Decompressor);
    defer std.testing.allocator.destroy(gzip);
    const block = try std.testing.allocator.create([bgzf.MAX_BLOCK]u8);
    defer std.testing.allocator.destroy(block);
    const out = try std.testing.allocator.create([bgzf.MAX_BLOCK]u8);
    defer std.testing.allocator.destroy(out);
    const kept = try std.testing.allocator.create([bgzf.MAX_BLOCK]u8);
    defer std.testing.allocator.destroy(kept);

    const text = plain[0..smith.slice(plain[0..4096])];
    var len = text.len;
    for (0..@as(usize, smith.valueRangeAtMost(u32, 0, 15))) |_| {
        if (len + text.len > plain.len) break;
        @memcpy(plain[len..][0..text.len], text);
        len += text.len;
    }
    const presets = [_]zipir.Preset{ .fast, .even, .dense };
    const size = encoder.compressBlock(plain[0..len], block, presets[smith.index(presets.len)]);
    for (0..@as(usize, smith.valueRangeAtMost(u32, 0, 3))) |_| {
        block[smith.index(size)] ^= @as(u8, 1) << smith.value(u3);
    }
    const bytes = block[0..size];

    @memset(kept, 0xa5);
    const into = decoder.decodeBlockInto(bytes, out);
    const copied = decoder.decodeBlock(bytes, kept);
    if (into) |n| {
        try std.testing.expectEqual(n, try copied);
        try std.testing.expectEqualSlices(u8, out[0..n], kept[0..n]);
    } else |err| {
        try std.testing.expectError(err, copied);
        for (kept) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
        try support.expectDataError(bgzf.DecompressError, err);
    }

    var source = std.Io.Reader.fixed(bytes);
    var sink = std.Io.Writer.fixed(kept);
    const member = support.decompressAll(gzip, &source, &sink, .{ .max_output_bytes = bgzf.MAX_BLOCK });
    if (into) |n| {
        try std.testing.expectEqual(@as(u64, n), try member);
        try std.testing.expectEqualSlices(u8, out[0..n], sink.buffered());
    } else |err| switch (err) {
        error.BlockSizeMismatch, error.BadBlockSize, error.NotBgzf, error.BlockTooLarge, error.BadHeader => {},
        else => if (member) |_| return error.GzipAcceptedWhatBgzfRejected else |_| {},
    }
}

test "[fuzz] - [bgzf blocks]: a block decodes as its gzip member, in both block calls, damaged or not" {
    try std.testing.fuzz({}, blocks, .{ .corpus = &.{ "ACGT\n", "A" ** 300, "" } });
}

fn tables(_: void, smith: *Smith) anyerror!void {
    var plain: [20_000]u8 = undefined;
    const text = plain[0..smith.slice(plain[0..2000])];
    var len = text.len;
    while (len + text.len <= plain.len and text.len != 0 and smith.boolWeighted(1, 3)) {
        @memcpy(plain[len..][0..text.len], text);
        len += text.len;
    }
    const encoder = try std.testing.allocator.create(zipir.deflate.Compressor);
    defer std.testing.allocator.destroy(encoder);
    var stream_buffer: [24_000]u8 = undefined;
    var sink = std.Io.Writer.fixed(&stream_buffer);
    var source = std.Io.Reader.fixed(plain[0..len]);
    const presets = [_]zipir.Preset{ .fast, .even, .dense };
    _ = try support.compressAll(encoder, &source, &sink, .{ .preset = presets[smith.index(presets.len)] });
    const stream = sink.buffered();
    for (0..@as(usize, smith.valueRangeAtMost(u32, 0, 2))) |_| {
        if (stream.len != 0) stream[smith.index(@min(stream.len, 64))] ^= @as(u8, 1) << smith.value(u3);
    }

    const slicer = try std.testing.allocator.create(zipir.deflate.SliceDecoder);
    defer std.testing.allocator.destroy(slicer);
    var ours: [20_000]u8 = undefined;
    const n = slicer.decode(stream, &ours) catch |err| return support.expectDataError(zipir.deflate.SliceError, err);

    var std_input = std.Io.Reader.fixed(stream);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var std_decoder: std.compress.flate.Decompress = .init(&std_input, .raw, &window);
    var theirs: [20_001]u8 = undefined;
    var std_sink = std.Io.Writer.fixed(&theirs);
    const m = std_decoder.reader.streamRemaining(&std_sink) catch return;
    try std.testing.expectEqual(m, n);
    try std.testing.expectEqualSlices(u8, std_sink.buffered(), ours[0..n]);
}

test "[fuzz] - [deflate tables]: zipir and std's flate decode to the same bytes where both succeed" {
    try std.testing.fuzz({}, tables, .{ .corpus = &.{ "ACGT\nACGA\n", "abc" ** 40, "" } });
}

const Visitor = struct {
    pub fn entry(_: *Visitor, _: zipir.tar.Entry) !zipir.tar.Action {
        return .read;
    }
    pub fn data(_: *Visitor, _: []const u8) !void {}
    pub fn entryEnd(_: *Visitor) !void {}
};

fn archives(_: void, smith: *Smith) anyerror!void {
    var buffer: [16_384]u8 = undefined;
    const bytes = input(smith, &buffer);
    var name: [zipir.tar.MAX_NAME + 1]u8 = undefined;
    var link: [zipir.tar.MAX_NAME + 1]u8 = undefined;
    var visitor: Visitor = .{};
    var reader: zipir.tar.Reader(Visitor) = .init(&visitor, .{ .name = &name, .link = &link });
    const split = @as(usize, smith.valueRangeAtMost(u32, 1, 1024));
    var at: usize = 0;
    while (at < bytes.len) : (at += split) {
        reader.writer.writeAll(bytes[at..@min(bytes.len, at + split)]) catch break;
    }
    _ = reader.finish() catch |err| try support.expectDataError(zipir.tar.Error, err);
    readIndex(bytes, smith.value(u32)) catch |err| try support.expectDataError(bgzf.DecompressError, err);
    scanBlocks(bytes) catch |err| try support.expectDataError(bgzf.DecompressError, err);
}

fn readIndex(bytes: []const u8, file_size: u64) !void {
    var source = std.Io.Reader.fixed(bytes);
    var index = try bgzf.IndexReader.init(&source, file_size);
    while (try index.next()) |_| {}
}

fn scanBlocks(bytes: []const u8) !void {
    var source = std.Io.Reader.fixed(bytes);
    var scanner = bgzf.scan(&source, .{});
    while (try scanner.next()) |_| {}
}

test "[fuzz] - [tar, gzi, bgzf scan]: any bytes end in entries or a documented error" {
    try std.testing.fuzz({}, archives, .{ .corpus = &.{ fixtures.tar_ustar, fixtures.tar_pax, &bgzf.EOF_MARKER } });
}

fn roundTrips(_: void, smith: *Smith) anyerror!void {
    var plain: [70_000]u8 = undefined;
    const text = plain[0..smith.slice(plain[0..3000])];
    var len = text.len;
    while (len + text.len <= plain.len and text.len != 0 and smith.boolWeighted(1, 4)) {
        @memcpy(plain[len..][0..text.len], text);
        len += text.len;
    }
    const presets = [_]zipir.Preset{ .fast, .even, .dense };
    const preset = presets[smith.index(presets.len)];
    const chunk = @as(usize, smith.valueRangeAtMost(u32, 1, 70_000));
    const encoded = try std.testing.allocator.alloc(u8, len + len / 8 + 1024);
    defer std.testing.allocator.free(encoded);
    const decoded = try std.testing.allocator.alloc(u8, len + 1);
    defer std.testing.allocator.free(decoded);
    switch (smith.index(4)) {
        inline 0, 1, 2 => |k| {
            const format: zipir.Format = @enumFromInt(k);
            const encoder = try std.testing.allocator.create(zipir.Compressor(format));
            defer std.testing.allocator.destroy(encoder);
            var sink = std.Io.Writer.fixed(encoded);
            try encoder.init(&sink, .{ .preset = preset });
            var at: usize = 0;
            while (at < len) : (at += chunk) try encoder.writer.writeAll(plain[at..@min(len, at + chunk)]);
            try std.testing.expectEqual(@as(u64, len), try encoder.finish());
            const decoder = try std.testing.allocator.create(zipir.Decompressor(format));
            defer std.testing.allocator.destroy(decoder);
            var source = std.Io.Reader.fixed(sink.buffered());
            var out = std.Io.Writer.fixed(decoded);
            try std.testing.expectEqual(@as(u64, len), try support.decompressAll(decoder, &source, &out, .{}));
            try std.testing.expectEqualSlices(u8, plain[0..len], out.buffered());
        },
        else => {
            const encoder = try std.testing.allocator.create(bgzf.Compressor);
            defer std.testing.allocator.destroy(encoder);
            var sink = std.Io.Writer.fixed(encoded);
            try encoder.init(&sink, .{ .preset = preset, .split = if (smith.value(bool)) .lines else .fill });
            var at: usize = 0;
            while (at < len) : (at += chunk) try encoder.writer.writeAll(plain[at..@min(len, at + chunk)]);
            _ = try encoder.finish();
            const decoder = try std.testing.allocator.create(bgzf.Decompressor);
            defer std.testing.allocator.destroy(decoder);
            var source = std.Io.Reader.fixed(sink.buffered());
            var out = std.Io.Writer.fixed(decoded);
            try std.testing.expectEqual(@as(u64, len), try support.decompressAll(decoder, &source, &out, .{}));
            try std.testing.expectEqualSlices(u8, plain[0..len], out.buffered());
        },
    }
}

test "[fuzz] - [compressors]: any plaintext, preset, and write size round-trips in every format" {
    try std.testing.fuzz({}, roundTrips, .{ .corpus = &.{ "ACGT\n" ** 20, "", "\x00\xff" ** 100 } });
}

fn planted(bytes: []const u8) void {
    if (bytes.len >= 3 and bytes[0] == 'B') {
        if (bytes[1] == 'U') {
            if (bytes[2] == 'G') @panic("planted crash found");
        }
    }
}

fn plantedCrash(_: void, smith: *Smith) anyerror!void {
    var buffer: [64]u8 = undefined;
    planted(input(smith, &buffer));
}

test "[fuzz] - [runner]: a planted crash is found, which proves the runner and its coverage work" {
    if (!planted_build) return error.SkipZigTest;
    try std.testing.fuzz({}, plantedCrash, .{ .corpus = &.{"AAA"} });
}
