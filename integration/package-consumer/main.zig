//! Public contracts of the `zipir` module as a dependent package sees them: streaming round trips for every format
//! namespace, BGZF indexing and seeking through a file, and a tar archive inside gzip.

const std = @import("std");
const zipir = @import("zipir");

const TEXT = "zipir from an outside package\n" ** 3000;

fn roundTrip(comptime format: zipir.Format, preset: zipir.Preset) !void {
    const allocator = std.testing.allocator;
    const compressor = try allocator.create(zipir.Compressor(format));
    defer allocator.destroy(compressor);
    const decompressor = try allocator.create(zipir.Decompressor(format));
    defer allocator.destroy(decompressor);
    var compressed: [TEXT.len]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&compressed);
    try compressor.init(&sink, .{ .preset = preset });
    try compressor.writer.writeAll(TEXT);
    try std.testing.expectEqual(@as(u64, TEXT.len), try compressor.finish());
    var source: std.Io.Reader = .fixed(sink.buffered());
    decompressor.init(&source, .{});
    var plain: [TEXT.len]u8 = undefined;
    var out: std.Io.Writer = .fixed(&plain);
    _ = decompressor.reader.streamRemaining(&out) catch return decompressor.err.?;
    try std.testing.expectEqualStrings(TEXT, out.buffered());
}

test "[integration] - [package]: gzip, zlib, and raw DEFLATE round-trip at every preset" {
    inline for (.{ .gzip, .zlib, .deflate }) |format| {
        for ([_]zipir.Preset{ .fast, .even, .dense }) |preset| try roundTrip(format, preset);
    }
}

test "[integration] - [package]: a BGZF file written with an index reads back from an uncompressed offset" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var entries: [64]zipir.bgzf.IndexEntry = undefined;
    var index: zipir.bgzf.IndexBuilder = .init(&entries);
    {
        const file = try tmp.dir.createFile(io, "text.gz", .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        const compressor = try allocator.create(zipir.bgzf.Compressor);
        defer allocator.destroy(compressor);
        try compressor.init(&writer.interface, .{ .split = .lines, .index = &index });
        for (0..4) |_| try compressor.writer.writeAll(TEXT);
        _ = try compressor.finish();
        try writer.interface.flush();
    }
    const file = try tmp.dir.openFile(io, "text.gz", .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const decompressor = try allocator.create(zipir.bgzf.Decompressor);
    defer allocator.destroy(decompressor);
    decompressor.init(&reader.interface, .{});
    const offset = 2 * TEXT.len + 5 * 30;
    try decompressor.seekUncompressed(&reader, index.slice(), offset);
    const line = decompressor.reader.takeDelimiterExclusive('\n') catch return decompressor.err.?;
    try std.testing.expectEqualStrings("zipir from an outside package", line);
}

const Source = struct {
    done: bool = false,
    data_reader: std.Io.Reader = .fixed(TEXT),

    pub fn next(self: *Source) !?zipir.tar.Entry {
        if (self.done) return null;
        self.done = true;
        return .{ .name = "notes/text.txt", .link_name = "", .kind = .file, .size = TEXT.len, .mode = 0o644, .mtime = 0 };
    }

    pub fn data(self: *Source) *std.Io.Reader {
        return &self.data_reader;
    }
};

const Visitor = struct {
    name: [64]u8 = undefined,
    name_len: usize = 0,
    bytes: std.Io.Writer.Allocating,

    pub fn entry(self: *Visitor, e: zipir.tar.Entry) !zipir.tar.Action {
        @memcpy(self.name[0..e.name.len], e.name);
        self.name_len = e.name.len;
        return .read;
    }

    pub fn data(self: *Visitor, bytes: []const u8) !void {
        try self.bytes.writer.writeAll(bytes);
    }

    pub fn entryEnd(_: *Visitor) !void {}
};

test "[integration] - [package]: a tar archive inside gzip reads back entry for entry" {
    const allocator = std.testing.allocator;
    const compressor = try allocator.create(zipir.gzip.Compressor);
    defer allocator.destroy(compressor);
    const decompressor = try allocator.create(zipir.gzip.Decompressor);
    defer allocator.destroy(decompressor);
    var source: Source = .{};
    var tar_buffer: [4096]u8 = undefined;
    var archive: zipir.tar.Writer(Source) = .init(&source, &tar_buffer, .{});
    var compressed: [TEXT.len]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&compressed);
    try compressor.init(&sink, .{});
    _ = try archive.reader.streamRemaining(&compressor.writer);
    _ = try compressor.finish();
    try std.testing.expectEqual(@as(u64, 1), try archive.finish());

    var visitor: Visitor = .{ .bytes = .init(allocator) };
    defer visitor.bytes.deinit();
    var name: [zipir.tar.MAX_NAME + 1]u8 = undefined;
    var link: [zipir.tar.MAX_NAME + 1]u8 = undefined;
    var tar_reader: zipir.tar.Reader(Visitor) = .init(&visitor, .{ .name = &name, .link = &link });
    var gz: std.Io.Reader = .fixed(sink.buffered());
    decompressor.init(&gz, .{});
    _ = decompressor.reader.streamRemaining(&tar_reader.writer) catch return decompressor.err.?;
    const summary = try tar_reader.finish();
    try std.testing.expectEqual(@as(u64, 1), summary.entries);
    try std.testing.expect(summary.end_marker);
    try std.testing.expectEqualStrings("notes/text.txt", visitor.name[0..visitor.name_len]);
    try std.testing.expectEqualStrings(TEXT, visitor.bytes.written());
}
