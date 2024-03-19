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

pub fn BitPacking(comptime FL: type) type {
    return struct {
        pub fn encode(comptime W: comptime_int, in: *const FL.Vector, out: *FL.PackedBytes(W)) void {
            comptime var packer = FL.bitpacker(W);
            var tmp: FL.MM1024 = undefined;
            // FIXME(ngates): this pack function doesn't work if the loop isn't inlined at comptime.
            //  We should either accept i as an argument to make it harder to misuse? Or avoid stateful packers?
            inline for (0..FL.T) |i| {
                tmp = packer.pack(out, FL.load(in, i), tmp);
            }
        }

        pub fn decode(comptime W: comptime_int, in: *const FL.PackedBytes(W), out: *FL.Vector) void {
            comptime var unpacker = FL.bitunpacker(W);
            var tmp: FL.MM1024 = undefined;
            inline for (0..FL.T) |i| {
                const next, tmp = unpacker.unpack(in, tmp);
                FL.store(out, i, next);
            }
        }
    };
}

test "bitpack" {
    const std = @import("std");
    const fl = @import("./fastlanez.zig");
    const BP = BitPacking(fl.FastLanez(u8));

    const ints: [1024]u8 = .{2} ** 1024;
    var packed_ints: [384]u8 = undefined;
    BP.encode(3, &ints, &packed_ints);

    // Decimal 2 repeated as 3-bit integers in blocks of 1024 bits.
    try std.testing.expectEqual(
        .{0b10010010} ** 128 ++ .{0b00100100} ** 128 ++ .{0b01001001} ** 128,
        packed_ints,
    );

    var output: [1024]u8 = undefined;
    BP.decode(3, &packed_ints, &output);
    try std.testing.expectEqual(.{2} ** 1024, output);
}

test "bitpack range" {
    const std = @import("std");
    const fl = @import("./fastlanez.zig");
    const BP = BitPacking(fl.FastLanez(u8));

    const W = 6;

    var ints: [1024]u8 = undefined;
    for (0..1024) |i| {
        ints[i] = @intCast(i % std.math.maxInt(std.meta.Int(.unsigned, W)));
    }

    var packed_ints: [128 * W]u8 = undefined;
    BP.encode(W, &ints, &packed_ints);

    var output: [1024]u8 = undefined;
    BP.decode(W, &packed_ints, &output);
    try std.testing.expectEqual(ints, output);
}
