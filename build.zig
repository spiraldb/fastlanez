const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run unit tests");

    const lib = b.addStaticLibrary(.{
        .name = "fastlanez",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    const old_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/fastlanes_old.zig" },
        .target = target,
        .optimize = optimize,
    });
    const run_old_unit_tests = b.addRunArtifact(old_unit_tests);

    test_step.dependOn(&run_old_unit_tests.step);
}
