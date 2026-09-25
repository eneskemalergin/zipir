//! Streams gzip, BGZF, zlib, and raw DEFLATE files and standard input through zipir.

const std = @import("std");
const zipir = @import("zipir");

const USAGE =
    \\Usage: zipir compress [--format gzip|zlib|deflate|bgzf] [--binary] [--level 1|5|9] [--] [FILE|-]
    \\       zipir decompress [--format auto|gzip|zlib|deflate] [--max-output-bytes N] [--] [FILE|-]
    \\       zipir test [--format auto|gzip|zlib|deflate] [--max-output-bytes N] [--] [FILE|-]
    \\       zipir bgzf index [--] FILE
    \\       zipir --version
    \\       zipir --help
    \\
    \\compress writes gzip to stdout unless --format says otherwise; default level is 5.
    \\BGZF blocks end at text lines, as bgzip's do, unless the input has NUL bytes or --binary is given.
    \\decompress writes to stdout; test verifies and discards output.
    \\--format auto, the default for decompress and test, detects gzip, BGZF, and zlib;
    \\raw DEFLATE has no signature and needs --format deflate; --format gzip reads BGZF as plain gzip.
    \\BGZF input without its EOF marker is a warning for decompress and an error for test.
    \\bgzf index writes FILE.gzi, the index bgzip -r writes, and never replaces an existing one.
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
    if (std.mem.eql(u8, args[1], "bgzf")) return bgzfIndex(io, allocator, args[2..]);
    const verify = std.mem.eql(u8, args[1], "test");
    const compress = std.mem.eql(u8, args[1], "compress");
    if (!compress and !verify and !std.mem.eql(u8, args[1], "decompress")) return usage(io);
    var path: ?[]const u8 = null;
    var format: ?zipir.Format = null;
    var max_output_bytes: u64 = std.math.maxInt(u64);
    var compress_options: zipir.gzip.CompressOptions = .{};
    var literal = false;
    var bgzf_output = false;
    var binary = false;
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
            } else if (std.mem.eql(u8, args[i], "bgzf")) {
                if (!compress) return usage(io);
                bgzf_output = true;
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
        if (!literal and std.mem.eql(u8, arg, "--binary")) {
            if (!compress or binary) return usage(io);
            binary = true;
            continue;
        }
        if (path != null or (!literal and arg.len > 1 and arg[0] == '-')) return usage(io);
        path = arg;
    }
    if (binary and !bgzf_output) return usage(io);
    const input_path = path orelse "-";
    const stdin = std.mem.eql(u8, input_path, "-");
    const file = if (stdin) std.Io.File.stdin() else try std.Io.Dir.cwd().openFile(io, input_path, .{});
    defer if (!stdin) file.close(io);
    var input_buffer: [32768]u8 = undefined;
    var reader = file.readerStreaming(io, &input_buffer);
    if (bgzf_output) {
        try compressBgzf(io, allocator, file, &stdout.interface, compress_options.level, binary);
        try stdout.interface.flush();
        return 0;
    }
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
    const bgzf_input = format == null and selected == .gzip and try isBgzf(&reader.interface);
    if (!bgzf_input) {
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
    try decompressBgzf(io, allocator, &reader.interface, writer, max_output_bytes, verify);
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

// A gzip member whose FEXTRA holds a `BC` subfield starts a BGZF file; headers larger than the buffer are not.
fn isBgzf(reader: *std.Io.Reader) !bool {
    const fixed = reader.peek(12) catch |err| switch (err) {
        error.EndOfStream => return false,
        error.ReadFailed => return err,
    };
    if (fixed[0] != 0x1f or fixed[1] != 0x8b or fixed[3] & 4 == 0) return false;
    const header_len = 12 + @as(usize, std.mem.readInt(u16, fixed[10..12], .little));
    if (header_len > reader.buffer.len) return false;
    const header = reader.peek(header_len) catch |err| switch (err) {
        error.EndOfStream => return false,
        error.ReadFailed => return err,
    };
    var i: usize = 12;
    while (i + 4 <= header.len) {
        const len = std.mem.readInt(u16, header[i + 2 ..][0..2], .little);
        if (header[i] == 'B' and header[i + 1] == 'C' and len == 2) return true;
        i += 4 + len;
    }
    return false;
}

fn compressBgzf(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File, out: *std.Io.Writer, level: @FieldType(zipir.bgzf.WriterOptions, "level"), binary: bool) !void {
    const buffer = try allocator.alloc(u8, 65536);
    defer allocator.free(buffer);
    var reader = file.readerStreaming(io, buffer);
    const head = reader.interface.peekGreedy(buffer.len) catch |err| switch (err) {
        error.EndOfStream => reader.interface.buffered(),
        error.ReadFailed => return err,
    };
    const split: zipir.bgzf.Split = if (binary or std.mem.indexOfScalar(u8, head, 0) != null) .fill else .lines;
    const writer = try allocator.create(zipir.bgzf.Writer);
    defer allocator.destroy(writer);
    writer.start(out, .{ .level = level, .split = split });
    try writer.write(&reader.interface);
    _ = try writer.finish();
}

// Two scans of FILE (the first counts the entries), then FILE.gzi, created exclusively.
fn bgzfIndex(io: std.Io, allocator: std.mem.Allocator, args: []const [:0]const u8) !u8 {
    if (args.len < 2 or !std.mem.eql(u8, args[0], "index")) return usage(io);
    const literal = args.len == 3 and std.mem.eql(u8, args[1], "--");
    if (args.len != @as(usize, if (literal) 3 else 2)) return usage(io);
    const path = args[args.len - 1];
    if (!literal and path.len > 0 and path[0] == '-') return usage(io);
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, path, .{});
    defer file.close(io);
    var buffer: [65536]u8 = undefined;
    var count: usize = 0;
    {
        var reader = file.reader(io, &buffer);
        var scanner = zipir.bgzf.scan(&reader.interface, .{});
        while (try scanner.next()) |block| count += @intFromBool(block.data_size != 0);
    }
    const entries = try allocator.alloc(zipir.bgzf.IndexEntry, count);
    defer allocator.free(entries);
    var builder: zipir.bgzf.IndexBuilder = .init(entries);
    var reader = file.reader(io, &buffer);
    var scanner = zipir.bgzf.scan(&reader.interface, .{});
    while (try scanner.next()) |block| try builder.add(block.coffset, block.data_size);
    const name = try std.fmt.allocPrint(allocator, "{s}.gzi", .{path});
    defer allocator.free(name);
    const out = try cwd.createFile(io, name, .{ .exclusive = true });
    errdefer cwd.deleteFile(io, name) catch {};
    defer out.close(io);
    var out_buffer: [4096]u8 = undefined;
    var writer = out.writer(io, &out_buffer);
    try zipir.bgzf.writeIndex(&writer.interface, builder.slice());
    try writer.interface.flush();
    return 0;
}

fn decompressBgzf(io: std.Io, allocator: std.mem.Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer, max_output_bytes: u64, verify: bool) !void {
    const decoder = try allocator.create(zipir.bgzf.Reader);
    defer allocator.destroy(decoder);
    const summary = try decoder.decompress(reader, writer, .{ .max_output_bytes = max_output_bytes, .require_eof_marker = verify });
    try writer.flush();
    if (summary.eof_marker) return;
    var buffer: [128]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    try stderr.interface.writeAll("zipir: warning: EOF marker is absent. The input may be truncated\n");
    try stderr.interface.flush();
}

fn usage(io: std.Io) !u8 {
    var buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    try stderr.interface.writeAll(USAGE);
    try stderr.interface.flush();
    return 2;
}
