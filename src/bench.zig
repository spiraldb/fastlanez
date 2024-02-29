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
const builtin = @import("builtin");
const cycleclock = @import("cycleclock");
const fl = @import("fastlanez.zig");

const dbg = builtin.mode == .Debug;

pub const Options = struct {
    warmup: comptime_int = if (dbg) 0 else 100_000,
    iterations: comptime_int = if (dbg) 1 else 3_000_000,
};

pub fn Bench(comptime name: []const u8, comptime variant: []const u8, comptime options: Options) type {
    return struct {
        pub fn bench(comptime Unit: type) !void {
            std.debug.print("{s},{s},{}", .{ name, variant, options.iterations });

            const unit = if (@hasDecl(Unit, "setup")) try Unit.setup() else Unit{};
            defer if (@hasDecl(Unit, "deinit")) {
                unit.deinit();
            };

            for (0..options.warmup) |_| {
                unit.run();
            }

            const start = cycleclock.now();
            for (0..options.iterations) |_| {
                unit.run();
            }
            const stop = cycleclock.now();
            const cycles = stop - start;

            if (cycles == 0) {
                std.debug.print(",0  # failed to measure cycles\n", .{});
                return;
            } else {
                const cycles_per_tuple = @as(f64, @floatFromInt(cycles)) / @as(f64, @floatFromInt(1024 * options.iterations));
                std.debug.print(",{d:.4}", .{cycles_per_tuple});
                std.debug.print(",{}\n", .{1024 * options.iterations / cycles});
            }
        }
    };
}

comptime {
    std.testing.refAllDecls(@import("bench_bitpacking.zig"));
    std.testing.refAllDecls(@import("bench_delta.zig"));
    std.testing.refAllDecls(@import("bench_ffor.zig"));
}
