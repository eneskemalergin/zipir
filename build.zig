//! Build zipir.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const adler_backend = b.option(
        []const u8,
        "adler-backend",
        "Adler-32 backend: dispatch or scalar",
    ) orelse "dispatch";
    if (!std.mem.eql(u8, adler_backend, "dispatch") and !std.mem.eql(u8, adler_backend, "scalar")) {
        std.debug.panic("unsupported Adler-32 backend: {s}", .{adler_backend});
    }

    const mod = b.addModule("zipir", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const adler_options = b.addOptions();
    adler_options.addOption([]const u8, "backend", adler_backend);
    mod.addOptions("adler_options", adler_options);
    addAdlerBackend(b, mod, target, optimize);

    const exe = b.addExecutable(.{
        .name = "zipir",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
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
            .root_source_file = b.path("src/kernel/adler32_x86_avx2.zig"),
            .target = avx2_target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });
    module.addObject(avx2);
}
