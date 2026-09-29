//! Checks command output, failures, format selection, and file preservation.

const std = @import("std");
const options = @import("options");

test "[cli] - [gzip]: command status and byte streams preserve source files" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(io, options.executable, allocator);
    defer allocator.free(executable);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const seed = @embedFile("data/synthetic/repeat-zero.gz");
    try tmp.dir.writeFile(io, .{ .sub_path = "-input with spaces.gz", .data = seed });
    try tmp.dir.writeFile(io, .{ .sub_path = "truncated.gz", .data = seed[0 .. seed.len - 1] });
    try tmp.dir.writeFile(io, .{ .sub_path = "-plain with spaces", .data = "A" });
    const compressed = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff\x73\x04\x00\x8b\x9e\xd9\xd3\x01\x00\x00\x00";
    const cases = .{
        .{ &.{executable}, @as(u8, 0), "zipir 0.2.0\n", "" },
        .{ &.{ executable, "--version" }, @as(u8, 0), "zipir 0.2.0\n", "" },
        .{ &.{ executable, "decompress", "--", "-input with spaces.gz" }, @as(u8, 0), "A", "" },
        .{ &.{ executable, "test", "--", "-input with spaces.gz" }, @as(u8, 0), "", "" },
        .{ &.{ executable, "decompress", "--max-output-bytes", "0", "--", "-input with spaces.gz" }, @as(u8, 1), "", "zipir: OutputLimitExceeded\n" },
        .{ &.{ executable, "decompress", "truncated.gz" }, @as(u8, 1), "", "zipir: Truncated\n" },
        .{ &.{ executable, "decompress", "missing.gz" }, @as(u8, 1), "", "zipir: FileNotFound\n" },
        .{ &.{ executable, "compress", "--", "-plain with spaces" }, @as(u8, 0), compressed, "" },
        .{ &.{ executable, "compress", "--level", "1", "--", "-plain with spaces" }, @as(u8, 0), compressed, "" },
        .{ &.{ executable, "compress", "--level", "5", "--", "-plain with spaces" }, @as(u8, 0), compressed, "" },
        .{ &.{ executable, "compress", "--level", "9", "--", "-plain with spaces" }, @as(u8, 0), compressed, "" },
        .{ &.{ executable, "compress", "--fast", "--", "-plain with spaces" }, @as(u8, 0), compressed, "" },
        .{ &.{ executable, "compress", "--even", "--", "-plain with spaces" }, @as(u8, 0), compressed, "" },
        .{ &.{ executable, "compress", "--dense", "--", "-plain with spaces" }, @as(u8, 0), compressed, "" },
        .{ &.{ executable, "compress", "missing.plain" }, @as(u8, 1), "", "zipir: FileNotFound\n" },
    };
    inline for (cases) |case| {
        const result = try std.process.run(allocator, io, .{ .argv = case[0], .cwd = .{ .dir = tmp.dir } });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = case[1] }, result.term);
        try std.testing.expectEqualStrings(case[2], result.stdout);
        try std.testing.expectEqualStrings(case[3], result.stderr);
    }
    const help = try std.process.run(allocator, io, .{ .argv = &.{ executable, "--help" } });
    defer allocator.free(help.stdout);
    defer allocator.free(help.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, help.term);
    try std.testing.expectEqualStrings("", help.stderr);
    inline for (.{ &.{"unknown"}, &.{ "decompress", "--max-output-bytes" }, &.{ "test", "--max-output-bytes", "-1" }, &.{ "test", "one", "two" }, &.{ "decompress", "--unknown" }, &.{ "compress", "--level" }, &.{ "compress", "--level", "0" }, &.{ "compress", "--level", "2" }, &.{ "compress", "--level", "6" }, &.{ "compress", "--level", "10" }, &.{ "compress", "--level", "256" }, &.{ "compress", "--level", "-1" }, &.{ "compress", "--level", "1", "--level", "9" }, &.{ "compress", "--fast", "--dense" }, &.{ "compress", "--even", "--level", "5" }, &.{ "compress", "--level", "1", "--fast" }, &.{ "decompress", "--fast" }, &.{ "test", "--dense" }, &.{ "compress", "--balanced" }, &.{ "compress", "--max-output-bytes", "1" }, &.{ "decompress", "--level", "5" }, &.{ "compress", "one", "two" } }) |args| {
        var argv: [args.len + 1][]const u8 = undefined;
        argv[0] = executable;
        inline for (args, 0..) |arg, i| argv[i + 1] = arg;
        const bad = try std.process.run(allocator, io, .{ .argv = &argv });
        defer allocator.free(bad.stdout);
        defer allocator.free(bad.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, bad.term);
        try std.testing.expectEqualStrings("", bad.stdout);
        try std.testing.expectEqualStrings(help.stdout, bad.stderr);
    }
    var contents: [seed.len]u8 = undefined;
    const file = try tmp.dir.openFile(io, "-input with spaces.gz", .{});
    defer file.close(io);
    var reader = file.readerStreaming(io, &.{});
    try reader.interface.readSliceAll(&contents);
    try std.testing.expectEqualSlices(u8, seed, &contents);
    const plain = try tmp.dir.openFile(io, "-plain with spaces", .{});
    defer plain.close(io);
    var plain_reader = plain.readerStreaming(io, &.{});
    var original: [1]u8 = undefined;
    try plain_reader.interface.readSliceAll(&original);
    try std.testing.expectEqualSlices(u8, "A", &original);
}

test "[cli] - [format]: --format selects the codec and auto detects gzip and zlib only" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(io, options.executable, allocator);
    defer allocator.free(executable);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gzip = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff\x73\x04\x00\x8b\x9e\xd9\xd3\x01\x00\x00\x00";
    const zlib = "\x78\x5e\x73\x04\x00\x00\x42\x00\x42";
    const raw = "\x73\x04\x00";
    const unknown = "zipir: unknown input format; use --format\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "plain", .data = "A" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.gz", .data = gzip });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zlib", .data = zlib });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.raw", .data = raw });
    try tmp.dir.writeFile(io, .{ .sub_path = "empty", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "text", .data = "hello" });
    const cases = .{
        .{ &.{ executable, "compress", "--format", "gzip", "plain" }, @as(u8, 0), gzip, "" },
        .{ &.{ executable, "compress", "--format", "zlib", "plain" }, @as(u8, 0), zlib, "" },
        .{ &.{ executable, "compress", "--level", "9", "--format", "deflate", "plain" }, @as(u8, 0), raw, "" },
        .{ &.{ executable, "decompress", "a.gz" }, @as(u8, 0), "A", "" },
        .{ &.{ executable, "decompress", "a.zlib" }, @as(u8, 0), "A", "" },
        .{ &.{ executable, "decompress", "--format", "auto", "a.zlib" }, @as(u8, 0), "A", "" },
        .{ &.{ executable, "decompress", "--format", "deflate", "a.raw" }, @as(u8, 0), "A", "" },
        .{ &.{ executable, "test", "--format", "zlib", "--", "a.zlib" }, @as(u8, 0), "", "" },
        .{ &.{ executable, "decompress", "--format", "zlib", "a.gz" }, @as(u8, 1), "", "zipir: UnsupportedMethod\n" },
        .{ &.{ executable, "decompress", "--format", "gzip", "a.zlib" }, @as(u8, 1), "", "zipir: BadHeader\n" },
        .{ &.{ executable, "decompress", "a.raw" }, @as(u8, 2), "", unknown },
        .{ &.{ executable, "test", "text" }, @as(u8, 2), "", unknown },
        .{ &.{ executable, "decompress", "empty" }, @as(u8, 1), "", "zipir: Truncated\n" },
    };
    inline for (cases) |case| {
        const result = try std.process.run(allocator, io, .{ .argv = case[0], .cwd = .{ .dir = tmp.dir } });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = case[1] }, result.term);
        try std.testing.expectEqualStrings(case[2], result.stdout);
        try std.testing.expectEqualStrings(case[3], result.stderr);
    }
    const help = try std.process.run(allocator, io, .{ .argv = &.{ executable, "--help" } });
    defer allocator.free(help.stdout);
    defer allocator.free(help.stderr);
    inline for (.{ &.{ "compress", "--format", "auto" }, &.{ "compress", "--format", "zstd" }, &.{ "decompress", "--format", "Gzip" }, &.{ "decompress", "--format" }, &.{ "decompress", "--format", "zlib", "--format", "zlib" }, &.{ "test", "--format", "" } }) |args| {
        var argv: [args.len + 1][]const u8 = undefined;
        argv[0] = executable;
        inline for (args, 0..) |arg, i| argv[i + 1] = arg;
        const bad = try std.process.run(allocator, io, .{ .argv = &argv });
        defer allocator.free(bad.stdout);
        defer allocator.free(bad.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, bad.term);
        try std.testing.expectEqualStrings("", bad.stdout);
        try std.testing.expectEqualStrings(help.stdout, bad.stderr);
    }
}

fn bgzfBlockSizes(stream: []const u8, sizes: []u32) []u32 {
    var at: usize = 0;
    var n: usize = 0;
    while (at < stream.len) : (n += 1) {
        const size = @as(usize, std.mem.readInt(u16, stream[at + 16 ..][0..2], .little)) + 1;
        sizes[n] = std.mem.readInt(u32, stream[at + size - 4 ..][0..4], .little);
        at += size;
    }
    return sizes[0..n];
}

test "[cli] - [bgzf]: compress, EOF policy, and index follow bgzip's behavior" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(io, options.executable, allocator);
    defer allocator.free(executable);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text = try allocator.alloc(u8, 150000);
    defer allocator.free(text);
    @memcpy(text[0..8], "#header\n");
    for (text[8..], 8..) |*b, i| b.* = if (i % 61 == 0) '\n' else "ACGT"[i * 7 % 4];
    try tmp.dir.writeFile(io, .{ .sub_path = "text", .data = text });
    try tmp.dir.writeFile(io, .{ .sub_path = "plain.gz", .data = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff\x73\x04\x00\x8b\x9e\xd9\xd3\x01\x00\x00\x00" });
    const Run = struct {
        fn run(argv: []const []const u8, dir: std.Io.Dir) !std.process.RunResult {
            return std.process.run(std.testing.allocator, std.testing.io, .{ .argv = argv, .cwd = .{ .dir = dir }, .stdout_limit = .limited(1 << 20) });
        }
    };
    var sizes: [8]u32 = undefined;
    const lines = try Run.run(&.{ executable, "compress", "--format", "bgzf", "text" }, tmp.dir);
    defer allocator.free(lines.stdout);
    defer allocator.free(lines.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, lines.term);
    const line_sizes = bgzfBlockSizes(lines.stdout, &sizes);
    try std.testing.expectEqual(@as(u32, 8), line_sizes[0]);
    try std.testing.expectEqual(@as(u32, 0), line_sizes[line_sizes.len - 1]);
    for (line_sizes[1 .. line_sizes.len - 1]) |size| try std.testing.expect(size <= 65280);
    const binary = try Run.run(&.{ executable, "compress", "--format", "bgzf", "--binary", "text" }, tmp.dir);
    defer allocator.free(binary.stdout);
    defer allocator.free(binary.stderr);
    try std.testing.expectEqualSlices(u32, &.{ 65280, 65280, 150000 - 2 * 65280, 0 }, bgzfBlockSizes(binary.stdout, &sizes));
    try tmp.dir.writeFile(io, .{ .sub_path = "t.gz", .data = binary.stdout });
    try tmp.dir.writeFile(io, .{ .sub_path = "cut.gz", .data = binary.stdout[0 .. binary.stdout.len - 28] });
    const warning = "zipir: warning: EOF marker is absent. The input may be truncated\n";
    const cases = .{
        .{ &.{ executable, "decompress", "t.gz" }, @as(u8, 0), text, "" },
        .{ &.{ executable, "test", "t.gz" }, @as(u8, 0), "", "" },
        .{ &.{ executable, "decompress", "cut.gz" }, @as(u8, 0), text, warning },
        .{ &.{ executable, "test", "cut.gz" }, @as(u8, 1), "", "zipir: MissingEofMarker\n" },
        .{ &.{ executable, "decompress", "--format", "gzip", "cut.gz" }, @as(u8, 0), text, "" },
        .{ &.{ executable, "bgzf", "index", "t.gz" }, @as(u8, 0), "", "" },
        .{ &.{ executable, "bgzf", "index", "--", "t.gz" }, @as(u8, 1), "", "zipir: PathAlreadyExists\n" },
        .{ &.{ executable, "bgzf", "index", "plain.gz" }, @as(u8, 1), "", "zipir: NotBgzf\n" },
    };
    inline for (cases) |case| {
        const result = try Run.run(case[0], tmp.dir);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = case[1] }, result.term);
        try std.testing.expectEqualSlices(u8, case[2], result.stdout);
        try std.testing.expectEqualStrings(case[3], result.stderr);
    }
    var index: [40]u8 = undefined;
    const index_file = try tmp.dir.openFile(io, "t.gz.gzi", .{});
    defer index_file.close(io);
    var index_reader = index_file.readerStreaming(io, &.{});
    try index_reader.interface.readSliceAll(&index);
    try std.testing.expectEqual(@as(u64, index.len), (try index_file.stat(io)).size);
    const first_block = @as(u64, std.mem.readInt(u16, binary.stdout[16..18], .little)) + 1;
    try std.testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, index[0..8], .little));
    try std.testing.expectEqual(first_block, std.mem.readInt(u64, index[8..16], .little));
    try std.testing.expectEqual(@as(u64, 65280), std.mem.readInt(u64, index[16..24], .little));
    try std.testing.expectEqual(@as(u64, 130560), std.mem.readInt(u64, index[32..40], .little));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "plain.gz.gzi", .{}));
    const help = try std.process.run(allocator, io, .{ .argv = &.{ executable, "--help" } });
    defer allocator.free(help.stdout);
    defer allocator.free(help.stderr);
    inline for (.{ &.{ "compress", "--binary" }, &.{ "compress", "--format", "zlib", "--binary" }, &.{ "decompress", "--format", "bgzf" }, &.{ "decompress", "--binary" }, &.{ "compress", "--format", "bgzf", "--binary", "--binary" }, &.{"bgzf"}, &.{ "bgzf", "index" }, &.{ "bgzf", "index", "a", "b" }, &.{ "bgzf", "frob", "a" }, &.{ "bgzf", "index", "-x" }, &.{ "bgzf", "index", "-" } }) |args| {
        var argv: [args.len + 1][]const u8 = undefined;
        argv[0] = executable;
        inline for (args, 0..) |arg, i| argv[i + 1] = arg;
        const bad = try std.process.run(allocator, io, .{ .argv = &argv });
        defer allocator.free(bad.stdout);
        defer allocator.free(bad.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, bad.term);
        try std.testing.expectEqualStrings(help.stdout, bad.stderr);
    }
}

test "[cli] - [tar]: create, list, and test agree in every format, with the end-block policy and path checks" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(io, options.executable, allocator);
    defer allocator.free(executable);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "d/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "d/a.txt", .data = "hello\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "d/sub/b", .data = "x" ** 700 });
    try tmp.dir.symLink(io, "a.txt", "d/s", .{});
    for ([_][]const u8{ "d", "d/a.txt", "d/sub", "d/sub/b" }, [_]u32{ 0o755, 0o640, 0o700, 0o600 }) |path, mode| {
        try tmp.dir.setFilePermissions(io, path, @enumFromInt(mode), .{});
    }
    const link_mode: u32 = @intCast(@intFromEnum((try tmp.dir.statFile(io, "d/s", .{ .follow_symlinks = false })).permissions) & 0o777);
    var link_bits: [9]u8 = undefined;
    for (&link_bits, 0..) |*c, bit| c.* = if (link_mode & (@as(u32, 0o400) >> @intCast(bit)) != 0) "rwxrwxrwx"[bit] else '-';
    var expected_storage: [512]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_storage,
        \\drwxr-xr-x 0 1970-01-01 00:00:00 d/
        \\-rw-r----- 6 1970-01-01 00:00:00 d/a.txt
        \\l{s} 0 1970-01-01 00:00:00 d/s -> a.txt
        \\drwx------ 0 1970-01-01 00:00:00 d/sub/
        \\-rw------- 700 1970-01-01 00:00:00 d/sub/b
        \\
    , .{&link_bits});
    const Run = struct {
        fn run(argv: []const []const u8, dir: std.Io.Dir) !std.process.RunResult {
            return std.process.run(std.testing.allocator, std.testing.io, .{ .argv = argv, .cwd = .{ .dir = dir }, .stdout_limit = .limited(1 << 20) });
        }
    };
    var plain: ?[]u8 = null;
    defer if (plain) |bytes| allocator.free(bytes);
    inline for (.{ "gzip", "zlib", "bgzf", "none" }) |format| {
        const created = try Run.run(&.{ executable, "tar", "create", "--format", format, "--fast", "d" }, tmp.dir);
        defer allocator.free(created.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, created.term);
        try std.testing.expectEqualStrings("", created.stderr);
        try tmp.dir.writeFile(io, .{ .sub_path = "d." ++ format, .data = created.stdout });
        if (std.mem.eql(u8, format, "none")) plain = created.stdout else allocator.free(created.stdout);
        const listed = try Run.run(&.{ executable, "tar", "list", "d." ++ format }, tmp.dir);
        defer allocator.free(listed.stdout);
        defer allocator.free(listed.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, listed.term);
        try std.testing.expectEqualStrings(expected, listed.stdout);
        try std.testing.expectEqualStrings("", listed.stderr);
    }
    const archive = plain.?;
    try tmp.dir.writeFile(io, .{ .sub_path = "cut.tar", .data = archive[0 .. archive.len - 1024] });
    var corrupt: [512]u8 = archive[0..512].*;
    corrupt[0] ^= 1;
    try tmp.dir.writeFile(io, .{ .sub_path = "corrupt.tar", .data = &corrupt });
    const cases = .{
        .{ &.{ executable, "tar", "test", "d.gzip" }, @as(u8, 0), "", "" },
        .{ &.{ executable, "tar", "test", "--format", "none", "--", "d.none" }, @as(u8, 0), "", "" },
        .{ &.{ executable, "tar", "list", "cut.tar" }, @as(u8, 0), expected, "zipir: warning: end-of-archive blocks are absent. The archive may be truncated\n" },
        .{ &.{ executable, "tar", "test", "cut.tar" }, @as(u8, 1), "", "zipir: MissingEndMarker\n" },
        .{ &.{ executable, "tar", "test", "--format", "none", "corrupt.tar" }, @as(u8, 1), "", "zipir: BadHeaderChecksum\n" },
        .{ &.{ executable, "tar", "test", "corrupt.tar" }, @as(u8, 2), "", "zipir: unknown input format; use --format\n" },
        .{ &.{ executable, "decompress", "d.none" }, @as(u8, 2), "", "zipir: unknown input format; use --format\n" },
        .{ &.{ executable, "tar", "create", "/d" }, @as(u8, 1), "", "zipir: UnsafePath\n" },
        .{ &.{ executable, "tar", "create", "d/../d" }, @as(u8, 1), "", "zipir: UnsafePath\n" },
        .{ &.{ executable, "tar", "list", "missing.tar" }, @as(u8, 1), "", "zipir: FileNotFound\n" },
    };
    inline for (cases) |case| {
        const result = try Run.run(case[0], tmp.dir);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = case[1] }, result.term);
        try std.testing.expectEqualStrings(case[2], result.stdout);
        try std.testing.expectEqualStrings(case[3], result.stderr);
    }
    const help = try std.process.run(allocator, io, .{ .argv = &.{ executable, "--help" } });
    defer allocator.free(help.stdout);
    defer allocator.free(help.stderr);
    inline for (.{ &.{"tar"}, &.{ "tar", "frob" }, &.{ "tar", "list", "a", "b" }, &.{ "tar", "create" }, &.{ "tar", "list", "--level", "5" }, &.{ "tar", "list", "--dense" }, &.{ "tar", "create", "--fast", "--even", "d" }, &.{ "tar", "create", "--format", "auto", "d" }, &.{ "tar", "list", "--format", "deflate" }, &.{ "tar", "create", "--level", "2", "d" }, &.{ "tar", "list", "--format", "none", "--format", "none" }, &.{ "tar", "list", "-x" } }) |args| {
        var argv: [args.len + 1][]const u8 = undefined;
        argv[0] = executable;
        inline for (args, 0..) |arg, i| argv[i + 1] = arg;
        const bad = try std.process.run(allocator, io, .{ .argv = &argv });
        defer allocator.free(bad.stdout);
        defer allocator.free(bad.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, bad.term);
        try std.testing.expectEqualStrings(help.stdout, bad.stderr);
    }
}
