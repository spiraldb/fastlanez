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
const fl = @import("./fastlanez.zig");
const Bench = @import("bench.zig").Bench;
const FFoR = @import("./ffor.zig").FFoR;
const gpa = std.testing.allocator;

test "bench ffor pack" {
    inline for (.{ u8, u16, u32, u64 }) |E| {
        const FL = fl.FastLanez(E);
        inline for (1..@bitSizeOf(E)) |W| {
            const dbg = @import("builtin").mode == .Debug;
            if (comptime dbg and !std.math.isPowerOfTwo(W)) {
                // Avoid too much code-gen in debug mode.
                continue;
            }

            try Bench("ffor_pack", @typeName(FL.E) ++ "_" ++ @typeName(std.meta.Int(.unsigned, W)), .{}).bench(struct {
                input: *const FL.Vector,
                output: *FL.PackedBytes(W),

                pub fn setup() !@This() {
                    const input = try gpa.create(FL.Vector);
                    input.* = .{5} ** 1024;
                    return .{ .input = input, .output = try gpa.create(FL.PackedBytes(W)) };
                }

                pub fn deinit(self: *const @This()) void {
                    gpa.destroy(self.input);
                    gpa.destroy(self.output);
                }

                pub fn run(self: *const @This()) void {
                    FFoR(FL).encode(W, 2, self.input, self.output);
                    std.mem.doNotOptimizeAway(self.output);
                }
            });
        }
    }
}
