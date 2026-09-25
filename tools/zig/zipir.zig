//! Streaming peer adapter for zipir's gzip and zlib codecs.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;
const adapter = @import("adapter");
const zipir = @import("zipir");

const FORMAT: zipir.Format = blk: {
    if (std.mem.eql(u8, build_options.format, "gzip")) break :blk .gzip;
    if (std.mem.eql(u8, build_options.format, "zlib")) break :blk .zlib;
    @compileError("unsupported zipir adapter format");
};
const NAME = if (FORMAT == .gzip) "zipir-gzip" else "zipir-zlib";

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next();
    const request = adapter.parse(&it) catch return usage();

    switch (request) {
        .version => try printVersion(io),
        .compress => |paths| try compressPath(FORMAT, io, paths),
        .decompress => |paths| try decompressPath(FORMAT, io, paths),
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
    if (FORMAT == .gzip) {
        std.debug.print(
            \\usage: zipir-gzip --version
            \\       zipir-gzip compress --level N IN OUT
            \\       zipir-gzip decompress IN OUT
            \\
        , .{});
    } else {
        std.debug.print(
            \\usage: zipir-zlib --version
            \\       zipir-zlib compress --level N IN OUT
            \\       zipir-zlib decompress IN OUT
            \\
        , .{});
    }
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

    _ = try decoder.decompress(&in_reader.interface, &out_writer.interface, .{});
    try out_writer.interface.flush();
}
