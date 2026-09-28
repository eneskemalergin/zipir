//! Streaming peer adapter for zipir's gzip, zlib, raw DEFLATE, and BGZF codecs.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;
const adapter = @import("adapter");
const zipir = @import("zipir");

// BGZF is not a zipir.Format: it has its own Writer and Reader.
const BGZF = std.mem.eql(u8, build_options.format, "bgzf");
const FORMAT: zipir.Format = blk: {
    if (std.mem.eql(u8, build_options.format, "gzip") or BGZF) break :blk .gzip;
    if (std.mem.eql(u8, build_options.format, "zlib")) break :blk .zlib;
    if (std.mem.eql(u8, build_options.format, "deflate")) break :blk .deflate;
    @compileError("unsupported zipir adapter format");
};
const NAME = "zipir-" ++ build_options.format;

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next();
    const request = adapter.parse(&it) catch return usage();

    switch (request) {
        .version => try printVersion(io),
        .compress => |paths| if (BGZF) try compressBgzf(io, paths) else try compressPath(FORMAT, io, paths),
        .decompress => |paths| if (BGZF) try decompressBgzf(io, paths) else try decompressPath(FORMAT, io, paths),
    }
}

fn printVersion(io: Io) !void {
    var buffer: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.print("{s} {d}.{d}.{d}\n", .{
        NAME,
        zipir.version.major,
        zipir.version.minor,
        zipir.version.patch,
    });
    try stdout.interface.flush();
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        \\usage: {0s} --version
        \\       {0s} compress --level N IN OUT
        \\       {0s} decompress IN OUT
        \\
    , .{NAME});
    return error.InvalidArguments;
}

fn compressPath(comptime codec_format: zipir.Format, io: Io, paths: adapter.Paths) !void {
    const Options = @field(zipir, @tagName(codec_format)).CompressOptions;
    const level = std.enums.fromInt(@FieldType(Options, "level"), paths.level) orelse
        return error.InvalidArguments;
    const compressor = try std.heap.page_allocator.create(zipir.Compressor(codec_format));
    defer std.heap.page_allocator.destroy(compressor);

    const in_file = try adapter.openIn(io, paths.in_path);
    defer adapter.closeIfOwned(io, in_file, paths.in_path);
    var in_buf: [adapter.IO_BUFFER_LEN]u8 = undefined;
    var in_reader = in_file.readerStreaming(io, &in_buf);

    const out_file = try adapter.openOut(io, paths.out_path);
    defer adapter.closeIfOwned(io, out_file, paths.out_path);
    var out_buf: [adapter.IO_BUFFER_LEN]u8 = undefined;
    var out_writer = out_file.writerStreaming(io, &out_buf);

    _ = try compressor.compress(&in_reader.interface, &out_writer.interface, .{ .level = level });
    try out_writer.interface.flush();
}

fn decompressPath(comptime codec_format: zipir.Format, io: Io, paths: adapter.Paths) !void {
    const decoder = try std.heap.page_allocator.create(zipir.Decompressor(codec_format));
    defer std.heap.page_allocator.destroy(decoder);

    const in_file = try adapter.openIn(io, paths.in_path);
    defer adapter.closeIfOwned(io, in_file, paths.in_path);
    var in_buf: [adapter.IO_BUFFER_LEN]u8 = undefined;
    var in_reader = in_file.readerStreaming(io, &in_buf);

    const out_file = try adapter.openOut(io, paths.out_path);
    defer adapter.closeIfOwned(io, out_file, paths.out_path);
    var out_buf: [adapter.IO_BUFFER_LEN]u8 = undefined;
    var out_writer = out_file.writerStreaming(io, &out_buf);

    decoder.init(&in_reader.interface, .{});
    _ = decoder.reader.streamRemaining(&out_writer.interface) catch |err| return switch (err) {
        error.ReadFailed => decoder.err.?,
        error.WriteFailed => error.WriteFailed,
    };
    try out_writer.interface.flush();
}

// The CLI's split rule: whole blocks for binary input, blocks ending at line breaks for text (bgzip's default).
fn compressBgzf(io: Io, paths: adapter.Paths) !void {
    const level = std.enums.fromInt(@FieldType(zipir.bgzf.WriterOptions, "level"), paths.level) orelse
        return error.InvalidArguments;
    const writer = try std.heap.page_allocator.create(zipir.bgzf.Writer);
    defer std.heap.page_allocator.destroy(writer);

    const in_file = try adapter.openIn(io, paths.in_path);
    defer adapter.closeIfOwned(io, in_file, paths.in_path);
    var in_buf: [zipir.bgzf.MAX_BLOCK]u8 = undefined;
    var in_reader = in_file.readerStreaming(io, &in_buf);
    const head = in_reader.interface.peekGreedy(in_buf.len) catch |err| switch (err) {
        error.EndOfStream => in_reader.interface.buffered(),
        error.ReadFailed => return err,
    };
    const split: zipir.bgzf.Split = if (std.mem.indexOfScalar(u8, head, 0) != null) .fill else .lines;

    const out_file = try adapter.openOut(io, paths.out_path);
    defer adapter.closeIfOwned(io, out_file, paths.out_path);
    var out_buf: [adapter.IO_BUFFER_LEN]u8 = undefined;
    var out_writer = out_file.writerStreaming(io, &out_buf);

    writer.start(&out_writer.interface, .{ .level = level, .split = split });
    try writer.write(&in_reader.interface);
    _ = try writer.finish();
    try out_writer.interface.flush();
}

fn decompressBgzf(io: Io, paths: adapter.Paths) !void {
    const decoder = try std.heap.page_allocator.create(zipir.bgzf.Decompressor);
    defer std.heap.page_allocator.destroy(decoder);

    const in_file = try adapter.openIn(io, paths.in_path);
    defer adapter.closeIfOwned(io, in_file, paths.in_path);
    var in_buf: [adapter.IO_BUFFER_LEN]u8 = undefined;
    var in_reader = in_file.readerStreaming(io, &in_buf);

    const out_file = try adapter.openOut(io, paths.out_path);
    defer adapter.closeIfOwned(io, out_file, paths.out_path);
    var out_buf: [adapter.IO_BUFFER_LEN]u8 = undefined;
    var out_writer = out_file.writerStreaming(io, &out_buf);

    decoder.init(&in_reader.interface, .{});
    _ = decoder.reader.streamRemaining(&out_writer.interface) catch |err| return switch (err) {
        error.ReadFailed => decoder.err.?,
        error.WriteFailed => error.WriteFailed,
    };
    try out_writer.interface.flush();
}
