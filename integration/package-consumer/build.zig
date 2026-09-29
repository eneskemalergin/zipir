//! An outside package that depends on zipir by path, as a dependent project does, and tests the public module.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zipir = b.dependency("zipir", .{ .target = target, .optimize = optimize });
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zipir", .module = zipir.module("zipir") }},
        }),
    });
    b.step("test", "Test the zipir module from an outside package").dependOn(&b.addRunArtifact(tests).step);
}
