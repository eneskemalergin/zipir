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
    const adler_backend = b.option(
        []const u8,
        "adler-backend",
        "Adler-32 backend: dispatch or scalar",
    ) orelse "dispatch";
    if (!std.mem.eql(u8, adler_backend, "dispatch") and !std.mem.eql(u8, adler_backend, "scalar")) {
        std.debug.panic("unsupported Adler-32 backend: {s}", .{adler_backend});
    }

    if (std.mem.eql(u8, adapter, "std-gzip")) {
        installZig(b, target, optimize, strip, "std-gzip", b.path("zig/std_gzip.zig"), &.{
            .{ .name = "args", .module = argsModule(b, target, optimize) },
        });
    } else if (std.mem.eql(u8, adapter, "std-zlib")) {
        installZig(b, target, optimize, strip, "std-zlib", b.path("zig/std_zlib.zig"), &.{
            .{ .name = "args", .module = argsModule(b, target, optimize) },
        });
    } else if (std.mem.eql(u8, adapter, "zipir-gzip") or
        std.mem.eql(u8, adapter, "zipir-zlib"))
    {
        const format = if (std.mem.eql(u8, adapter, "zipir-gzip")) "gzip" else "zlib";
        const zipir = b.createModule(.{
            .root_source_file = b.path("../src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        const adler_options = b.addOptions();
        adler_options.addOption([]const u8, "backend", adler_backend);
        zipir.addOptions("adler_options", adler_options);
        addAdlerBackend(b, zipir, target, optimize);
        const options = b.addOptions();
        options.addOption([]const u8, "format", format);
        installZigWithOptions(b, target, optimize, strip, adapter, b.path("zig/zipir.zig"), &.{
            .{ .name = "args", .module = argsModule(b, target, optimize) },
            .{ .name = "zipir", .module = zipir },
        }, options);
    } else {
        std.debug.panic("unknown adapter: {s}", .{adapter});
    }
}

fn addAdlerBackend(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    if (target.result.cpu.arch != .x86_64) return;

    var avx2_query = target.query;
    avx2_query.cpu_model = .baseline;
    avx2_query.cpu_features_add = .empty;
    avx2_query.cpu_features_sub = .empty;
    avx2_query.cpu_features_add.addFeatureSet(std.Target.x86.featureSet(&.{.avx2}));
    const avx2_target = b.resolveTargetQuery(avx2_query);
    const avx2 = b.addObject(.{
        .name = "adler32_x86_avx2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("../src/adler32_x86_avx2.zig"),
            .target = avx2_target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });
    module.addObject(avx2);
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
    installZigWithOptions(b, target, optimize, strip, name, root, imports, null);
}

fn installZigWithOptions(
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
