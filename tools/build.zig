//! Build one selected comparison adapter. zipir adapters use the library package as a path dependency.

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
            .{ .name = "adapter", .module = adapterModule(b, target, optimize) },
        }, null);
    } else if (std.mem.eql(u8, adapter, "std-zlib")) {
        installZig(b, target, optimize, strip, "std-zlib", b.path("zig/std_zlib.zig"), &.{
            .{ .name = "adapter", .module = adapterModule(b, target, optimize) },
        }, null);
    } else if (std.mem.startsWith(u8, adapter, "zipir-")) {
        const format = adapter["zipir-".len..];
        const known = [_][]const u8{ "gzip", "zlib", "deflate", "bgzf" };
        for (known) |name| {
            if (std.mem.eql(u8, format, name)) break;
        } else std.debug.panic("unknown adapter: {s}", .{adapter});
        const zipir = b.dependency("zipir", .{ .target = target, .optimize = optimize }).module("zipir");
        const options = b.addOptions();
        options.addOption([]const u8, "format", format);
        installZig(b, target, optimize, strip, adapter, b.path("zig/zipir.zig"), &.{
            .{ .name = "adapter", .module = adapterModule(b, target, optimize) },
            .{ .name = "zipir", .module = zipir },
        }, options);
    } else {
        std.debug.panic("unknown adapter: {s}", .{adapter});
    }
}

fn adapterModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("zig/adapter.zig"),
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
    options: ?*std.Build.Step.Options,
) void {
    const module = b.createModule(.{
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .single_threaded = true,
        .imports = imports,
    });
    if (options) |build_options| module.addOptions("build_options", build_options);
    b.installArtifact(b.addExecutable(.{
        .name = name,
        .root_module = module,
    }));
}
