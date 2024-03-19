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

// This unified transpose layout allows us to operate efficiently using a variety of SIMD lane widths.
const ORDER: [8]u8 = .{ 0, 4, 2, 6, 1, 5, 3, 7 };

// Comptime compute the transpose and untranspose masks.
const transpose_mask: [1024]comptime_int = blk: {
    @setEvalBranchQuota(4096);
    var mask: [1024]comptime_int = undefined;
    var mask_idx = 0;
    for (0..8) |row| {
        for (ORDER) |o| {
            for (0..16) |i| {
                mask[mask_idx] = (i * 64) + (o * 8) + row;
                mask_idx += 1;
            }
        }
    }
    break :blk mask;
};

const untranspose_mask: [1024]comptime_int = blk: {
    @setEvalBranchQuota(4096);
    var mask: [1024]comptime_int = undefined;
    for (0..1024) |i| {
        mask[transpose_mask[i]] = i;
    }
    break :blk mask;
};

pub fn FastLanez(comptime Element: type) type {
    return struct {
        /// The type of the element.
        pub const E = Element;
        /// The bit size of the element type.
        pub const T = @bitSizeOf(E);
        /// The number of elements in a single MM1024 word.
        pub const S = 1024 / T;
        /// A vector of 1024 elements.
        pub const Vector = [1024]E;
        /// A vector of 1024 bits.
        pub const BaseVector = [S]E;
        /// Represents the fastlanes virtual 1024-bit SIMD word.
        pub const MM1024 = @Vector(1024 / T, E);

        /// Offset required to iterate over 1024 bit vectors according to the unified transpose order.
        const offsets: [T]u8 = blk: {
            var _offsets: [T]u8 = undefined;
            var offset = 0;
            for (0..T / 8) |order| {
                for (0..8) |row| {
                    _offsets[offset] = order + ((T / 8) * row);
                    offset += 1;
                }
            }
            break :blk _offsets;
        };

        /// Load the nth MM1024 from the input buffer. Respecting the unified transpose order.
        pub inline fn load_transposed(ptr: anytype, n: usize) MM1024 {
            return load(ptr, offsets[n]);
        }

        /// Load the nth MM1024 from the input buffer.
        pub inline fn load(ptr: anytype, n: usize) MM1024 {
            const Array = @typeInfo(@TypeOf(ptr)).Pointer.child;
            const bytes: *const [@sizeOf(Array)]u8 = @ptrCast(ptr);
            return @bitCast(bytes[n * 128 ..][0..128].*);
        }

        /// Store the nth MM1024 into the output buffer. Respecting the unified transpose order.
        pub inline fn store_transposed(ptr: anytype, n: usize, vec: MM1024) void {
            store(ptr, offsets[n], vec);
        }

        /// Store the nth MM1024 into the output buffer.
        pub inline fn store(ptr: anytype, n: usize, word: MM1024) void {
            const Array = @typeInfo(@TypeOf(ptr)).Pointer.child;
            const words: *[@sizeOf(Array) / 128][128]u8 = @ptrCast(ptr);
            words[n] = @bitCast(word);
        }

        /// Shuffle the input vector into the unified transpose order.
        pub fn transpose(vec: Vector) Vector {
            const V = @Vector(1024, E);
            return @shuffle(E, @as(V, vec), @as(V, vec), transpose_mask);
        }

        /// Unshuffle the input vector from the unified transpose order.
        pub fn untranspose(vec: Vector) Vector {
            const V = @Vector(1024, E);
            return @shuffle(E, @as(V, vec), @as(V, vec), untranspose_mask);
        }

        /// A type representing an array of packed bytes.
        pub fn PackedBytes(comptime Width: comptime_int) type {
            return [128 * Width]u8;
        }

        /// Returns a comptime struct for packing bits into Width-bit integers.
        pub fn bitpacker(comptime Width: comptime_int) BitPacker(Width) {
            return BitPacker(Width){};
        }

        fn BitPacker(comptime Width: comptime_int) type {
            return struct {
                const Self = @This();

                /// The number of times store has been called. The position in the input vector, so to speak.
                t: comptime_int = 0,
                /// The position in the output that we're writing to. Will finish equal to Width.
                out_idx: comptime_int = 0,

                bit_idx: comptime_int = 0,

                /// Invoke to store the next vector.
                /// Called T times, and writes W times. bit_idx tracks how many bits have been written into the result.
                pub inline fn pack(comptime self: *Self, out: *PackedBytes(Width), word: MM1024, state: MM1024) MM1024 {
                    var tmp: MM1024 = undefined;
                    if (self.t == 0) {
                        tmp = @splat(0);
                    } else {
                        tmp = state;
                    }

                    if (self.t > T) {
                        @compileError("BitPacker.pack called too many times");
                    }
                    self.t += 1;

                    const shift_bits = self.bit_idx % T;
                    const mask_bits = @min(T - shift_bits, Width - (self.bit_idx % Width));

                    tmp = or_(tmp, and_lshift(word, shift_bits, bitmask(mask_bits)));
                    self.bit_idx += mask_bits;

                    if (self.bit_idx % T == 0) {
                        // If we have a full T bits, then store it and reset the tmp register
                        store(out, self.out_idx, tmp);
                        tmp = @splat(0);
                        self.out_idx += 1;

                        // Put the remainder of the bits in the next word
                        if (mask_bits < Width) {
                            tmp = or_(tmp, and_rshift(word, mask_bits, bitmask(Width - mask_bits)));
                            self.bit_idx += (Width - mask_bits);
                        }
                    }

                    return tmp;
                }
            };
        }

        /// Returns a comptime struct for unpacking bits from Width-bit integers.
        pub fn bitunpacker(comptime Width: comptime_int) BitUnpacker(Width) {
            return BitUnpacker(Width){};
        }

        fn BitUnpacker(comptime Width: comptime_int) type {
            return struct {
                const Self = @This();

                t: comptime_int = 0,

                input_idx: comptime_int = 0,
                bit_idx: comptime_int = 0,

                pub inline fn unpack(comptime self: *Self, input: *const PackedBytes(Width), state: MM1024) struct { MM1024, MM1024 } {
                    if (self.t > T) {
                        @compileError("BitUnpacker.unpack called too many times");
                    }
                    self.t += 1;

                    var tmp: MM1024 = undefined;
                    if (self.bit_idx % T == 0) {
                        tmp = load(input, self.input_idx);
                        self.input_idx += 1;
                    } else {
                        tmp = state;
                    }

                    const shift_bits = self.bit_idx % T;
                    const mask_bits = @min(T - shift_bits, Width - (self.bit_idx % Width));

                    var next: MM1024 = and_rshift(tmp, shift_bits, bitmask(mask_bits));

                    if (mask_bits != Width) {
                        tmp = load(input, self.input_idx);
                        self.input_idx += 1;

                        next = or_(next, and_lshift(tmp, mask_bits, bitmask(Width - mask_bits)));
                        self.bit_idx += Width;
                    } else {
                        self.bit_idx += mask_bits;
                    }

                    return .{ next, tmp };
                }
            };
        }

        // Create a mask of the first `bits` bits.
        inline fn bitmask(comptime bits: comptime_int) E {
            return (1 << bits) - 1;
        }

        pub inline fn add(a: MM1024, b: MM1024) MM1024 {
            return a +% b;
        }

        pub inline fn subtract(a: MM1024, b: MM1024) MM1024 {
            return a -% b;
        }

        pub inline fn and_(a: MM1024, b: MM1024) MM1024 {
            return a & b;
        }

        pub inline fn or_(a: MM1024, b: MM1024) MM1024 {
            return a | b;
        }

        pub inline fn and_lshift(lane: MM1024, comptime n: comptime_int, comptime mask: E) MM1024 {
            const maskvec: MM1024 = @splat(mask);
            const nvec: MM1024 = @splat(n);
            return (lane & maskvec) << nvec;
        }

        pub inline fn and_rshift(lane: MM1024, comptime n: comptime_int, comptime mask: E) MM1024 {
            const maskvec: MM1024 = @splat(mask << n);
            const nvec: MM1024 = @splat(n);
            return (lane & maskvec) >> nvec;
        }
    };
}

test "fastlanez transpose" {
    const std = @import("std");
    const arange = @import("helper.zig").arange;
    const T = u32;
    const FL = FastLanez(T);

    const input: FL.Vector = arange(T, 1024);
    const transposed = FL.transpose(input);

    try std.testing.expectEqual(transposed[0], 0);
    try std.testing.expectEqual(transposed[1], 64);
    try std.testing.expectEqual(transposed[2], 128);
    try std.testing.expectEqual(transposed[16], 32);
    try std.testing.expectEqual(transposed[1017], 639);
    try std.testing.expectEqual(transposed[1023], 1023);
}

comptime {
    const std = @import("std");

    std.testing.refAllDecls(@import("bitpacking_u8_u3.zig"));
    std.testing.refAllDecls(@import("bitpacking.zig"));
    std.testing.refAllDecls(@import("delta.zig"));
    std.testing.refAllDecls(@import("ffor.zig"));
}
