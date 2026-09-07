//! Command-line entry for z_flate.

const std = @import("std");
const z_flate = @import("z_flate");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    try stdout.interface.print("z_flate {d}.{d}.{d}\n", .{
        z_flate.version.major,
        z_flate.version.minor,
        z_flate.version.patch,
    });
    try stdout.interface.flush();
}
