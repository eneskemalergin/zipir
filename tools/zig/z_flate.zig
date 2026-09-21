//! Streaming peer adapter for z-flate's gzip and zlib codecs.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;
const args = @import("args");
const z_flate = @import("z_flate");

const format: z_flate.Format = blk: {
    if (std.mem.eql(u8, build_options.format, "gzip")) break :blk .gzip;
    if (std.mem.eql(u8, build_options.format, "zlib")) break :blk .zlib;
    @compileError("unsupported z-flate adapter format");
};
const name = if (format == .gzip) "z-flate-gzip" else "z-flate-zlib";
const IO_BUFFER_LEN = 64 * 1024;

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next();
    const request = args.parse(&it) catch return usage();

    switch (request) {
        .version => try printVersion(io),
        .compress => |paths| {
            if (format != .gzip) return usage();
            try compressPath(io, paths);
        },
        .decompress => |paths| try decompressPath(format, io, paths),
    }
}

fn printVersion(io: Io) !void {
    var buffer: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.print("{s} {d}.{d}.{d}\n", .{
        name,
        z_flate.version.major,
        z_flate.version.minor,
        z_flate.version.patch,
    });
    try stdout.interface.flush();
}

fn usage() error{InvalidArguments} {
    if (format == .gzip) {
        std.debug.print(
            \\usage: z-flate-gzip --version
            \\       z-flate-gzip compress --level N IN OUT
            \\       z-flate-gzip decompress IN OUT
            \\
        , .{});
    } else {
        std.debug.print(
            \\usage: z-flate-zlib --version
            \\       z-flate-zlib decompress IN OUT
            \\
        , .{});
    }
    return error.InvalidArguments;
}

fn compressPath(io: Io, paths: args.Paths) !void {
    const level = std.enums.fromInt(@FieldType(z_flate.gzip.CompressOptions, "level"), paths.level) orelse
        return error.InvalidArguments;
    const compressor = try std.heap.page_allocator.create(z_flate.Compressor(.gzip));
    defer std.heap.page_allocator.destroy(compressor);

    const in_file = try openIn(io, paths.in_path);
    defer closeIfOwned(io, in_file, paths.in_path);
    var in_buf: [IO_BUFFER_LEN]u8 = undefined;
    var in_reader = in_file.readerStreaming(io, &in_buf);

    const out_file = try openOut(io, paths.out_path);
    defer closeIfOwned(io, out_file, paths.out_path);
    var out_buf: [IO_BUFFER_LEN]u8 = undefined;
    var out_writer = out_file.writerStreaming(io, &out_buf);

    _ = try compressor.compress(&in_reader.interface, &out_writer.interface, .{ .level = level });
    try out_writer.interface.flush();
}

fn decompressPath(comptime codec_format: z_flate.Format, io: Io, paths: args.Paths) !void {
    const decoder = try std.heap.page_allocator.create(z_flate.Decompressor(codec_format));
    defer std.heap.page_allocator.destroy(decoder);

    const in_file = try openIn(io, paths.in_path);
    defer closeIfOwned(io, in_file, paths.in_path);
    var in_buf: [IO_BUFFER_LEN]u8 = undefined;
    var in_reader = in_file.readerStreaming(io, &in_buf);

    const out_file = try openOut(io, paths.out_path);
    defer closeIfOwned(io, out_file, paths.out_path);
    var out_buf: [IO_BUFFER_LEN]u8 = undefined;
    var out_writer = out_file.writerStreaming(io, &out_buf);

    _ = try decoder.decompress(&in_reader.interface, &out_writer.interface, .{});
    try out_writer.interface.flush();
}

fn isDash(path: []const u8) bool {
    return std.mem.eql(u8, path, "-");
}

fn openIn(io: Io, path: []const u8) !std.Io.File {
    if (isDash(path)) return .stdin();
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openFileAbsolute(io, path, .{});
    return std.Io.Dir.cwd().openFile(io, path, .{});
}

fn openOut(io: Io, path: []const u8) !std.Io.File {
    if (isDash(path)) return .stdout();
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.createFileAbsolute(io, path, .{});
    return std.Io.Dir.cwd().createFile(io, path, .{});
}

fn closeIfOwned(io: Io, file: std.Io.File, path: []const u8) void {
    if (!isDash(path)) file.close(io);
}
