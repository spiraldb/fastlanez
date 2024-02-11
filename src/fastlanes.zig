// We always operate on vectors of 1024 elements.
// Elements may be 8, 16, 32, or 64 bits wide. Known as T.
// 1024 / T is the number of SIMD lanes, known as S.

// TODO(ngates): parametermize with build option.
const FL_WIDTH = 1024;

pub fn FastLanez(comptime E: type, comptime ISA: type) type {
    return struct {
        const Elements = [FL_WIDTH]E;
        const FLMM1024 = @Vector(FL_WIDTH, E);
        const T = @bitSizeOf(E);
        const S = FL_WIDTH / T;

        const Lane = ISA.Lane;
        const LaneWidth = ISA.Width;
        const Lanes = FL_WIDTH / LaneWidth;

        const FLVec = @Vector(S, T);

        inline fn load(elems: *const Elements) FLMM1024 {
            var vec: FLMM1024 = undefined;
            for (0..Lanes) |l| {
                vec[l * LaneWidth ..][0..LaneWidth].* = ISA.load(elems[l * LaneWidth ..][0..LaneWidth]);
            }
            return vec;
        }

        inline fn store(vec: FLMM1024, elems: *Elements) void {
            elems.* = @bitCast(vec);
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
    return struct {
        const FL = FastLanez_SIMD(T);
        const Elements = FL.Elements;
        const FLMM1024 = FL.FLMM1024;

        pub fn encode(base: *const Elements, in: *const Elements, out: *Elements) void {
            const vec = FL.load(in);

            out = FL.subtract(in, base);

            // Delta encoding must iterate in tranpose order.

            FL.store(vec, out);
        }
    };
}

test "fastlanez simd isa" {
    const std = @import("std");
    const T = u32;
    const FL = FastLanez_SIMD(T);

    const expected = arange(T);
    const vec = FL.load(&expected);

    var actual: [FL_WIDTH]T = undefined;
    FL.store(vec, &actual);

    try std.testing.expectEqual(expected, actual);
}

test "fastlanez delta" {
    const std = @import("std");
    const T = u32;
    const Codec = Delta(T);

    const expected = arange(T);
    var actual: Codec.Elements = arange(T);
    Codec.encode(&expected, &actual);

    try std.testing.expectEqual(expected, actual);
}

fn arange(comptime T: type) [FL_WIDTH]T {
    var result: [FL_WIDTH]T = undefined;
    for (0..FL_WIDTH) |i| {
        result[i] = @intCast(i);
    }
    return result;
}
