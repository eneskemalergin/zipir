//! Zebrac adapter for `std.compress.flate` gzip.

const std = @import("std");
const flate = std.compress.flate;
const Io = std.Io;
const args = @import("args");

const version = "0.16.0";
const IO_BUFFER_LEN = 64 * 1024;

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next();
    const request = args.parse(&it) catch return usage();

    switch (request) {
        .version => {
            var buf: [64]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(io, &buf);
            try stdout.interface.print("std-gzip {s}\n", .{version});
            try stdout.interface.flush();
        },
        .compress => |paths| try compressPath(io, paths),
        .decompress => |paths| try decompressPath(io, paths),
    }
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        \\usage: std-gzip --version
        \\       std-gzip compress --level N IN OUT
        \\       std-gzip decompress IN OUT
        \\
    , .{});
    return error.InvalidArguments;
}

fn compressPath(io: Io, paths: args.Paths) !void {
    const options = levelOptions(paths.level) orelse return error.InvalidArguments;
    const in_file = try openIn(io, paths.in_path);
    defer closeIfOwned(io, in_file, paths.in_path);
    var in_buf: [IO_BUFFER_LEN]u8 = undefined;
    var in_reader = in_file.readerStreaming(io, &in_buf);

    const out_file = try openOut(io, paths.out_path);
    defer closeIfOwned(io, out_file, paths.out_path);
    var out_buf: [IO_BUFFER_LEN]u8 = undefined;
    var out_writer = out_file.writerStreaming(io, &out_buf);

    var window: [flate.max_window_len]u8 = undefined;
    var c = try flate.Compress.init(&out_writer.interface, &window, .gzip, options);
    _ = try in_reader.interface.streamRemaining(&c.writer);
    try c.finish();
    try out_writer.interface.flush();
}

fn decompressPath(io: Io, paths: args.Paths) !void {
    const in_file = try openIn(io, paths.in_path);
    defer closeIfOwned(io, in_file, paths.in_path);
    var in_buf: [IO_BUFFER_LEN]u8 = undefined;
    var in_reader = in_file.readerStreaming(io, &in_buf);

    const out_file = try openOut(io, paths.out_path);
    defer closeIfOwned(io, out_file, paths.out_path);
    var out_buf: [IO_BUFFER_LEN]u8 = undefined;
    var out_writer = out_file.writerStreaming(io, &out_buf);

    var window: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&in_reader.interface, .gzip, &window);
    _ = d.reader.streamRemaining(&out_writer.interface) catch |err| switch (err) {
        error.ReadFailed => return d.err orelse error.ReadFailed,
        else => |e| return e,
    };
    try out_writer.interface.flush();
}

fn levelOptions(level: u8) ?flate.Compress.Options {
    return switch (level) {
        1 => .level_1,
        2 => .level_2,
        3 => .level_3,
        4 => .level_4,
        5 => .level_5,
        6 => .level_6,
        7 => .level_7,
        8 => .level_8,
        9 => .level_9,
        else => null,
    };
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
