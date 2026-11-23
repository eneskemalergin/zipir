//! zipir's long and heavy correctness checks, as their own package: zipir is imported by path, so a check sees only
//! the public module, and the root build registers nothing from here. `-Dbudget` sets the size: `seed` (seconds, what
//! CI runs), `full` (the contract suites at the size each long property was written for), `long` (a campaign).
//!
//! `zig build check` runs everything at the budget. `zig build suites` runs the contract suites of `tests/`, the same
//! files `zig build test` runs at unit scale, at `full` or `long` (at `seed` it only compiles them).

const std = @import("std");

const Budget = enum { seed, full, long };
const TestScale = enum { unit, full, long };

const SUITES = [_][]const u8{ "gzip", "zlib", "deflate", "bgzf", "tar", "reader", "writer", "checksum" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const budget = b.option(Budget, "budget", "seed: seconds; full: the suites at full size; long: a campaign") orelse .seed;
    const zipir = b.dependency("zipir", .{ .target = target, .optimize = optimize });

    const scale_options = b.addOptions();
    scale_options.addOption(TestScale, "scale", switch (budget) {
        .seed, .full => .full,
        .long => .long,
    });
    const scale = scale_options.createModule();

    const all = b.step("check", "Run every check at the budget");
    const suites = b.step("suites", "Run the contract suites of tests/ at the budget's scale");
    all.dependOn(suites);
    for (SUITES) |name| {
        const suite = b.addTest(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = zipir.path(b.fmt("tests/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zipir", .module = zipir.module("zipir") },
                    .{ .name = "scale", .module = scale },
                },
            }),
        });
        if (budget == .seed) {
            suites.dependOn(&suite.step);
        } else {
            suites.dependOn(&b.addRunArtifact(suite).step);
        }
    }
}
