//! Streams gzip, BGZF, zlib, and raw DEFLATE files and standard input through zipir, and lists, tests, and
//! creates tar archives in those formats or plain.

const std = @import("std");
const zipir = @import("zipir");

const USAGE =
    \\Usage: zipir compress [--format gzip|zlib|deflate|bgzf] [--binary] [--fast|--even|--dense] [--] [FILE|-]
    \\       zipir decompress [--format auto|gzip|zlib|deflate] [--max-output-bytes N] [--] [FILE|-]
    \\       zipir test [--format auto|gzip|zlib|deflate] [--max-output-bytes N] [--] [FILE|-]
    \\       zipir bgzf index [--] FILE
    \\       zipir tar list|test [--format auto|gzip|zlib|bgzf|none] [--] [FILE|-]
    \\       zipir tar create [--format gzip|zlib|bgzf|none] [--fast|--even|--dense] [--] PATH...
    \\       zipir --version
    \\       zipir --help
    \\
    \\compress writes gzip to stdout unless --format says otherwise; --even is the default preset,
    \\--fast trades size for speed, and --dense speed for size.
    \\BGZF blocks end at text lines, as bgzip's do, unless the input has NUL bytes or --binary is given.
    \\decompress writes to stdout; test verifies and discards output.
    \\--format auto, the default for decompress and test, detects gzip, BGZF, and zlib;
    \\raw DEFLATE has no signature and needs --format deflate; --format gzip reads BGZF as plain gzip.
    \\BGZF input without its EOF marker is a warning for decompress and an error for test.
    \\bgzf index writes FILE.gzi, the index bgzip -r writes, and never replaces an existing one.
    \\tar list prints mode, size, UTC time, and name per entry; tar test checks every header and the end blocks.
    \\tar --format auto also detects a plain archive (none); an archive without end blocks is a warning
    \\for list and an error for test. tar create writes an archive of PATH... (relative, without ..) to
    \\stdout, gzip unless --format says otherwise, with owner 0 and time 0; hardlinked files are stored whole.
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
    if (std.mem.eql(u8, args[1], "tar")) return tarCommand(io, allocator, args[2..], &stdout.interface);
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
        if (!literal and presetFlag(arg) != null) {
            if (!compress or has_level) return usage(io);
            compress_options.level = presetFlag(arg).?;
            has_level = true;
            continue;
        }
        // --level 1|5|9 is the hidden alias of --fast, --even, and --dense (0.1.2's numeric levels).
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
    const input: Input = if (format) |known| .{ .codec = known } else try detect(&reader.interface, false) orelse return unknownFormat(io);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    const writer = if (verify) &discard.writer else &stdout.interface;
    // Detection without tar never reports a plain archive; `--format` cannot name one here.
    if (input == .plain) return unknownFormat(io);
    if (input == .codec) {
        switch (input.codec) {
            inline else => |known| {
                const decoder = try allocator.create(zipir.Decompressor(known));
                defer allocator.destroy(decoder);
                try pump(decoder, &reader.interface, writer, .{ .max_output_bytes = max_output_bytes });
            },
        }
        try writer.flush();
        return 0;
    }
    try decompressBgzf(io, allocator, &reader.interface, writer, max_output_bytes, verify);
    return 0;
}

// Decodes all of `input` into `out`; a decode error is returned as itself rather than as `ReadFailed`.
fn pump(decoder: anytype, input: *std.Io.Reader, out: *std.Io.Writer, options: std.meta.Child(@TypeOf(decoder)).Options) !void {
    decoder.init(input, options);
    _ = decoder.reader.streamRemaining(out) catch |err| return switch (err) {
        error.ReadFailed => decoder.err.?,
        error.WriteFailed => error.WriteFailed,
    };
}

// What `--format` names or `auto` detects: a codec, BGZF (gzip read with its structure checks), or a
// plain tar archive.
const Input = union(enum) { codec: zipir.Format, bgzf, plain };

// `--format auto` for every command: gzip, BGZF by its first member's `BC` subfield, zlib by a valid
// RFC 1950 header, and for tar commands a plain archive by a valid first header block (or a zero block,
// an archive with no entries). The tar check comes first: it is the strongest signal.
fn detect(reader: *std.Io.Reader, archive: bool) !?Input {
    if (archive) {
        if (reader.peek(512)) |block| {
            if (zipir.tar.isHeader(block[0..512]) or std.mem.allEqual(u8, block, 0)) return .plain;
        } else |err| switch (err) {
            error.EndOfStream => {},
            error.ReadFailed => return err,
        }
    }
    const head = reader.peek(2) catch |err| switch (err) {
        // Inputs shorter than two bytes keep failing as truncated gzip, as they did before auto-detection.
        error.EndOfStream => return .{ .codec = .gzip },
        error.ReadFailed => return err,
    };
    if (head[0] == 0x1f and head[1] == 0x8b) return if (try isBgzf(reader)) .bgzf else .{ .codec = .gzip };
    if (head[0] & 0x0f == 8 and head[0] >> 4 <= 7 and (@as(u16, head[0]) << 8 | head[1]) % 31 == 0) return .{ .codec = .zlib };
    return null;
}

fn unknownFormat(io: std.Io) !u8 {
    var buffer: [128]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    try stderr.interface.writeAll("zipir: unknown input format; use --format\n");
    try stderr.interface.flush();
    return 2;
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
    var buffer: [65536]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
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

// --- tar ---

fn tarCommand(io: std.Io, allocator: std.mem.Allocator, args: []const [:0]const u8, stdout: *std.Io.Writer) !u8 {
    if (args.len == 0) return usage(io);
    const create = std.mem.eql(u8, args[0], "create");
    const verify = std.mem.eql(u8, args[0], "test");
    if (!create and !verify and !std.mem.eql(u8, args[0], "list")) return usage(io);
    var input: ?Input = null;
    var level: @FieldType(zipir.gzip.CompressOptions, "level") = .even;
    var has_format = false;
    var has_level = false;
    var literal = false;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!literal and std.mem.eql(u8, arg, "--")) {
            literal = true;
            continue;
        }
        if (!literal and std.mem.eql(u8, arg, "--format")) {
            if (has_format or i + 1 == args.len) return usage(io);
            i += 1;
            input = if (std.mem.eql(u8, args[i], "none")) .plain else if (std.mem.eql(u8, args[i], "bgzf")) .bgzf else if (std.mem.eql(u8, args[i], "gzip")) .{ .codec = .gzip } else if (std.mem.eql(u8, args[i], "zlib")) .{ .codec = .zlib } else if (!create and std.mem.eql(u8, args[i], "auto")) null else return usage(io);
            has_format = true;
            continue;
        }
        if (!literal and presetFlag(arg) != null) {
            if (!create or has_level) return usage(io);
            level = presetFlag(arg).?;
            has_level = true;
            continue;
        }
        if (!literal and std.mem.eql(u8, arg, "--level")) {
            if (!create or has_level or i + 1 == args.len) return usage(io);
            i += 1;
            const value = std.fmt.parseInt(u8, args[i], 10) catch return usage(io);
            level = std.enums.fromInt(@TypeOf(level), value) orelse return usage(io);
            has_level = true;
            continue;
        }
        if (!literal and arg.len > 1 and arg[0] == '-') return usage(io);
        try paths.append(allocator, arg);
    }
    if (create) {
        if (paths.items.len == 0) return usage(io);
        try createArchive(io, allocator, paths.items, input orelse .{ .codec = .gzip }, level, stdout);
        try stdout.flush();
        return 0;
    }
    if (paths.items.len > 1) return usage(io);
    const input_path = if (paths.items.len == 1) paths.items[0] else "-";
    const stdin = std.mem.eql(u8, input_path, "-");
    const file = if (stdin) std.Io.File.stdin() else try std.Io.Dir.cwd().openFile(io, input_path, .{});
    defer if (!stdin) file.close(io);
    var input_buffer: [32768]u8 = undefined;
    var reader = file.readerStreaming(io, &input_buffer);
    const selected = input orelse try detect(&reader.interface, true) orelse return unknownFormat(io);
    var name: [zipir.tar.MAX_NAME + 1]u8 = undefined;
    var link: [zipir.tar.MAX_NAME + 1]u8 = undefined;
    var lister: Lister = .{ .out = if (verify) null else stdout };
    var archive: zipir.tar.Reader(Lister) = .init(&lister, .{ .name = &name, .link = &link });
    readArchive(io, allocator, &reader.interface, selected, &archive.writer, verify) catch |err| {
        if (err == error.WriteFailed) _ = try archive.finish();
        return err;
    };
    const summary = try archive.finish();
    try stdout.flush();
    if (summary.end_marker) return 0;
    if (verify) return error.MissingEndMarker;
    var buffer: [128]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    try stderr.interface.writeAll("zipir: warning: end-of-archive blocks are absent. The archive may be truncated\n");
    try stderr.interface.flush();
    return 0;
}

fn readArchive(io: std.Io, allocator: std.mem.Allocator, reader: *std.Io.Reader, input: Input, archive: *std.Io.Writer, verify: bool) !void {
    switch (input) {
        .codec => |codec| switch (codec) {
            inline else => |known| {
                const decoder = try allocator.create(zipir.Decompressor(known));
                defer allocator.destroy(decoder);
                try pump(decoder, reader, archive, .{});
            },
        },
        .bgzf => try decompressBgzf(io, allocator, reader, archive, std.math.maxInt(u64), verify),
        // The archive's writer has no buffer, so plain input is fed from the reader's buffer.
        .plain => while (true) {
            const bytes = reader.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return,
                error.ReadFailed => return err,
            };
            try archive.writeAll(bytes);
            reader.toss(bytes.len);
        },
    }
}

// Prints `tar -tv --full-time`'s line without the owner column, in UTC; with no output, only reads.
const Lister = struct {
    out: ?*std.Io.Writer,

    pub fn entry(self: *Lister, e: zipir.tar.Entry) !zipir.tar.Action {
        const out = self.out orelse return .skip;
        var mode: [10]u8 = undefined;
        mode[0] = switch (e.kind) {
            .file => '-',
            .directory => 'd',
            .symlink => 'l',
            .hardlink => 'h',
            .char_device => 'c',
            .block_device => 'b',
            .fifo => 'p',
            .other => '?',
        };
        for (0..9) |bit| {
            const set = e.mode & (@as(u32, 0o400) >> @intCast(bit)) != 0;
            mode[1 + bit] = if (set) "rwxrwxrwx"[bit] else '-';
        }
        for ([_]u32{ 0o4000, 0o2000, 0o1000 }, [_]usize{ 3, 6, 9 }, [_]u8{ 's', 's', 't' }) |flag, at, letter| {
            if (e.mode & flag != 0) mode[at] = if (mode[at] == 'x') letter else std.ascii.toUpper(letter);
        }
        const time = civil(e.mtime);
        try out.print("{s} {d} ", .{ &mode, e.size });
        // A signed number with a width prints its sign; GNU tar prints 1970, not +1970.
        if (time.year >= 0) try out.print("{d:0>4}", .{@as(u64, @intCast(time.year))}) else try out.print("{d}", .{time.year});
        try out.print("-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {s}", .{ time.month, time.day, time.hour, time.minute, time.second, e.name });
        switch (e.kind) {
            .symlink => try out.print(" -> {s}", .{e.link_name}),
            .hardlink => try out.print(" link to {s}", .{e.link_name}),
            else => {},
        }
        try out.writeByte('\n');
        return .skip;
    }

    pub fn data(self: *Lister, bytes: []const u8) !void {
        _ = self;
        _ = bytes;
    }

    pub fn entryEnd(self: *Lister) !void {
        _ = self;
    }
};

const Civil = struct { year: i64, month: u8, day: u8, hour: u8, minute: u8, second: u8 };

// Days to a proleptic Gregorian date (Howard Hinnant's `civil_from_days`), valid for negative times too;
// `std.time.epoch` takes unsigned seconds only.
fn civil(seconds: i64) Civil {
    const days = @divFloor(seconds, 86400);
    const rest: u32 = @intCast(@mod(seconds, 86400));
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = yoe + era * 400 + @intFromBool(month <= 2),
        .month = @intCast(month),
        .day = @intCast(day),
        .hour = @intCast(rest / 3600),
        .minute = @intCast(rest / 60 % 60),
        .second = @intCast(rest % 60),
    };
}

/// The preset a `--fast`, `--even`, or `--dense` flag names, or null.
fn presetFlag(arg: []const u8) ?@FieldType(zipir.gzip.CompressOptions, "level") {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    return std.meta.stringToEnum(@FieldType(zipir.gzip.CompressOptions, "level"), arg[2..]);
}

fn createArchive(io: std.Io, allocator: std.mem.Allocator, paths: []const []const u8, output: Input, level: @FieldType(zipir.gzip.CompressOptions, "level"), stdout: *std.Io.Writer) !void {
    for (paths) |path| if (!safePath(path)) return error.UnsafePath;
    var tree: Tree = .{ .io = io, .allocator = allocator, .roots = paths };
    defer tree.deinit();
    var buffer: [65536]u8 = undefined;
    var archive: zipir.tar.Writer(Tree) = .init(&tree, &buffer, .{});
    writeArchive(allocator, &archive.reader, output, level, stdout) catch |err| {
        if (err == error.ReadFailed) _ = try archive.finish();
        return err;
    };
}

fn writeArchive(allocator: std.mem.Allocator, archive: *std.Io.Reader, output: Input, level: @FieldType(zipir.gzip.CompressOptions, "level"), stdout: *std.Io.Writer) !void {
    switch (output) {
        .codec => |codec| switch (codec) {
            inline else => |known| {
                const encoder = try allocator.create(zipir.Compressor(known));
                defer allocator.destroy(encoder);
                _ = try encoder.compress(archive, stdout, .{ .level = level });
            },
        },
        .bgzf => {
            const writer = try allocator.create(zipir.bgzf.Writer);
            defer allocator.destroy(writer);
            writer.start(stdout, .{ .level = level });
            try writer.write(archive);
            _ = try writer.finish();
        },
        .plain => _ = try archive.streamRemaining(stdout),
    }
}

// Archive names come from PATH as given; zipir's own extraction refuses absolute and `..` names, so they
// are refused here rather than rewritten.
fn safePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/') return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}

// The source for `tar create`: each PATH and, for directories, their contents in byte order of names,
// never following symlinks. Hardlinks are not detected: `std.Io.File.Stat` has no device number, and an
// inode alone could join two files of different file systems.
const Tree = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    roots: []const []const u8,
    root_index: usize = 0,
    stack: std.ArrayList(Frame) = .empty,
    path: std.ArrayList(u8) = .empty,
    link: [zipir.tar.MAX_NAME + 1]u8 = undefined,
    file: ?std.Io.File = null,
    file_reader: std.Io.File.Reader = undefined,
    read_buffer: [65536]u8 = undefined,

    // One directory's names, back to back in `bytes`, in byte order through `spans`: two allocations per
    // directory, not one per name.
    const Frame = struct { prefix_len: usize, bytes: []u8, spans: []Span, next: usize };
    const Span = struct { start: usize, len: usize };

    fn deinit(self: *Tree) void {
        if (self.file) |f| f.close(self.io);
        for (self.stack.items) |frame| self.freeFrame(frame);
        self.stack.deinit(self.allocator);
        self.path.deinit(self.allocator);
    }

    pub fn next(self: *Tree) !?zipir.tar.Entry {
        if (self.file) |f| {
            f.close(self.io);
            self.file = null;
        }
        while (true) {
            if (self.stack.items.len != 0) {
                const top = &self.stack.items[self.stack.items.len - 1];
                if (top.next == top.spans.len) {
                    self.path.shrinkRetainingCapacity(top.prefix_len);
                    self.freeFrame(top.*);
                    _ = self.stack.pop();
                    continue;
                }
                const span = top.spans[top.next];
                const name = top.bytes[span.start..][0..span.len];
                top.next += 1;
                self.path.shrinkRetainingCapacity(top.prefix_len);
                try self.path.append(self.allocator, '/');
                try self.path.appendSlice(self.allocator, name);
            } else {
                if (self.root_index == self.roots.len) return null;
                self.path.clearRetainingCapacity();
                try self.path.appendSlice(self.allocator, std.mem.trimEnd(u8, self.roots[self.root_index], "/"));
                self.root_index += 1;
            }
            if (try self.visit()) |entry| return entry;
        }
    }

    pub fn data(self: *Tree) *std.Io.Reader {
        return &self.file_reader.interface;
    }

    fn visit(self: *Tree) !?zipir.tar.Entry {
        const cwd = std.Io.Dir.cwd();
        const path = self.path.items;
        const stat = try cwd.statFile(self.io, path, .{ .follow_symlinks = false });
        const mode: u32 = @intCast(@intFromEnum(stat.permissions) & 0o7777);
        switch (stat.kind) {
            .directory => {
                var dir = try cwd.openDir(self.io, path, .{ .iterate = true });
                defer dir.close(self.io);
                var bytes: std.ArrayList(u8) = .empty;
                defer bytes.deinit(self.allocator);
                var spans: std.ArrayList(Span) = .empty;
                defer spans.deinit(self.allocator);
                var it = dir.iterate();
                while (try it.next(self.io)) |e| {
                    try spans.append(self.allocator, .{ .start = bytes.items.len, .len = e.name.len });
                    try bytes.appendSlice(self.allocator, e.name);
                }
                std.mem.sort(Span, spans.items, bytes.items, lessThan);
                var frame: Frame = .{ .prefix_len = path.len, .bytes = try bytes.toOwnedSlice(self.allocator), .spans = &.{}, .next = 0 };
                frame.spans = spans.toOwnedSlice(self.allocator) catch |err| {
                    self.allocator.free(frame.bytes);
                    return err;
                };
                self.stack.append(self.allocator, frame) catch |err| {
                    self.freeFrame(frame);
                    return err;
                };
                // Directory names end with a slash, as GNU tar writes them.
                try self.path.append(self.allocator, '/');
                return .{ .name = self.path.items, .link_name = "", .kind = .directory, .size = 0, .mode = mode, .mtime = 0 };
            },
            .sym_link => {
                const n = try cwd.readLink(self.io, path, &self.link);
                return .{ .name = path, .link_name = self.link[0..n], .kind = .symlink, .size = 0, .mode = mode, .mtime = 0 };
            },
            .file => {
                const file = try cwd.openFile(self.io, path, .{});
                self.file = file;
                self.file_reader = file.readerStreaming(self.io, &self.read_buffer);
                // std's copy_file_range path costs about 49 us per file on btrfs; below 1 MiB buffered reads
                // are faster (tar lab, 2026-09-24).
                if (stat.size < 1 << 20) self.file_reader.mode = .streaming_simple;
                return .{ .name = path, .link_name = "", .kind = .file, .size = stat.size, .mode = mode, .mtime = 0 };
            },
            else => {
                var buffer: [256]u8 = undefined;
                var stderr = std.Io.File.stderr().writer(self.io, &buffer);
                try stderr.interface.print("zipir: warning: skipped {s}: not a file, directory, or link\n", .{path});
                try stderr.interface.flush();
                return null;
            },
        }
    }

    fn freeFrame(self: *Tree, frame: Frame) void {
        self.allocator.free(frame.bytes);
        self.allocator.free(frame.spans);
    }

    fn lessThan(bytes: []const u8, a: Span, b: Span) bool {
        return std.mem.lessThan(u8, bytes[a.start..][0..a.len], bytes[b.start..][0..b.len]);
    }
};

fn usage(io: std.Io) !u8 {
    var buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    try stderr.interface.writeAll(USAGE);
    try stderr.interface.flush();
    return 2;
}
