//! Zebrac adapter for `std.compress.flate` gzip.

const std = @import("std");
const builtin = @import("builtin");
const flate = std.compress.flate;
const Io = std.Io;
const adapter = @import("adapter");

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next();
    const request = adapter.parse(&it) catch return usage();

    switch (request) {
        .version => {
            var buf: [64]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(io, &buf);
            try stdout.interface.print("std-gzip {s}\n", .{builtin.zig_version_string});
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

fn compressPath(io: Io, paths: adapter.Paths) !void {
    const options = levelOptions(paths.level) orelse return error.InvalidArguments;
    const in_file = try adapter.openIn(io, paths.in_path);
    defer adapter.closeIfOwned(io, in_file, paths.in_path);
    var in_buf: [adapter.IO_BUFFER_LEN]u8 = undefined;
    var in_reader = in_file.readerStreaming(io, &in_buf);

    const out_file = try adapter.openOut(io, paths.out_path);
    defer adapter.closeIfOwned(io, out_file, paths.out_path);
    var out_buf: [adapter.IO_BUFFER_LEN]u8 = undefined;
    var out_writer = out_file.writerStreaming(io, &out_buf);

    var window: [flate.max_window_len]u8 = undefined;
    var c = try flate.Compress.init(&out_writer.interface, &window, .gzip, options);
    _ = try in_reader.interface.streamRemaining(&c.writer);
    try c.finish();
    try out_writer.interface.flush();
}

fn decompressPath(io: Io, paths: adapter.Paths) !void {
    const in_file = try adapter.openIn(io, paths.in_path);
    defer adapter.closeIfOwned(io, in_file, paths.in_path);
    var in_buf: [adapter.IO_BUFFER_LEN]u8 = undefined;
    var in_reader = in_file.readerStreaming(io, &in_buf);

    const out_file = try adapter.openOut(io, paths.out_path);
    defer adapter.closeIfOwned(io, out_file, paths.out_path);
    var out_buf: [adapter.IO_BUFFER_LEN]u8 = undefined;
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
