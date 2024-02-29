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

/// Fused Frame of Reference (FFoR) codec.
pub fn FFoR(comptime FL: type) type {
    return struct {
        pub fn encode(comptime W: comptime_int, reference: FL.E, in: *const FL.Vector, out: *FL.PackedBytes(W)) void {
            comptime var packer = FL.bitpacker(W);
            var tmp: FL.MM1024 = undefined;

            inline for (0..FL.T) |t| {
                const next = FL.subtract(FL.load(in, t), @splat(reference));
                tmp = packer.pack(out, next, tmp);
            }
        }

        pub fn decode(comptime W: comptime_int, reference: FL.E, in: *const FL.PackedBytes(W), out: *FL.Vector) void {
            comptime var packer = FL.bitunpacker(W);
            var tmp: FL.MM1024 = undefined;

            inline for (0..FL.T) |t| {
                const next, tmp = packer.unpack(in, tmp);
                FL.store(out, t, FL.add(next, @splat(reference)));
            }
        }
    };
}

test "fastlanez ffor" {
    const std = @import("std");
    const fl = @import("fastlanez.zig");

    const E = u16;
    const W = 3;
    const FL = fl.FastLanez(E);

    const input: FL.Vector = .{5} ** 1024;
    var output: FL.PackedBytes(W) = undefined;
    FFoR(FL).encode(W, 3, &input, &output);

    var decoded: FL.Vector = undefined;
    FFoR(FL).decode(W, 3, &output, &decoded);

    try std.testing.expectEqual(input, decoded);
}
