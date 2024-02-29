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
const fl = @import("fastlanez.zig");
const Bench = @import("bench.zig").Bench;
const Delta = @import("./delta.zig").Delta;
const arange = @import("helper.zig").arange;
const gpa = std.testing.allocator;

test "bench delta encode" {
    inline for (.{ u8, u16, u32, u64 }) |T| {
        const FL = fl.FastLanez(T);

        try Bench("delta_encode", @typeName(T), .{}).bench(struct {
            base: FL.BaseVector,
            input: *const FL.Vector,
            output: *FL.Vector,

            pub fn setup() !@This() {
                const input = try gpa.create(FL.Vector);
                input.* = FL.transpose(arange(T, 1024));
                const output = try gpa.create(FL.Vector);
                return .{
                    .base = [_]T{0} ** (1024 / @bitSizeOf(T)),
                    .input = input,
                    .output = output,
                };
            }

            pub fn deinit(self: *const @This()) void {
                gpa.free(self.input);
                gpa.free(self.output);
            }

            pub fn run(self: *const @This()) void {
                @call(.never_inline, Delta(FL).encode, .{ &self.base, self.input, self.output });
                std.mem.doNotOptimizeAway(self.output);
            }
        });
    }
}

test "bench delta decode" {
    inline for (.{ u8, u16, u32, u64 }) |T| {
        const FL = fl.FastLanez(T);

        try Bench("delta_decode", @typeName(T), .{}).bench(struct {
            base: FL.BaseVector,
            input: *const FL.Vector,
            output: *FL.Vector,

            pub fn setup() !@This() {
                const input = try gpa.create(FL.Vector);
                input.* = .{1} ** 1024;
                const output = try gpa.create(FL.Vector);
                return .{
                    .base = [_]T{0} ** (1024 / @bitSizeOf(T)),
                    .input = input,
                    .output = output,
                };
            }

            pub fn deinit(self: *const @This()) void {
                gpa.destroy(self.input);
                gpa.destroy(self.output);
            }

            pub fn run(self: @This()) void {
                Delta(FL).decode(&self.base, self.input, self.output);
                std.mem.doNotOptimizeAway(self.output);
            }
        });
    }
}

test "bench delta pack" {
    inline for (.{ u8, u16, u32, u64 }) |T| {
        const FL = fl.FastLanez(T);
        const W = 3;

        try Bench("delta_pack", @typeName(T) ++ "_" ++ @typeName(std.meta.Int(.unsigned, W)), .{}).bench(struct {
            base: FL.BaseVector = [_]T{0} ** (1024 / @bitSizeOf(T)),
            input: *const FL.Vector,
            output: *FL.PackedBytes(W),

            pub fn setup() !@This() {
                const input = try gpa.create(FL.Vector);
                input.* = .{1} ** 1024;
                return .{ .input = input, .output = try gpa.create(FL.PackedBytes(W)) };
            }

            pub fn deinit(self: *const @This()) void {
                gpa.destroy(self.input);
                gpa.destroy(self.output);
            }

            pub fn run(self: @This()) void {
                Delta(FL).pack(3, &self.base, self.input, self.output);
                std.mem.doNotOptimizeAway(self.output);
            }
        });
    }
}

test "bench delta unpack" {
    inline for (.{ u8, u16, u32, u64 }) |T| {
        const FL = fl.FastLanez(T);
        const W = 3;

        try Bench("delta_unpack", @typeName(T) ++ "_" ++ @typeName(std.meta.Int(.unsigned, W)), .{}).bench(struct {
            base: FL.BaseVector,
            delta: *const FL.PackedBytes(W),
            output: *FL.Vector,

            pub fn setup() !@This() {
                const base = [_]T{0} ** (1024 / @bitSizeOf(T));
                const input: FL.Vector = .{1} ** 1024;
                const delta: *FL.PackedBytes(W) = try gpa.create(FL.PackedBytes(W));
                Delta(FL).pack(3, &base, &input, delta);
                return .{
                    .base = base,
                    .delta = delta,
                    .output = try gpa.create(FL.Vector),
                };
            }

            pub fn deinit(self: *const @This()) void {
                gpa.destroy(self.delta);
                gpa.destroy(self.output);
            }

            pub fn run(self: *const @This()) void {
                Delta(FL).unpack(3, &self.base, self.delta, self.output);
                std.mem.doNotOptimizeAway(self.output);
            }
        });
    }
}
