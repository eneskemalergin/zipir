//! Streams gzip files and standard input through z_flate.

const std = @import("std");
const z_flate = @import("z_flate");

const USAGE =
    \\Usage: z_flate decompress [--max-output-bytes N] [--] [FILE|-]
    \\       z_flate test [--max-output-bytes N] [--] [FILE|-]
    \\       z_flate --version
    \\       z_flate --help
    \\
    \\decompress writes to stdout; test verifies and discards output.
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
        stderr.interface.print("z_flate: {s}\n", .{@errorName(err)}) catch {};
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
    if (args.len == 1 or (args.len == 2 and std.mem.eql(u8, args[1], "--version"))) {
        try stdout.interface.print("z_flate {d}.{d}.{d}\n", .{
            z_flate.version.major, z_flate.version.minor, z_flate.version.patch,
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
    if (!verify and !std.mem.eql(u8, args[1], "decompress")) return usage(io);
    var path: ?[]const u8 = null;
    var options: z_flate.gzip.Options = .{};
    var literal = false;
    var has_limit = false;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!literal and std.mem.eql(u8, arg, "--")) {
            literal = true;
            continue;
        }
        if (!literal and std.mem.eql(u8, arg, "--max-output-bytes")) {
            if (has_limit or i + 1 == args.len) return usage(io);
            i += 1;
            options.max_output_bytes = std.fmt.parseInt(u64, args[i], 10) catch return usage(io);
            has_limit = true;
            continue;
        }
        if (path != null or (!literal and arg.len > 1 and arg[0] == '-')) return usage(io);
        path = arg;
    }
    const input_path = path orelse "-";
    const stdin = std.mem.eql(u8, input_path, "-");
    const file = if (stdin) std.Io.File.stdin() else try std.Io.Dir.cwd().openFile(io, input_path, .{});
    defer if (!stdin) file.close(io);
    const decoder = try allocator.create(z_flate.Decompressor(.gzip));
    defer allocator.destroy(decoder);
    var input_buffer: [32768]u8 = undefined;
    var reader = file.readerStreaming(io, &input_buffer);
    if (verify) {
        var discard: std.Io.Writer.Discarding = .init(&.{});
        _ = try decoder.decompress(&reader.interface, &discard.writer, options);
        try discard.writer.flush();
    } else {
        _ = try decoder.decompress(&reader.interface, &stdout.interface, options);
        try stdout.interface.flush();
    }
    return 0;
}

fn usage(io: std.Io) !u8 {
    var buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    try stderr.interface.writeAll(USAGE);
    try stderr.interface.flush();
    return 2;
}
