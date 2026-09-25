//! Shared argv parsing and file handling for the comparison adapters.

const std = @import("std");

pub const IO_BUFFER_LEN = 64 * 1024;

pub const Request = union(enum) {
    version,
    compress: Paths,
    decompress: Paths,
};

pub const Paths = struct {
    level: u8,
    in_path: []const u8,
    out_path: []const u8,
};

pub fn parse(it: *std.process.Args.Iterator) error{InvalidArguments}!Request {
    const first = it.next() orelse return error.InvalidArguments;
    if (std.mem.eql(u8, first, "--version")) {
        if (it.next() != null) return error.InvalidArguments;
        return .version;
    }

    if (std.mem.eql(u8, first, "compress")) {
        const flag = it.next() orelse return error.InvalidArguments;
        if (!std.mem.eql(u8, flag, "--level")) return error.InvalidArguments;
        const level = try parseLevel(it.next() orelse return error.InvalidArguments);
        const in_path = it.next() orelse return error.InvalidArguments;
        const out_path = it.next() orelse return error.InvalidArguments;
        if (it.next() != null) return error.InvalidArguments;
        return .{ .compress = .{ .level = level, .in_path = in_path, .out_path = out_path } };
    }

    if (std.mem.eql(u8, first, "decompress")) {
        const in_path = it.next() orelse return error.InvalidArguments;
        const out_path = it.next() orelse return error.InvalidArguments;
        if (it.next() != null) return error.InvalidArguments;
        return .{ .decompress = .{ .level = 0, .in_path = in_path, .out_path = out_path } };
    }

    return error.InvalidArguments;
}

fn parseLevel(text: []const u8) error{InvalidArguments}!u8 {
    const value = std.fmt.parseInt(u8, text, 10) catch return error.InvalidArguments;
    return value;
}

fn isDash(path: []const u8) bool {
    return std.mem.eql(u8, path, "-");
}

pub fn openIn(io: std.Io, path: []const u8) !std.Io.File {
    if (isDash(path)) return .stdin();
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openFileAbsolute(io, path, .{});
    return std.Io.Dir.cwd().openFile(io, path, .{});
}

pub fn openOut(io: std.Io, path: []const u8) !std.Io.File {
    if (isDash(path)) return .stdout();
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.createFileAbsolute(io, path, .{});
    return std.Io.Dir.cwd().createFile(io, path, .{});
}

pub fn closeIfOwned(io: std.Io, file: std.Io.File, path: []const u8) void {
    if (!isDash(path)) file.close(io);
}
