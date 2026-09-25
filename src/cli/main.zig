//! Streams gzip, zlib, and raw DEFLATE files and standard input through zipir.

const std = @import("std");
const zipir = @import("zipir");

const USAGE =
    \\Usage: zipir compress [--format gzip|zlib|deflate] [--level 1|5|9] [--] [FILE|-]
    \\       zipir decompress [--format auto|gzip|zlib|deflate] [--max-output-bytes N] [--] [FILE|-]
    \\       zipir test [--format auto|gzip|zlib|deflate] [--max-output-bytes N] [--] [FILE|-]
    \\       zipir --version
    \\       zipir --help
    \\
    \\compress writes gzip to stdout unless --format says otherwise; default level is 5.
    \\decompress writes to stdout; test verifies and discards output.
    \\--format auto, the default for decompress and test, detects gzip and zlib;
    \\raw DEFLATE has no signature and needs --format deflate.
    \\FILE defaults to stdin. Concatenated gzip members are supported.
    \\Corrupt, truncated, or trailing data returns a nonzero status.
    \\Output may be partial on failure. Input files are preserved.
    \\
;

pub fn main(init: std.process.Init.Minimal) void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const status = run(io, init.args) catch |err| failed: {
        var buffer: [256]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &buffer);
        stderr.interface.print("zipir: {s}\n", .{@errorName(err)}) catch {};
        stderr.interface.flush() catch {};
        break :failed @as(u8, 1);
    };
    if (status != 0) std.process.exit(status);
}

fn run(io: std.Io, process_args: std.process.Args) !u8 {
    const allocator = std.heap.page_allocator;
    const args = try process_args.toSlice(allocator);
    defer allocator.free(args);
    var output_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &output_buffer);
    // An empty argument vector (possible through execve) gets the version, not an out-of-bounds read.
    if (args.len <= 1 or (args.len == 2 and std.mem.eql(u8, args[1], "--version"))) {
        try stdout.interface.print("zipir {d}.{d}.{d}\n", .{
            zipir.version.major, zipir.version.minor, zipir.version.patch,
        });
        try stdout.interface.flush();
        return 0;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        try stdout.interface.writeAll(USAGE);
        try stdout.interface.flush();
        return 0;
    }
    const verify = std.mem.eql(u8, args[1], "test");
    const compress = std.mem.eql(u8, args[1], "compress");
    if (!compress and !verify and !std.mem.eql(u8, args[1], "decompress")) return usage(io);
    var path: ?[]const u8 = null;
    var format: ?zipir.Format = null;
    var max_output_bytes: u64 = std.math.maxInt(u64);
    var compress_options: zipir.gzip.CompressOptions = .{};
    var literal = false;
    var has_format = false;
    var has_limit = false;
    var has_level = false;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!literal and std.mem.eql(u8, arg, "--")) {
            literal = true;
            continue;
        }
        if (!literal and std.mem.eql(u8, arg, "--format")) {
            if (has_format or i + 1 == args.len) return usage(io);
            i += 1;
            if (std.mem.eql(u8, args[i], "auto")) {
                if (compress) return usage(io);
            } else format = std.meta.stringToEnum(zipir.Format, args[i]) orelse return usage(io);
            has_format = true;
            continue;
        }
        if (!literal and std.mem.eql(u8, arg, "--max-output-bytes")) {
            if (compress or has_limit or i + 1 == args.len) return usage(io);
            i += 1;
            max_output_bytes = std.fmt.parseInt(u64, args[i], 10) catch return usage(io);
            has_limit = true;
            continue;
        }
        if (!literal and std.mem.eql(u8, arg, "--level")) {
            if (!compress or has_level or i + 1 == args.len) return usage(io);
            i += 1;
            const level = std.fmt.parseInt(u8, args[i], 10) catch return usage(io);
            compress_options.level = std.enums.fromInt(@FieldType(zipir.gzip.CompressOptions, "level"), level) orelse return usage(io);
            has_level = true;
            continue;
        }
        if (path != null or (!literal and arg.len > 1 and arg[0] == '-')) return usage(io);
        path = arg;
    }
    const input_path = path orelse "-";
    const stdin = std.mem.eql(u8, input_path, "-");
    const file = if (stdin) std.Io.File.stdin() else try std.Io.Dir.cwd().openFile(io, input_path, .{});
    defer if (!stdin) file.close(io);
    var input_buffer: [32768]u8 = undefined;
    var reader = file.readerStreaming(io, &input_buffer);
    if (compress) {
        switch (format orelse .gzip) {
            inline else => |selected| {
                const encoder = try allocator.create(zipir.Compressor(selected));
                defer allocator.destroy(encoder);
                _ = try encoder.compress(&reader.interface, &stdout.interface, compress_options);
            },
        }
        try stdout.interface.flush();
        return 0;
    }
    const selected = format orelse try detect(&reader.interface) orelse {
        var buffer: [128]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &buffer);
        try stderr.interface.writeAll("zipir: unknown input format; use --format\n");
        try stderr.interface.flush();
        return 2;
    };
    var discard: std.Io.Writer.Discarding = .init(&.{});
    const writer = if (verify) &discard.writer else &stdout.interface;
    switch (selected) {
        inline else => |known| {
            const decoder = try allocator.create(zipir.Decompressor(known));
            defer allocator.destroy(decoder);
            _ = try decoder.decompress(&reader.interface, writer, .{ .max_output_bytes = max_output_bytes });
        },
    }
    try writer.flush();
    return 0;
}

fn detect(reader: *std.Io.Reader) !?zipir.Format {
    const head = reader.peek(2) catch |err| switch (err) {
        // Inputs shorter than two bytes keep failing as truncated gzip, as they did before auto-detection.
        error.EndOfStream => return .gzip,
        error.ReadFailed => return err,
    };
    if (head[0] == 0x1f and head[1] == 0x8b) return .gzip;
    if (head[0] & 0x0f == 8 and head[0] >> 4 <= 7 and (@as(u16, head[0]) << 8 | head[1]) % 31 == 0) return .zlib;
    return null;
}

fn usage(io: std.Io) !u8 {
    var buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    try stderr.interface.writeAll(USAGE);
    try stderr.interface.flush();
    return 2;
}
