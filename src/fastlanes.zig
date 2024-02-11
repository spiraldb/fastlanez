// We always operate on vectors of 1024 elements.
// Elements may be 8, 16, 32, or 64 bits wide. Known as T.
// 1024 / T is the number of SIMD lanes, known as S.

// TODO(ngates): parametermize with build option.
const FL_WIDTH = 1024;

pub fn FastLanez(comptime E: type, comptime ISA: type) type {
    return struct {
        const T = @bitSizeOf(E);
        const S = FL_WIDTH / T;
        const FLMM1024 = [FL_WIDTH]E;
        const FLLane = [S]E;

        const Lane = ISA.Lane;
        const LaneWidth = ISA.Width;
        const Lanes = FL_WIDTH / LaneWidth;

        /// Returns a function that operates pair-wise on FLMM1024 vectors by tranposing.
        inline fn tranpose(comptime op: fn (Lane, Lane) Lane) fn (FLLane, FLMM1024, *FLMM1024) void {
            const impl = struct {
                pub fn fl_transpose(base: FLLane, in: FLMM1024, out: *FLMM1024) void {
                    // TODO(ngates): should we use ISA.load instead of bitcasting?
                    const base_lanes: [Lanes]Lane = @bitCast(base);
                    const in_lanes: [T * Lanes]Lane = @bitCast(in);
                    const out_lanes: *[T * Lanes]Lane = @alignCast(@ptrCast(out));

                    for (0..Lanes) |l| {
                        var accumulator: Lane = base_lanes[l];
                        inline for (0..T) |t| {
                            const in_lane = in_lanes[l + t + (T / 4)];
                            accumulator = op(accumulator, in_lane);
                            out_lanes[l + t + (T / 4)] = accumulator;
                        }
                    }
                }
            };
            return impl.fl_transpose;
        }

        // forall T−bit lanes i in REG return (i & MASK) << N
        inline fn and_lshift(vec: FLMM1024, n: anytype, mask: FLMM1024) FLMM1024 {
            // TODO(ngates): can we make this more efficient?
            const nVec: FLMM1024 = @splat(n);
            return (vec & mask) << @intCast(nVec);
        }

        // forall T−bit lanes i in REG return (i & (MASK << N)) >> N
        inline fn and_rshift(vec: FLMM1024, n: anytype, mask: FLMM1024) FLMM1024 {
            const nVec: FLMM1024 = @splat(n);
            return (vec & (mask << nVec)) >> @intCast(nVec);
        }
    };
}

/// A FastLanez ISA implemented using 64-bit unsigned integers.
pub fn FastLanez_U64(comptime T: type) type {
    return struct {
        const Width = 64;
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

        pub fn subtract(a: Lane, b: Lane) Lane {
            const a_vec: @Vector(64 / @bitSizeOf(T), T) = @bitCast(a);
            const b_vec: @Vector(64 / @bitSizeOf(T), T) = @bitCast(b);
            const std = @import("std");
            std.debug.print("{} - {}\n", .{ a_vec, b_vec });
            return @bitCast(a_vec - b_vec);
        }
    };
}

/// A FastLanez ISA implemented using Zig SIMD 1024-bit vectors.
pub fn FastLanez_SIMD(comptime T: type) type {
    return struct {
        const Width = 1024;
        const Lane = @Vector(FL_WIDTH / @bitSizeOf(T), T);

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
    };
}

pub fn Delta(comptime T: type) type {
    const ISA = FastLanez_U64(T);
    const FL = FastLanez(T, ISA);

    return struct {
        pub const FLMM1024 = FL.FLMM1024;

        pub fn encode(base: FL.FLLane, in: FLMM1024, out: *FLMM1024) void {
            return FL.tranpose(sub)(base, in, out);
        }

        fn sub(a: FL.Lane, b: FL.Lane) FL.Lane {
            const std = @import("std");
            std.debug.print("sub {} {}\n", .{ a, b });
            return ISA.subtract(a, b);
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

test "fastlanez delta" {
    const std = @import("std");
    const T = u32;
    const Codec = Delta(T);

    const input = arange(T, 1024);
    const base = arange(T, 1024 / @bitSizeOf(T));
    var actual: [1024]T = undefined;
    Codec.encode(base, input, &actual);

    try std.testing.expectEqual(input, actual);
}

fn arange(comptime T: type, comptime n: comptime_int) [n]T {
    var result: [n]T = undefined;
    for (0..n) |i| {
        result[i] = @intCast(i);
    }
    return result;
}
