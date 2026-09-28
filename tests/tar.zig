//! Public tar contracts: reading (entry kinds, names, pax and GNU extensions, end marker, failures) and
//! writing (header formats, round trips through the reader and a compressor, failures).

const std = @import("std");
const support = @import("support.zig");
const zipir = @import("zipir");
const tar = zipir.tar;

const GNU = @embedFile("data/synthetic/tar-gnu.tar");
const PAX = @embedFile("data/synthetic/tar-pax.tar");
const USTAR = @embedFile("data/synthetic/tar-ustar.tar");
const PAX_EXTRA = @embedFile("data/synthetic/tar-pax-extra.tar");
const BASE256 = @embedFile("data/synthetic/tar-base256.tar");

const MTIME = 1700000000;

// Records every visitor call as text: `kind size mode mtime name -> link|` then the data, then `;`.
const Transcript = struct {
    out: std.Io.Writer,
    skip: bool = false,
    fail_on: ?[]const u8 = null,

    pub fn entry(self: *Transcript, e: tar.Entry) !tar.Action {
        if (self.fail_on) |name| if (std.mem.eql(u8, name, e.name)) return error.Stop;
        try self.out.print("{t} {d} {o} {d} {s}", .{ e.kind, e.size, e.mode, e.mtime, e.name });
        if (e.link_name.len != 0) try self.out.print(" -> {s}", .{e.link_name});
        try self.out.writeByte('|');
        return if (self.skip) .skip else .read;
    }

    pub fn data(self: *Transcript, bytes: []const u8) !void {
        try self.out.writeAll(bytes);
    }

    pub fn entryEnd(self: *Transcript) !void {
        try self.out.writeByte(';');
    }
};

const Result = struct { summary: tar.Summary, transcript: []const u8 };

// Feeds `archive` in pieces of `split` bytes, as a decompressor's batches would arrive.
fn read(archive: []const u8, split: usize, visitor: *Transcript, names: tar.Names) !tar.Summary {
    var reader: tar.Reader(Transcript) = .init(visitor, names);
    var at: usize = 0;
    while (at < archive.len) : (at += split) {
        reader.writer.writeAll(archive[at..@min(archive.len, at + split)]) catch return reader.finish();
    }
    return reader.finish();
}

fn transcribe(archive: []const u8, split: usize, storage: []u8) !Result {
    var name: [512]u8 = undefined;
    var link: [512]u8 = undefined;
    var visitor: Transcript = .{ .out = .fixed(storage) };
    const summary = try read(archive, split, &visitor, .{ .name = &name, .link = &link });
    return .{ .summary = summary, .transcript = visitor.out.buffered() };
}

fn binPattern() [1000]u8 {
    var bytes: [1000]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i * 7);
    return bytes;
}

// The staged tree GNU tar archived in `tar-gnu.tar` and `tar-pax.tar`, in archive order.
fn expectedTree(out: *std.Io.Writer) !void {
    const long_name = "d/" ++ "n" ** 120 ++ ".txt";
    const long_link = "t" ** 120;
    try out.print("directory 0 755 {d} d/|;", .{MTIME});
    try out.print("file 6 644 {d} d/a.txt|hello\n;", .{MTIME});
    try out.print("file 1000 644 {d} d/bin|{s};", .{ MTIME, &binPattern() });
    try out.print("file 0 644 {d} d/empty|;", .{MTIME});
    try out.print("fifo 0 644 {d} d/fifo|;", .{MTIME});
    try out.print("hardlink 0 644 {d} d/hard -> d/a.txt|;", .{MTIME});
    try out.print("symlink 0 777 {d} d/longlink -> {s}|;", .{ MTIME, long_link });
    try out.print("file 5 644 {d} {s}|long\n;", .{ MTIME, long_name });
    try out.print("symlink 0 777 {d} d/sym -> a.txt|;", .{MTIME});
}

// A ustar header built independently of the reader, for malformed cases no tool writes.
fn header(block: *[512]u8, name: []const u8, typeflag: u8, size: []const u8) void {
    @memset(block, 0);
    @memcpy(block[0..name.len], name);
    @memcpy(block[100..107], "0000644");
    @memcpy(block[124..][0..size.len], size);
    @memcpy(block[136..147], "14524770400");
    block[156] = typeflag;
    @memcpy(block[257..263], "ustar\x00");
    @memcpy(block[263..265], "00");
    @memset(block[148..156], ' ');
    var sum: u32 = 0;
    for (block) |b| sum += b;
    _ = std.fmt.bufPrint(block[148..155], "{o:0>6}\x00", .{sum}) catch unreachable;
}

test "[integration] - [tar reader]: GNU and pax archives of every kind give GNU tar's listing and the files' bytes" {
    var expected_storage: [8192]u8 = undefined;
    var expected: std.Io.Writer = .fixed(&expected_storage);
    try expectedTree(&expected);
    var storage: [8192]u8 = undefined;
    for ([_][]const u8{ GNU, PAX }) |archive| {
        const result = try transcribe(archive, archive.len, &storage);
        try std.testing.expectEqualStrings(expected.buffered(), result.transcript);
        try std.testing.expectEqual(tar.Summary{ .entries = 9, .end_marker = true }, result.summary);
    }
    const ustar = try transcribe(USTAR, USTAR.len, &storage);
    try std.testing.expectEqualStrings(std.fmt.comptimePrint("file 6 644 {d} d/a.txt|hello\n;symlink 0 777 {d} d/sym -> a.txt|;file 6 644 {d} {s}/{s}|split\n;", .{ MTIME, MTIME, MTIME, "p" ** 60, "q" ** 60 }), ustar.transcript);
}

test "[integration] - [tar reader]: devices, a global header, a pax size, and base-256 numbers read as tarfile wrote them" {
    var storage: [1024]u8 = undefined;
    const extra = try transcribe(PAX_EXTRA, PAX_EXTRA.len, &storage);
    try std.testing.expectEqualStrings(std.fmt.comptimePrint("char_device 0 600 {d} dev/null|;block_device 0 600 {d} dev/sda|;file 6 644 {d} sized.txt|sized\n;", .{ MTIME, MTIME, MTIME }), extra.transcript);
    const base256 = try transcribe(BASE256, BASE256.len, &storage);
    try std.testing.expectEqualStrings("file 8 644 -86400 b256.txt|base256\n;", base256.transcript);
}

test "[integration] - [tar reader]: an archive written through the gzip decoder gives the same visitor calls" {
    const compressor = try std.testing.allocator.create(zipir.Compressor(.gzip));
    defer std.testing.allocator.destroy(compressor);
    const decompressor = try std.testing.allocator.create(zipir.Decompressor(.gzip));
    defer std.testing.allocator.destroy(decompressor);
    var compressed: [PAX.len]u8 = undefined;
    var plain = std.Io.Reader.fixed(PAX);
    var sink: std.Io.Writer = .fixed(&compressed);
    _ = try support.compressAll(compressor, &plain, &sink, .{});
    var storage: [8192]u8 = undefined;
    const direct = try transcribe(PAX, PAX.len, &storage);
    var name: [256]u8 = undefined;
    var link: [256]u8 = undefined;
    var other: [8192]u8 = undefined;
    var visitor: Transcript = .{ .out = .fixed(&other) };
    var reader: tar.Reader(Transcript) = .init(&visitor, .{ .name = &name, .link = &link });
    var buffer: [64]u8 = undefined;
    var source = support.Source.init(sink.buffered(), &buffer, 13);
    _ = try support.decompressAll(decompressor, &source.reader, &reader.writer, .{});
    try std.testing.expectEqual(direct.summary, try reader.finish());
    try std.testing.expectEqualStrings(direct.transcript, visitor.out.buffered());
}

test "[property] - [tar reader]: every split of the input gives the same visitor calls" {
    var storage: [8192]u8 = undefined;
    var expected_storage: [8192]u8 = undefined;
    for ([_][]const u8{ GNU, PAX, PAX_EXTRA }) |archive| {
        const whole = try transcribe(archive, archive.len, &expected_storage);
        for (1..1100) |split| {
            const result = try transcribe(archive, split, &storage);
            try std.testing.expectEqualStrings(whole.transcript, result.transcript);
            try std.testing.expectEqual(whole.summary, result.summary);
        }
    }
}

test "[edge] - [tar reader]: the archive ends at its first zero block, and the end marker is reported, not required" {
    var storage: [1024]u8 = undefined;
    const body = USTAR[0 .. USTAR.len - 1024];
    try std.testing.expectEqual(tar.Summary{ .entries = 3, .end_marker = false }, (try transcribe(body, 512, &storage)).summary);
    try std.testing.expectEqual(tar.Summary{ .entries = 3, .end_marker = false }, (try transcribe(USTAR[0 .. USTAR.len - 512], 512, &storage)).summary);
    try std.testing.expectEqual(tar.Summary{ .entries = 3, .end_marker = false }, (try transcribe(USTAR[0 .. USTAR.len - 100], 512, &storage)).summary);
    // After one zero block GNU tar stops, even when a valid header follows.
    var lone: [USTAR.len]u8 = undefined;
    @memcpy(lone[0..body.len], body);
    @memset(lone[body.len..][0..512], 0);
    header(lone[body.len + 512 ..][0..512], "ghost.txt", '0', "00000000000");
    const result = try transcribe(&lone, 7, &storage);
    try std.testing.expectEqual(tar.Summary{ .entries = 3, .end_marker = false }, result.summary);
    try std.testing.expect(std.mem.find(u8, result.transcript, "ghost") == null);
    try std.testing.expectEqual(tar.Summary{ .entries = 0, .end_marker = false }, (try transcribe("", 1, &storage)).summary);
}

test "[edge] - [tar reader]: kinds without data skip any size their header claims; unknown kinds carry data" {
    var archive: [10 * 512]u8 = @splat(0);
    // GNU tar and tarfile read the block after each of these headers as the next header.
    header(archive[0..512], "dir", '5', "00000001000");
    header(archive[512..1024], "sym", '2', "00000001000");
    header(archive[1024..1536], "old/", 0, "00000000000");
    header(archive[1536..2048], "vendor", 'Z', "00000000003");
    @memcpy(archive[2048..2051], "abc");
    // A GNU long name ends at its NUL even when more bytes follow in its data.
    header(archive[2560..3072], "././@LongLink", 'L', "00000000011");
    @memcpy(archive[3072..3081], "long\x00junk");
    header(archive[3584..4096], "short", '0', "00000000000");
    var storage: [1024]u8 = undefined;
    for ([_]usize{ 1, 100 }) |split| {
        const result = try transcribe(&archive, split, &storage);
        try std.testing.expectEqualStrings(std.fmt.comptimePrint("directory 0 644 {d} dir|;symlink 0 644 {d} sym|;directory 0 644 {d} old/|;other 3 644 {d} vendor|abc;file 0 644 {d} long|;", .{ MTIME, MTIME, MTIME, MTIME, MTIME }), result.transcript);
        try std.testing.expectEqual(tar.Summary{ .entries = 5, .end_marker = true }, result.summary);
    }
}

test "[edge] - [tar reader]: a checksum summed over signed bytes is accepted, as some old writers made them" {
    var archive: [3 * 512]u8 = @splat(0);
    header(archive[0..512], "caf\xe9", '0', "00000000000");
    @memset(archive[148..156], ' ');
    var signed: i32 = 0;
    for (archive[0..512]) |b| signed += @as(i8, @bitCast(b));
    _ = try std.fmt.bufPrint(archive[148..155], "{o:0>6}\x00", .{@as(u32, @intCast(signed))});
    var storage: [256]u8 = undefined;
    const result = try transcribe(&archive, 512, &storage);
    try std.testing.expectEqualStrings(std.fmt.comptimePrint("file 0 644 {d} caf\xe9|;", .{MTIME}), result.transcript);
    archive[0] = 'C';
    try std.testing.expectError(error.BadHeaderChecksum, transcribe(&archive, 512, &storage));
}

test "[unit] - [tar]: isHeader accepts header blocks with a right checksum and nothing else" {
    try std.testing.expect(tar.isHeader(GNU[0..512]));
    try std.testing.expect(tar.isHeader(BASE256[0..512]));
    try std.testing.expect(!tar.isHeader(GNU[GNU.len - 512 ..][0..512]));
    var block: [512]u8 = GNU[0..512].*;
    block[0] ^= 1;
    try std.testing.expect(!tar.isHeader(&block));
    try std.testing.expect(tar.isHeader(GNU[512..1024]));
    try std.testing.expect(!tar.isHeader(GNU[1024..1536]));
}

test "[edge] - [tar reader]: skipped entries get no data and still end" {
    var name: [256]u8 = undefined;
    var link: [256]u8 = undefined;
    var storage: [8192]u8 = undefined;
    var visitor: Transcript = .{ .out = .fixed(&storage), .skip = true };
    _ = try read(USTAR, 512, &visitor, .{ .name = &name, .link = &link });
    try std.testing.expectEqualStrings(std.fmt.comptimePrint("file 6 644 {d} d/a.txt|;symlink 0 777 {d} d/sym -> a.txt|;file 6 644 {d} {s}/{s}|;", .{ MTIME, MTIME, MTIME, "p" ** 60, "q" ** 60 }), visitor.out.buffered());
}

test "[failure] - [tar reader]: a stream cut anywhere but a block boundary between entries is Truncated" {
    var storage: [8192]u8 = undefined;
    var whole_storage: [8192]u8 = undefined;
    for ([_][]const u8{ GNU, PAX }) |archive| {
        const whole = try transcribe(archive, archive.len, &whole_storage);
        const first_end = archive.len - 1024;
        var boundaries: usize = 0;
        for (0..archive.len) |cut| {
            if (transcribe(archive[0..cut], 509, &storage)) |result| {
                try std.testing.expect(!result.summary.end_marker);
                try std.testing.expect(std.mem.startsWith(u8, whole.transcript, result.transcript));
                // Once the first end block is complete the archive has ended, like GNU tar reads it.
                if (cut >= first_end + 512) continue;
                try std.testing.expect(cut % 512 == 0);
                boundaries += 1;
            } else |err| {
                try std.testing.expectEqual(error.Truncated, err);
                try std.testing.expect(cut < first_end + 512);
            }
        }
        // Before each of the nine entries' first header block, and before the end blocks.
        try std.testing.expectEqual(@as(usize, 10), boundaries);
    }
}

test "[failure] - [tar reader]: checksums, numbers, sparse entries, and names that do not fit are errors" {
    var storage: [8192]u8 = undefined;
    var bad: [USTAR.len]u8 = USTAR.*;
    bad[0] ^= 1;
    try std.testing.expectError(error.BadHeaderChecksum, transcribe(&bad, 512, &storage));
    var archive: [1024]u8 = @splat(0);
    header(archive[0..512], "a", '0', "0000000012a");
    try std.testing.expectError(error.BadNumber, transcribe(&archive, 512, &storage));
    header(archive[0..512], "sparse", 'S', "00000000000");
    try std.testing.expectError(error.UnsupportedEntry, transcribe(&archive, 512, &storage));
    // Every way a name reaches the caller is bounded by the caller's buffer.
    var name: [100]u8 = undefined;
    var link: [100]u8 = undefined;
    for ([_][]const u8{ GNU, PAX, USTAR }) |fixture| {
        var visitor: Transcript = .{ .out = .fixed(&storage) };
        try std.testing.expectError(error.NameTooLong, read(fixture, 512, &visitor, .{ .name = &name, .link = &link }));
    }
    var wide: [256]u8 = undefined;
    var link119: [119]u8 = undefined;
    var visitor: Transcript = .{ .out = .fixed(&storage) };
    try std.testing.expectError(error.NameTooLong, read(GNU, 512, &visitor, .{ .name = &wide, .link = &link119 }));
}

test "[failure] - [tar reader]: malformed pax records are BadPax" {
    var storage: [1024]u8 = undefined;
    const cases = [_][]const u8{
        "9 pathx\n", "12 path=x\n", "8 path=xy",                      "x path=x\n",  "11 size=1a\n",
        "5 =x\n",    "3 a\n",       "29 size=99999999999999999999\n", "9 path=x\n1",
    };
    for (cases) |records| {
        var archive: [3 * 512]u8 = @splat(0);
        var size: [11]u8 = undefined;
        _ = try std.fmt.bufPrint(&size, "{o:0>11}", .{records.len});
        header(archive[0..512], "pax", 'x', &size);
        @memcpy(archive[512..][0..records.len], records);
        header(archive[1024..1536], "file", '0', "00000000000");
        try std.testing.expectError(error.BadPax, transcribe(&archive, 3, &storage));
    }
}

test "[failure] - [tar reader]: a visitor's error stops the stream and is returned by finish" {
    const decompressor = try std.testing.allocator.create(zipir.Decompressor(.gzip));
    defer std.testing.allocator.destroy(decompressor);
    const compressor = try std.testing.allocator.create(zipir.Compressor(.gzip));
    defer std.testing.allocator.destroy(compressor);
    var compressed: [GNU.len]u8 = undefined;
    var plain = std.Io.Reader.fixed(GNU);
    var sink: std.Io.Writer = .fixed(&compressed);
    _ = try support.compressAll(compressor, &plain, &sink, .{});
    var name: [256]u8 = undefined;
    var link: [256]u8 = undefined;
    var storage: [8192]u8 = undefined;
    var visitor: Transcript = .{ .out = .fixed(&storage), .fail_on = "d/fifo" };
    var reader: tar.Reader(Transcript) = .init(&visitor, .{ .name = &name, .link = &link });
    var source = std.Io.Reader.fixed(sink.buffered());
    try std.testing.expectError(error.WriteFailed, support.decompressAll(decompressor, &source, &reader.writer, .{}));
    try std.testing.expectError(error.Stop, reader.finish());
    try std.testing.expectError(error.WriteFailed, reader.writer.writeAll("more"));
}

test "[property] - [tar reader]: bounded bit flips end in success or a documented error" {
    var storage: [16384]u8 = undefined;
    var mutated: [PAX.len]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(2020);
    for (0..3000) |k| {
        const archive = if (k % 2 == 0) PAX else GNU;
        @memcpy(mutated[0..archive.len], archive);
        mutated[rng.random().uintLessThan(usize, archive.len)] ^= @as(u8, 1) << rng.random().int(u3);
        _ = transcribe(mutated[0..archive.len], 1 + k % 700, &storage) catch |err| switch (err) {
            error.WriteFailed => return err,
            else => {},
        };
    }
}

// --- Writing ---

const File = struct { entry: tar.Entry, bytes: []const u8 = "" };

// Yields `files` in order; `short` hands out one byte fewer than the entry's size.
const Files = struct {
    files: []const File,
    index: usize = 0,
    data_reader: std.Io.Reader = .fixed(""),
    short: bool = false,
    fail_at: ?usize = null,

    pub fn next(self: *Files) !?tar.Entry {
        if (self.fail_at == self.index) return error.SourceBroke;
        if (self.index == self.files.len) return null;
        const file = self.files[self.index];
        self.index += 1;
        self.data_reader = .fixed(if (self.short) file.bytes[0 .. file.bytes.len - 1] else file.bytes);
        return file.entry;
    }

    pub fn data(self: *Files) *std.Io.Reader {
        return &self.data_reader;
    }
};

fn entry(name: []const u8, kind: tar.Kind, size: u64, link: []const u8) tar.Entry {
    return .{ .name = name, .link_name = link, .kind = kind, .size = size, .mode = if (kind == .symlink) 0o777 else 0o644, .mtime = 12345 };
}

const LONG = "l/" ++ "x" ** 298;
const LONG_TARGET = "y" ** 200;
const SPLIT = "p" ** 60 ++ "/" ++ "q" ** 60;
const EXACT = "e" ** 100;

fn sampleFiles() [9]File {
    const S = struct {
        var big: [1000]u8 = undefined;
    };
    for (&S.big, 0..) |*b, i| b.* = @truncate(i * 13);
    return .{
        .{ .entry = entry("d/", .directory, 0, "") },
        .{ .entry = entry("d/a.txt", .file, 6, ""), .bytes = "hello\n" },
        .{ .entry = entry("d/empty", .file, 0, "") },
        .{ .entry = entry("d/big", .file, 1000, ""), .bytes = &S.big },
        .{ .entry = entry(EXACT, .file, 2, ""), .bytes = "ex" },
        .{ .entry = entry(SPLIT, .file, 5, ""), .bytes = "split" },
        .{ .entry = entry(LONG, .file, 4, ""), .bytes = "long" },
        .{ .entry = entry("d/sym", .symlink, 0, LONG_TARGET) },
        .{ .entry = entry("d/hard", .hardlink, 0, "d/a.txt") },
    };
}

// What the reader reports for `sampleFiles` written with mtime 0.
fn expectedSample(out: *std.Io.Writer, files: []const File) !void {
    for (files) |file| {
        const e = file.entry;
        try out.print("{t} {d} {o} 0 {s}", .{ e.kind, e.size, e.mode, e.name });
        if (e.link_name.len != 0) try out.print(" -> {s}", .{e.link_name});
        try out.print("|{s};", .{file.bytes});
    }
}

// Reads the whole archive from a writer whose reader has `buffer`, `chunk` bytes at a time.
fn writeArchive(files: []const File, buffer: []u8, chunk: usize, options: tar.WriterOptions, out: []u8) ![]u8 {
    var source: Files = .{ .files = files };
    var writer: tar.Writer(Files) = .init(&source, buffer, options);
    var at: usize = 0;
    while (true) {
        const n = writer.reader.readSliceShort(out[at..@min(out.len, at + chunk)]) catch |err| {
            _ = try writer.finish();
            return err;
        };
        at += n;
        if (n < @min(chunk, out.len - at + n)) break;
    }
    try std.testing.expectEqual(@as(u64, files.len), try writer.finish());
    return out[0..at];
}

test "[property] - [tar writer]: archives read back entry for entry through any reader buffer and read size" {
    const files = sampleFiles();
    var expected_storage: [4096]u8 = undefined;
    var expected: std.Io.Writer = .fixed(&expected_storage);
    try expectedSample(&expected, &files);
    var first: [16384]u8 = undefined;
    const reference = try writeArchive(&files, &.{}, first.len, .{}, &first);
    // Header blocks plus data blocks: the 121-byte name fits ustar's prefix, the 300-byte name and the
    // 200-byte target each take a GNU header and one block of name, and two zero blocks end the archive.
    try std.testing.expectEqual(@as(usize, (1 + 2 + 1 + 3 + 2 + 2 + 4 + 3 + 1 + 2) * 512), reference.len);
    var storage: [4096]u8 = undefined;
    const result = try transcribe(reference, 512, &storage);
    try std.testing.expectEqualStrings(expected.buffered(), result.transcript);
    try std.testing.expectEqual(tar.Summary{ .entries = 9, .end_marker = true }, result.summary);
    var buffer: [4096]u8 = undefined;
    for ([_]usize{ 0, 1, 7, 512, 4096 }) |buffer_len| {
        for ([_]usize{ 1, 13, 512, 16384 }) |chunk| {
            var again: [16384]u8 = undefined;
            try std.testing.expectEqualSlices(u8, reference, try writeArchive(&files, buffer[0..buffer_len], chunk, .{}, &again));
        }
    }
}

test "[integration] - [tar writer]: the gzip compressor reads an archive the gzip decoder and the reader restore" {
    const files = sampleFiles();
    const compressor = try std.testing.allocator.create(zipir.Compressor(.gzip));
    defer std.testing.allocator.destroy(compressor);
    const decompressor = try std.testing.allocator.create(zipir.Decompressor(.gzip));
    defer std.testing.allocator.destroy(decompressor);
    var source: Files = .{ .files = &files };
    var buffer: [4096]u8 = undefined;
    var writer: tar.Writer(Files) = .init(&source, &buffer, .{});
    var compressed: [16384]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&compressed);
    _ = try support.compressAll(compressor, &writer.reader, &sink, .{});
    var plain: [16384]u8 = undefined;
    var direct: std.Io.Writer = .fixed(&plain);
    var gz = std.Io.Reader.fixed(sink.buffered());
    _ = try support.decompressAll(decompressor, &gz, &direct, .{});
    var reference: [16384]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try writeArchive(&files, &.{}, reference.len, .{}, &reference), direct.buffered());
}

test "[edge] - [tar writer]: the output depends only on the entries and the mtime option" {
    const files = sampleFiles();
    var a: [16384]u8 = undefined;
    var b: [16384]u8 = undefined;
    const zero = try writeArchive(&files, &.{}, a.len, .{}, &a);
    try std.testing.expectEqualSlices(u8, zero, try writeArchive(&files, &.{}, b.len, .{}, &b));
    const dated = try writeArchive(files[1..2], &.{}, b.len, .{ .mtime = -86400 }, &b);
    var storage: [256]u8 = undefined;
    try std.testing.expectEqualStrings("file 6 644 -86400 d/a.txt|hello\n;", (try transcribe(dated, 512, &storage)).transcript);
    // 12345 in each entry does not reach the archive.
    try std.testing.expect(std.mem.find(u8, zero, "30071") == null);
}

test "[edge] - [tar writer]: a size of 8 GiB or more is written base-256 and read back" {
    const huge = [_]File{.{ .entry = entry("huge", .file, 8 << 30, "") }};
    var source: Files = .{ .files = &huge };
    var writer: tar.Writer(Files) = .init(&source, &.{}, .{});
    var block: [512]u8 = undefined;
    try writer.reader.readSliceAll(&block);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0 }, block[124..136]);
    var storage: [256]u8 = undefined;
    try std.testing.expectError(error.Truncated, transcribe(&block, 512, &storage));
    try std.testing.expectEqualStrings("file 8589934592 644 0 huge|", storage[0..27]);
    // The largest size a u64 holds still fits the 12-byte field.
    const largest = [_]File{.{ .entry = entry("largest", .file, std.math.maxInt(u64), "") }};
    var largest_source: Files = .{ .files = &largest };
    var largest_writer: tar.Writer(Files) = .init(&largest_source, &.{}, .{});
    try largest_writer.reader.readSliceAll(&block);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, block[124..136]);
}

test "[failure] - [tar writer]: a short source, a long name, an unsupported kind, and a source error are reported" {
    const files = sampleFiles();
    var out: [16384]u8 = undefined;
    var source: Files = .{ .files = files[1..2], .short = true };
    var writer: tar.Writer(Files) = .init(&source, &.{}, .{});
    try std.testing.expectError(error.ReadFailed, writer.reader.readSliceShort(&out));
    try std.testing.expectError(error.SourceTooShort, writer.finish());
    try std.testing.expectError(error.ReadFailed, writer.reader.readSliceShort(&out));
    const bad = [_]File{
        .{ .entry = entry("n" ** (tar.MAX_NAME + 1), .file, 0, "") },
        .{ .entry = entry("l", .symlink, 0, "t" ** (tar.MAX_NAME + 1)) },
        .{ .entry = entry("fifo", .fifo, 0, "") },
    };
    for (bad, [_]anyerror{ error.NameTooLong, error.NameTooLong, error.UnsupportedEntry }) |file, expected| {
        try std.testing.expectError(expected, writeArchive(&.{file}, &.{}, out.len, .{}, &out));
    }
    const longest = [_]File{.{ .entry = entry("n" ** tar.MAX_NAME, .symlink, 0, "t" ** tar.MAX_NAME) }};
    var storage: [16384]u8 = undefined;
    var name: [tar.MAX_NAME]u8 = undefined;
    var link: [tar.MAX_NAME]u8 = undefined;
    var visitor: Transcript = .{ .out = .fixed(&storage) };
    _ = try read(try writeArchive(&longest, &.{}, out.len, .{}, &out), 512, &visitor, .{ .name = &name, .link = &link });
    try std.testing.expectEqualStrings("symlink 0 777 0 " ++ "n" ** tar.MAX_NAME ++ " -> " ++ "t" ** tar.MAX_NAME ++ "|;", visitor.out.buffered());
    const compressor = try std.testing.allocator.create(zipir.Compressor(.gzip));
    defer std.testing.allocator.destroy(compressor);
    var broken: Files = .{ .files = &files, .fail_at = 3 };
    var broken_writer: tar.Writer(Files) = .init(&broken, &.{}, .{});
    var sink: std.Io.Writer = .fixed(&out);
    try std.testing.expectError(error.ReadFailed, support.compressAll(compressor, &broken_writer.reader, &sink, .{}));
    try std.testing.expectError(error.SourceBroke, broken_writer.finish());
}

test "[unit] - [tar]: the public error sets name exactly the documented errors" {
    try support.expectErrorNames(tar.Error, &.{ "BadHeaderChecksum", "BadNumber", "BadPax", "NameTooLong", "Truncated", "UnsupportedEntry" });
    try support.expectErrorNames(tar.WriteError, &.{ "NameTooLong", "SourceTooShort", "UnsupportedEntry" });
}
