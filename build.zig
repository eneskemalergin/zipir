//! Build z_flate.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("z_flate", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "z_flate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .strip = optimize == .ReleaseFast,
            .imports = &.{
                .{ .name = "z_flate", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run z_flate");
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
            .imports = &.{.{ .name = "z_flate", .module = mod }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(contracts).step);

    const zlib_contracts = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zlib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "z_flate", .module = mod }},
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
