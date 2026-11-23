//! zipir's long and heavy correctness checks, as their own package: zipir is imported by path, so a check sees only
//! the public module, and the root build registers nothing from here. `-Dbudget` sets the size: `seed` (seconds, what
//! CI runs), `full` (the contract suites at the size each long property was written for), `long` (a campaign).
//!
//! `zig build check` runs everything at the budget. `zig build suites` runs the contract suites of `tests/`, the same
//! files `zig build test` runs at unit scale, at `full` or `long` (at `seed` it only compiles them).

const std = @import("std");

const Budget = enum { seed, full, long };
const TestScale = enum { unit, full, long };

const FIXTURES = [_][2][]const u8{
    .{ "short6", "short6.gz" },
    .{ "long_codes", "long-codes.gz" },
    .{ "repeat_zero", "repeat-zero.gz" },
    .{ "fixed_codes", "fixed-codes.gz" },
    .{ "empty_single", "empty-single.gz" },
    .{ "final_stored", "final-stored-concat.gz" },
    .{ "tar_ustar", "tar-ustar.tar" },
    .{ "tar_pax", "tar-pax.tar" },
};

const SUITES = [_][]const u8{ "gzip", "zlib", "deflate", "bgzf", "tar", "reader", "writer", "checksum" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const budget = b.option(Budget, "budget", "seed: seconds; full: the suites at full size; long: a campaign") orelse .seed;
    const planted = b.option(bool, "planted", "Build only the fuzz target with a planted crash (fuzz.sh --self-check)") orelse false;
    const filter = b.option([]const u8, "filter", "Build only the fuzz targets whose name contains this text");
    const zipir = b.dependency("zipir", .{ .target = target, .optimize = optimize });

    const scale_options = b.addOptions();
    scale_options.addOption(TestScale, "scale", switch (budget) {
        .seed, .full => .full,
        .long => .long,
    });
    const scale = scale_options.createModule();

    const support = b.createModule(.{
        .root_source_file = zipir.path("tests/support.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "scale", .module = scale }, .{ .name = "zipir", .module = zipir.module("zipir") } },
    });
    const fixture_files = b.addWriteFiles();
    var fixture_source: std.ArrayList(u8) = .empty;
    fixture_source.appendSlice(b.allocator, "pub const zlib_a = \"\\x78\\x5e\\x73\\x04\\x00\\x00\\x42\\x00\\x42\";\npub const raw_a = \"\\x73\\x04\\x00\";\n") catch @panic("OOM");
    for (FIXTURES) |fixture| {
        _ = fixture_files.addCopyFile(zipir.path(b.fmt("tests/data/synthetic/{s}", .{fixture[1]})), fixture[1]);
        fixture_source.appendSlice(b.allocator, b.fmt("pub const {s} = @embedFile(\"{s}\");\n", .{ fixture[0], fixture[1] })) catch @panic("OOM");
    }
    const fixtures = b.createModule(.{ .root_source_file = fixture_files.add("fixtures.zig", fixture_source.items) });

    const fuzz_options = b.addOptions();
    fuzz_options.addOption(bool, "planted", planted);
    const fuzz = b.addTest(.{
        .name = "fuzz",
        .filters = if (planted) &.{"planted"} else if (filter) |text| b.dupeStrings(&.{text}) else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zipir", .module = zipir.module("zipir") },
                .{ .name = "support", .module = support },
                .{ .name = "fixtures", .module = fixtures },
                .{ .name = "fuzz_options", .module = fuzz_options.createModule() },
            },
        }),
    });
    const fuzz_step = b.step("fuzz", "Run the fuzz targets over their seeds, or a campaign with --fuzz=N in ReleaseSafe");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz).step);

    const all = b.step("check", "Run every check at the budget");
    all.dependOn(fuzz_step);
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
