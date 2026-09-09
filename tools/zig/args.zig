//! Shared argv for comparison adapters.

const std = @import("std");

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

    var level: ?u8 = null;
    var op = first;
    if (std.mem.eql(u8, first, "--level")) {
        level = try parseLevel(it.next() orelse return error.InvalidArguments);
        op = it.next() orelse return error.InvalidArguments;
    }

    if (std.mem.eql(u8, op, "compress")) {
        if (level == null) {
            const flag = it.next() orelse return error.InvalidArguments;
            if (!std.mem.eql(u8, flag, "--level")) return error.InvalidArguments;
            level = try parseLevel(it.next() orelse return error.InvalidArguments);
        }
        const in_path = it.next() orelse return error.InvalidArguments;
        const out_path = it.next() orelse return error.InvalidArguments;
        if (it.next() != null) return error.InvalidArguments;
        return .{ .compress = .{ .level = level.?, .in_path = in_path, .out_path = out_path } };
    }

    if (std.mem.eql(u8, op, "decompress")) {
        if (level != null) return error.InvalidArguments;
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
