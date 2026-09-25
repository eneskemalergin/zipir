//! Streaming zlib decompression adapter for `std.compress.flate`.

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
            try stdout.interface.print("std-zlib {s}\n", .{builtin.zig_version_string});
            try stdout.interface.flush();
        },
        .compress => return usage(),
        .decompress => |paths| try decompressPath(io, paths),
    }
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        \\usage: std-zlib --version
        \\       std-zlib decompress IN OUT
        \\
    , .{});
    return error.InvalidArguments;
}

fn decompressPath(io: Io, paths: adapter.Paths) !void {
    const in_file = try adapter.openIn(io, paths.in_path);
    defer adapter.closeIfOwned(io, in_file, paths.in_path);
    var in_buf: [adapter.IO_BUFFER_LEN]u8 = undefined;
    var in_reader = in_file.readerStreaming(io, &in_buf);

    const header = try in_reader.interface.peekArray(2);
    if ((header[0] & 0x0f) != 8) return error.UnsupportedMethod;
    if ((header[0] >> 4) > 7) return error.WindowTooLarge;
    if ((@as(u16, header[0]) << 8 | header[1]) % 31 != 0) return error.BadHeader;
    if ((header[1] & 0x20) != 0) return error.DictionaryUnsupported;

    const out_file = try adapter.openOut(io, paths.out_path);
    defer adapter.closeIfOwned(io, out_file, paths.out_path);
    var out_buf: [adapter.IO_BUFFER_LEN]u8 = undefined;
    var out_writer = out_file.writerStreaming(io, &out_buf);

    var window: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&in_reader.interface, .zlib, &window);
    var adler_buf: [adapter.IO_BUFFER_LEN]u8 = undefined;
    var adler_writer = out_writer.interface.hashed(std.hash.Adler32{}, &adler_buf);
    _ = d.reader.streamRemaining(&adler_writer.writer) catch |err| switch (err) {
        error.ReadFailed => {
            const inner = d.err orelse return error.ReadFailed;
            if (inner != error.EndOfStream) return inner;
            switch (@field(d, "state")) {
                .end => {},
                else => return inner,
            }
        },
        else => |e| return e,
    };
    try adler_writer.writer.flush();

    // Zig 0.16 stores the parsed zlib trailer privately; this peer is pinned to that version.
    const metadata = @field(d, "container_metadata");
    const expected_adler = @field(metadata, "zlib").adler;
    if (adler_writer.hasher.adler != expected_adler) return error.BadAdler;

    const trailing = in_reader.interface.take(1) catch |err| switch (err) {
        error.EndOfStream => &.{},
        error.ReadFailed => return d.err orelse error.ReadFailed,
        else => |e| return e,
    };
    if (trailing.len != 0) return error.TrailingData;
    try out_writer.interface.flush();
}
