const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cycleclock_dep = b.dependency("zig-cycleclock", .{
        .target = target,
        .optimize = optimize,
    });

    const module = b.addModule("fastlanez", .{
        .root_source_file = .{ .path = "src/fastlanes.zig" },
        .imports = &.{
            .{ .name = "cycleclock", .module = cycleclock_dep.module("cycleclock") },
        },
    });

    // Unit Tests
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/fastlanes.zig" },
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.import_table = module.import_table;
    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.step.dependOn(b.getInstallStep());
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
