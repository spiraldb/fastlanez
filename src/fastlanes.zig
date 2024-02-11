// We always operate on vectors of 1024 elements.
// Elements may be 8, 16, 32, or 64 bits wide. Known as T.
// 1024 / T is the number of SIMD lanes, known as S.

// The question is whether strictly implementing the 1024 bit vectors will
// mean the compiler fails to optimize. e.g. for our u64 ISA, we need to load
// values into a 16 element array of u64s. Instead of iterating over 1 u64 at a time
// inside a single register, we may now have another STORE operation to push
// all this back into memory.

pub fn FastLanez(comptime E: type, comptime ISA: type) type {
    const V = @Vector(1024, E);

    // This unified transpose layout allows us to operate efficiently using a variety of SIMD lane widths.
    const ORDER: [8]u8 = .{ 0, 4, 2, 6, 1, 5, 3, 7 };

    // Comptime compute the transpose and untranspose masks.
    const transpose_mask: [1024]i32 = blk: {
        @setEvalBranchQuota(4096);
        var mask: [1024]i32 = undefined;
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

    const untranspose_mask: [1024]i32 = blk: {
        @setEvalBranchQuota(4096);
        var mask: [1024]i32 = undefined;
        for (0..1024) |i| {
            mask[transpose_mask[i]] = i;
        }
        break :blk mask;
    };

    return struct {
        const T = @bitSizeOf(E);
        const S = 1024 / T;

        /// A FL vector captures 1024 elements of type E.
        const FLVector = [1024]E;
        const FLBase = [S]E;

        /// Represents the fastlanes virtual 1024-bit SIMD register.
        pub const FLMM1024 = ISA.FLMM1024;

        pub const Lane = ISA.Lane;
        const LaneSize = ISA.Width / T;
        const LaneCount = 1024 / ISA.Width;

        /// Wraps a native SIMD operator and invokes it elementwise over a fastlanes vector.
        /// TODO(ngates): does the order matter at all here?
        pub fn elementwise(comptime op: fn (Lane) Lane) fn (FLVector, *FLVector) void {
            const impl = struct {
                pub fn fl_elementwise(in: FLVector, out: *FLVector) void {
                    @setEvalBranchQuota(8192);

                    const in_lanes: [T * LaneCount]Lane = @bitCast(in);
                    const out_lanes: *[T * LaneCount]Lane = @alignCast(@ptrCast(out));

                    inline for (0..LaneCount) |i| {
                        const result = op(in_lanes[i]);
                        out_lanes[i] = result;
                    }
                }
            };

            return impl.fl_elementwise;
        }

        /// Pairwise but looping over 1024 bit vectors.
        pub fn pairwise2(comptime op: fn (ISA.FLMM1024, ISA.FLMM1024) ISA.FLMM1024) fn (FLBase, FLVector, *FLVector) void {
            const impl = struct {
                const std = @import("std");

                pub fn fl_pairwise2(base: FLBase, in: FLVector, out: *FLVector) void {
                    @setEvalBranchQuota(8192);

                    var prev = ISA.load(&base);

                    inline for (0..T / 8) |o| {
                        const order_offset = ORDER[o] * 16;

                        inline for (0..8) |row| { // u32: 8
                            const row_offset = 128 * row;

                            const offset = order_offset + row_offset;
                            const next = ISA.load(in[offset..][0..S]);
                            const result = op(prev, next);
                            ISA.store(result, out[order_offset + row_offset ..][0..S]);
                            prev = next;
                        }
                    }
                }
            };

            return impl.fl_pairwise2;
        }

        /// Wraps a native SIMD operator and invokes it pairwise over a fastlanes vector.
        /// TODO(ngates): the base vector is wrong here. It should be 1024 bits, not 16 elements.
        /// TODO(ngates): this could just be a comptime function to generate a lane indices iterator?
        pub fn pairwise(comptime op: fn (Lane, Lane) Lane) fn (FLBase, FLVector, *FLVector) void {
            const impl = struct {
                pub fn fl_pairwise(base: FLBase, in: FLVector, out: *FLVector) void {
                    @setEvalBranchQuota(8192);

                    // TODO(ngates): should we use ISA.load instead of bitcasting?
                    const base_lanes: [S / LaneSize]Lane = @bitCast(base);
                    const in_lanes: [T * LaneCount]Lane = @bitCast(in);
                    const out_lanes: *[T * LaneCount]Lane = @alignCast(@ptrCast(out));

                    // See Figure 6 in the FastLanes paper for more information about the next few lines.
                    // The unified tranposed layout places 1024 elements into eight 8x16 tiles.
                    // These tiles are ordered as per the ORDER constant above, 04261537.
                    //
                    // There are three loops that are unrolled at compile-time.
                    // First, the loop over the SIMD lanes themselves. Think of this as an offset over the columns of each tile.
                    // Next, we loop over the 8 tiles themselves. This is the tranposed ordering.
                    // Finally, we loop over the rows of each tile.

                    const tile_width_in_elems = 16;
                    const tile_width_in_lanes = tile_width_in_elems / ISA.LaneWidth;

                    const row_width_in_elems = 8 * tile_width_in_elems;
                    const row_width_in_lanes = row_width_in_elems / ISA.LaneWidth;

                    // TODO(ngates): can we loop of FLMM1024 bit vectors instead of native lanes?
                    // That way the code here doesn't depend on bit width and we can push it inside the ISA impls.
                    inline for (0..tile_width_in_lanes) |lane_offset| {
                        var prev_lane: Lane = base_lanes[lane_offset];

                        inline for (ORDER) |o| {
                            const order_offset = o * tile_width_in_lanes;

                            inline for (0..8) |row| {
                                const row_offset = row * row_width_in_lanes;

                                const offset = lane_offset + order_offset + row_offset;

                                // Apply a function to the previous and current lanes.
                                // TODO(ngates): ideally we apply an op from the ISA?
                                const result = op(prev_lane, in_lanes[offset]);
                                out_lanes[offset] = result;
                                prev_lane = in_lanes[offset];
                            }
                        }
                    }
                }
            };

            return impl.fl_pairwise;
        }

        /// Shuffle the input vector into the unified transpose order.
        /// TODO(ngates): not sure there's much better than a scalar loop here.
        pub fn transpose(vec: FLVector) FLVector {
            return @shuffle(E, @as(V, vec), @as(V, vec), transpose_mask);
        }

        /// Unshuffle the input vector from the unified transpose order.
        pub fn untranspose(vec: FLVector) FLVector {
            return @shuffle(E, @as(V, vec), @as(V, vec), untranspose_mask);
        }

        // forall T−bit lanes i in REG return (i & MASK) << N
        inline fn and_lshift(vec: FLVector, n: anytype, mask: FLVector) FLVector {
            // TODO(ngates): can we make this more efficient?
            const nVec: FLVector = @splat(n);
            return (vec & mask) << @intCast(nVec);
        }

        // forall T−bit lanes i in REG return (i & (MASK << N)) >> N
        inline fn and_rshift(vec: FLVector, n: anytype, mask: FLVector) FLVector {
            const nVec: FLVector = @splat(n);
            return (vec & (mask << nVec)) >> @intCast(nVec);
        }
    };
}

/// A FastLanez ISA implemented using 64-bit unsigned integers.
pub fn FastLanez_U64(comptime T: type) type {
    return struct {
        const Width = 64;
        const LaneWidth = 64 / @bitSizeOf(T);
        const Lane = u64;

        inline fn load(elems: *const [Width]T) Lane {
            return @bitCast(elems.*);
        }

        inline fn store(lane: Lane, elems: *[Width]T) void {
            elems.* = @bitCast(lane);
        }

        // forall T−bit lanes i in REG return (i & MASK) << N
        inline fn and_lshift(lane: Lane, n: anytype, mask: Lane) Lane {
            // TODO(ngates): can we make this more efficient?
            const nVec: Lane = @splat(n);
            return (lane & mask) << @intCast(nVec);
        }

        // forall T−bit lanes i in REG return (i & (MASK << N)) >> N
        inline fn and_rshift(lane: Lane, n: anytype, mask: Lane) Lane {
            const nVec: Lane = @splat(n);
            return (lane & (mask << nVec)) >> @intCast(nVec);
        }

        inline fn subtract(a: Lane, b: Lane) Lane {
            const a_vec: [LaneWidth]T = @bitCast(a);
            const b_vec: [LaneWidth]T = @bitCast(b);
            var result: [LaneWidth]T = undefined;
            for (0..LaneWidth) |l| {
                result[l] = a_vec[l] - b_vec[l];
            }
            return @bitCast(result);
        }
    };
}

pub fn FastLanez_ZIMD2(comptime E: type, comptime W: comptime_int) type {
    const nvecs = 1024 / W;
    const nelems = 1024 / @bitSizeOf(E);

    return struct {
        // Our FLMM1024 type.

        pub const FLMM1024 = [nvecs]@Vector(W / @bitSizeOf(E), E);

        inline fn load(elems: *const [nelems]E) FLMM1024 {
            return @bitCast(elems.*);
        }

        inline fn store(register: FLMM1024, elems: *[nelems]E) void {
            elems.* = @bitCast(register);
        }

        inline fn subtract(a: FLMM1024, b: FLMM1024) FLMM1024 {
            var result: FLMM1024 = undefined;
            inline for (0..nvecs) |i| {
                result[i] = a[i] -% b[i];
            }
            return result;
        }
    };
}

/// A FastLanez ISA implemented using Zig SIMD vectors (of configurable width).
pub fn FastLanez_ZIMD(comptime T: type, comptime W: comptime_int) type {
    return struct {
        const Width = W;
        const LaneWidth = W / @bitSizeOf(T);
        const Lane = @Vector(LaneWidth, T);

        inline fn load(elems: *const [LaneWidth]T) Lane {
            return @bitCast(elems.*);
        }

        inline fn store(lane: Lane, elems: *[LaneWidth]T) void {
            elems.* = @bitCast(lane);
        }

        inline fn shuffle(lane: Lane, mask: [LaneWidth]i32) Lane {
            const mask_vec: @Vector(LaneWidth, i32) = @bitCast(mask);
            return @shuffle(T, lane, lane, mask_vec);
        }

        // forall T−bit lanes i in REG return (i & MASK) << N
        inline fn and_lshift(lane: Lane, n: anytype, mask: Lane) Lane {
            // TODO(ngates): can we make this more efficient?
            const nVec: Lane = @splat(n);
            return (lane & mask) << @intCast(nVec);
        }

        // forall T−bit lanes i in REG return (i & (MASK << N)) >> N
        inline fn and_rshift(lane: Lane, n: anytype, mask: Lane) Lane {
            const nVec: Lane = @splat(n);
            return (lane & (mask << nVec)) >> @intCast(nVec);
        }

        inline fn subtract(a: Lane, b: Lane) Lane {
            return a -% b;
        }
    };
}

pub fn Delta(comptime T: type) type {
    const ISA = FastLanez_ZIMD(T, 128);
    // const ISA = FastLanez_U64(T);

    return struct {
        pub const FL = FastLanez(T, ISA);
        pub const FLVector = FL.FLVector;

        pub fn encode(base: FL.FLBase, in: FLVector, out: *FLVector) void {
            // const tin = FL.transpose(in);

            return FL.pairwise(delta)(base, in, out);
        }

        fn delta(acc: FL.Lane, value: FL.Lane) FL.Lane {
            return ISA.subtract(value, acc);
        }
    };
}

pub fn Delta1024(comptime T: type) type {
    const ISA = FastLanez_ZIMD2(T, 128);

    return struct {
        pub const FL = FastLanez(T, ISA);
        pub const FLVector = FL.FLVector;

        pub fn encode(base: FL.FLBase, in: FLVector, out: *FLVector) void {
            // const tin = FL.transpose(in);

            return FL.pairwise2(delta)(base, in, out);
            // return FL.pairwise(delta)(base, tin, out);
        }

        fn delta(acc: FL.FLMM1024, value: FL.FLMM1024) FL.FLMM1024 {
            return ISA.subtract(value, acc);
        }
    };
}

// test "fastlanez simd isa" {
//     const std = @import("std");
//     const T = u32;
//     const FL = FastLanez_SIMD(T);

//     const expected = arange(T);
//     const vec = FL.load(&expected);

//     var actual: [FL_WIDTH]T = undefined;
//     FL.store(vec, &actual);

//     try std.testing.expectEqual(expected, actual);
// }

test "fastlanez transpose" {
    const std = @import("std");
    const T = u32;
    const ISA = FastLanez_ZIMD(T, 128);
    const FL = FastLanez(T, ISA);

    const input: FL.FLVector = arange(T, 1024);
    const transposed = FL.transpose(input);
    const transposed2 = FL.transpose(input);
    _ = transposed2;

    try std.testing.expectEqual(transposed[0], 0);
    try std.testing.expectEqual(transposed[1], 64);
    try std.testing.expectEqual(transposed[2], 128);
    try std.testing.expectEqual(transposed[16], 32);
    try std.testing.expectEqual(transposed[1017], 639);
    try std.testing.expectEqual(transposed[1023], 1023);
}

// test "fastlanez delta" {
//     if (true) return error.skip;
//     const std = @import("std");
//     const T = u32;
//     const Codec = Delta(T);

//     const base = [_]T{0} ** (1024 / @bitSizeOf(T));
//     const input = arange(T, 1024);

//     var actual: [1024]T = undefined;
//     Codec.encode(base, input, &actual);

//     actual = Codec.FL.untranspose(actual);

//     for (0..1024) |i| {
//         // Since fastlanes processes based on 16 blocks, we expect a zero delta every 1024 / 16 = 64 elements.
//         if (i % @bitSizeOf(T) == 0) {
//             try std.testing.expectEqual(i, actual[i]);
//         } else {
//             try std.testing.expectEqual(1, actual[i]);
//         }
//     }
// }

test "fastlanez delta bench" {
    const std = @import("std");

    const warmup = 0;
    const iterations = 1_000_000;

    inline for (.{ u16, u32, u64 }) |T| {
        inline for (.{ Delta(T), Delta1024(T) }) |Codec| {
            const base = [_]T{0} ** (1024 / @bitSizeOf(T));
            const input = arange(T, 1024);

            for (0..warmup) |_| {
                var actual: [1024]T = undefined;
                Codec.encode(base, input, &actual);
            }

            var time: i128 = 0;
            for (0..iterations) |_| {
                const start = std.time.nanoTimestamp();
                var actual: [1024]T = undefined;
                Codec.encode(base, input, &actual);
                std.mem.doNotOptimizeAway(actual);
                // Codec.encode(base, input, &actual);
                const stop = std.time.nanoTimestamp();
                time += stop - start;
            }

            const clock_freq = 3.48; // GHz

            const total_nanos = @as(f64, @floatFromInt(time));
            const total_ms = total_nanos / 1_000_000;
            const total_cycles = total_nanos * clock_freq;

            const total_elems = iterations * 1024;
            const elems_per_cycle = total_elems / total_cycles;
            const cycles_per_elem = total_cycles / total_elems;

            std.debug.print("Completed {} iterations of {}\n", .{ iterations, Codec });
            std.debug.print("\t{d:.2} ms total.\n", .{total_ms});
            std.debug.print("\t{d:.1} elems / cycle\n", .{elems_per_cycle});
            std.debug.print("\t{d:.1} cycles / elem\n", .{cycles_per_elem});
            std.debug.print("\t{d:.2} billion elems / second\n", .{total_elems / total_nanos});
            std.debug.print("\n", .{});
        }
    }
}

fn arange(comptime T: type, comptime n: comptime_int) [n]T {
    const std = @import("std");
    var result: [n]T = undefined;
    for (0..n) |i| {
        result[i] = @intCast(i % std.math.maxInt(T));
    }
    return result;
}
