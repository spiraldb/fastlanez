// (c) Copyright 2024 Fulcrum Technologies, Inc. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cycleclock_dep = b.dependency("zig-cycleclock", .{
        .target = target,
        .optimize = optimize,
    });

    const module = b.addModule("fastlanez", .{
        .root_source_file = .{ .path = "src/fastlanez.zig" },
        .imports = &.{
            .{ .name = "cycleclock", .module = cycleclock_dep.module("cycleclock") },
        },
    });

    // Static Library
    const lib = b.addStaticLibrary(.{
        .name = "fastlanez",
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/lib.zig" },
    });
    const lib_install = b.addInstallArtifact(lib, .{});

    // Ideally we would use dlib.getEmittedH(), but https://github.com/ziglang/zig/issues/18497
    _ = lib.getEmittedH(); // Needed to trigger header generation
    const lib_header = b.addInstallFile(.{ .path = "zig-cache/fastlanez.h" }, "include/fastlanez.h");
    lib_header.step.dependOn(&lib_install.step);

    const lib_step = b.step("lib", "Build static C library");
    lib_step.dependOn(&lib_header.step);
    lib_step.dependOn(&lib_install.step);

    // Unit Tests
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/fastlanez.zig" },
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.import_table = module.import_table;
    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.step.dependOn(b.getInstallStep());
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Benchmarking
    const bench = b.addTest(.{
        .root_source_file = .{ .path = "src/bench.zig" },
        .target = target,
        .optimize = optimize,
        .filter = "bench",
    });
    bench.root_module.import_table = module.import_table;
    const run_bench = b.addRunArtifact(bench);
    run_bench.step.dependOn(b.getInstallStep());
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);
}
