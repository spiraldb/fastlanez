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
const BitPacking = @import("./bitpacking.zig").BitPacking;
const gpa = std.testing.allocator;

test "bench bitpacking pack" {
    inline for (.{ u8, u16, u32, u64 }) |E| {
        const FL = fl.FastLanez(E);
        inline for (1..@bitSizeOf(E)) |W| {
            const dbg = @import("builtin").mode == .Debug;
            if (comptime dbg and !std.math.isPowerOfTwo(W)) {
                // Avoid too much code-gen in debug mode.
                continue;
            }

            try Bench("pack", @typeName(FL.E) ++ "_" ++ @typeName(std.meta.Int(.unsigned, W)), .{}).bench(struct {
                ints: *const FL.Vector,
                packed_bytes: *FL.PackedBytes(W),

                pub fn setup() !@This() {
                    const ints = try gpa.create(FL.Vector);
                    for (0..1024) |i| {
                        ints[i] = @intCast(i % W);
                    }
                    const packed_bytes = try gpa.create(FL.PackedBytes(W));
                    return .{ .ints = ints, .packed_bytes = packed_bytes };
                }

                pub fn deinit(self: *const @This()) void {
                    gpa.destroy(self.ints);
                    gpa.destroy(self.packed_bytes);
                }

                pub fn run(self: *const @This()) void {
                    BitPacking(FL).encode(W, self.ints, self.packed_bytes);
                    std.mem.doNotOptimizeAway(self.packed_bytes);
                }
            });
        }
    }
}

test "bench bitpacking unpack" {
    inline for (.{ u8, u16, u32, u64 }) |E| {
        const FL = fl.FastLanez(E);
        inline for (1..@bitSizeOf(E)) |W| {
            const dbg = @import("builtin").mode == .Debug;
            if (comptime dbg and !std.math.isPowerOfTwo(W)) {
                // Avoid too much code-gen in debug mode.
                continue;
            }

            try Bench("unpack", @typeName(FL.E) ++ "_" ++ @typeName(std.meta.Int(.unsigned, W)), .{}).bench(struct {
                ints: *FL.Vector,
                packed_bytes: *const FL.PackedBytes(W),

                pub fn setup() !@This() {
                    const ints = try gpa.create(FL.Vector);
                    const packed_bytes = try gpa.create(FL.PackedBytes(W));
                    for (0..@sizeOf(FL.PackedBytes(W))) |i| {
                        packed_bytes[i] = 5; // Set every byte to 5...
                    }
                    return .{ .ints = ints, .packed_bytes = packed_bytes };
                }

                pub fn deinit(self: *const @This()) void {
                    gpa.destroy(self.ints);
                    gpa.destroy(self.packed_bytes);
                }

                pub fn run(self: *const @This()) void {
                    BitPacking(FL).decode(W, self.packed_bytes, self.ints);
                    std.mem.doNotOptimizeAway(self.ints);
                }
            });
        }
    }
}
