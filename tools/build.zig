//! Build one selected comparison adapter. Independent of the library build.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
        },
    });
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip adapter symbols") orelse (optimize == .ReleaseFast);
    const adapter = b.option([]const u8, "adapter", "Adapter to build") orelse "std-gzip";

    if (std.mem.eql(u8, adapter, "std-gzip")) {
        installZig(b, target, optimize, strip, "std-gzip", b.path("zig/std_gzip.zig"), &.{
            .{ .name = "args", .module = argsModule(b, target, optimize) },
        });
    } else {
        std.debug.panic("unknown adapter: {s}", .{adapter});
    }
}

fn argsModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("zig/args.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
}

fn installZig(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    name: []const u8,
    root: std.Build.LazyPath,
    imports: []const std.Build.Module.Import,
) void {
    const module = b.createModule(.{
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .single_threaded = true,
        .imports = imports,
    });
    b.installArtifact(b.addExecutable(.{
        .name = name,
        .root_module = module,
    }));
}
