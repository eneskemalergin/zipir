//! Checks gzip command output, failures and file preservation.

const std = @import("std");

test "[cli] - [gzip]: command status and byte streams preserve source files" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(io, @import("options").executable, allocator);
    defer allocator.free(executable);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const seed = @embedFile("data/synthetic/repeat-zero.gz");
    try tmp.dir.writeFile(io, .{ .sub_path = "-input with spaces.gz", .data = seed });
    try tmp.dir.writeFile(io, .{ .sub_path = "truncated.gz", .data = seed[0 .. seed.len - 1] });
    const cases = .{
        .{ &.{executable}, @as(u8, 0), "z_flate 0.0.0\n", "" },
        .{ &.{ executable, "--version" }, @as(u8, 0), "z_flate 0.0.0\n", "" },
        .{ &.{ executable, "decompress", "--", "-input with spaces.gz" }, @as(u8, 0), "A", "" },
        .{ &.{ executable, "test", "--", "-input with spaces.gz" }, @as(u8, 0), "", "" },
        .{ &.{ executable, "decompress", "--max-output-bytes", "0", "--", "-input with spaces.gz" }, @as(u8, 1), "", "z_flate: OutputLimitExceeded\n" },
        .{ &.{ executable, "decompress", "truncated.gz" }, @as(u8, 1), "", "z_flate: Truncated\n" },
        .{ &.{ executable, "decompress", "missing.gz" }, @as(u8, 1), "", "z_flate: FileNotFound\n" },
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
    inline for (.{ &.{"unknown"}, &.{ "decompress", "--max-output-bytes" }, &.{ "test", "--max-output-bytes", "-1" }, &.{ "test", "one", "two" }, &.{ "decompress", "--unknown" } }) |args| {
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
}
