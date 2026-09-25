//! Build zipir.

const std = @import("std");

const KernelBackend = enum { dispatch, portable };
const Mode = enum { direct, object, absent };

// Every CPU-specific kernel, wired only here (plan/design/dispatch.md).
const backends = [_]struct { name: []const u8, features: []const std.Target.x86.Feature }{
    .{ .name = "crc32_x86_pclmul", .features = &.{ .pclmul, .sse4_1 } },
    .{ .name = "adler32_x86_avx2", .features = &.{.avx2} },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const kernel_backend = b.option(
        KernelBackend,
        "kernel-backend",
        "dispatch: pick kernels for the running CPU; portable: force every kernel to its portable twin",
    ) orelse .dispatch;

    const mod = b.addModule("zipir", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const kernel_options = b.addOptions();
    kernel_options.addOption(KernelBackend, "kernel_backend", kernel_backend);
    kernel_options.addOption(bool, "as_object", false);
    for (backends) |backend| {
        const mode = backendMode(target, backend.features);
        kernel_options.addOption(Mode, backend.name, mode);
        if (mode == .object) mod.addObject(backendObject(b, target, optimize, backend.name, backend.features));
    }
    mod.addOptions("kernel_options", kernel_options);

    const exe = b.addExecutable(.{
        .name = "zipir",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .strip = optimize == .ReleaseFast,
            .imports = &.{
                .{ .name = "zipir", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run zipir");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const contracts = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/gzip.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zipir", .module = mod }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(contracts).step);

    const zlib_contracts = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zlib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zipir", .module = mod }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(zlib_contracts).step);

    const cli_options = b.addOptions();
    cli_options.addOptionPath("executable", exe.getEmittedBin());
    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cli_tests.root_module.addOptions("options", cli_options);
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);
}

// A target that guarantees the features imports the backend directly (inlinable, no dispatch);
// another x86_64 target links it as a separate object; other architectures skip it.
fn backendMode(target: std.Build.ResolvedTarget, features: []const std.Target.x86.Feature) Mode {
    if (target.result.cpu.arch != .x86_64) return .absent;
    for (features) |feature| {
        if (!std.Target.x86.featureSetHas(target.result.cpu.features, feature)) return .object;
    }
    return .direct;
}

fn backendObject(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    features: []const std.Target.x86.Feature,
) *std.Build.Step.Compile {
    var query = target.query;
    query.cpu_model = .baseline;
    query.cpu_features_add = .empty;
    query.cpu_features_sub = .empty;
    for (features) |feature| query.cpu_features_add.addFeature(@intFromEnum(feature));
    const object_options = b.addOptions();
    object_options.addOption(bool, "as_object", true);
    const module = b.createModule(.{
        .root_source_file = b.path(b.fmt("src/kernel/{s}.zig", .{name})),
        .target = b.resolveTargetQuery(query),
        .optimize = optimize,
    });
    module.addOptions("kernel_options", object_options);
    return b.addObject(.{ .name = name, .root_module = module, .use_llvm = true });
}
