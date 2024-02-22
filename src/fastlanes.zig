// We always operate on vectors of 1024 elements.
// Elements may be 8, 16, 32, or 64 bits wide. Known as T.
// 1024 / T is the number of SIMD lanes, known as S.

// The question is whether strictly implementing the 1024 bit vectors will
// mean the compiler fails to optimize. e.g. for our u64 ISA, we need to load
// values into a 16 element array of u64s. Instead of iterating over 1 u64 at a time
// inside a single register, we may now have another STORE operation to push
// all this back into memory.

const isa = @import("isa.zig");

pub const Options = struct {
    ISA: fn (comptime E: type) type = isa.FastLanez_ISA_ZIMD(1024),
};

pub fn FastLanez(comptime E: type, comptime options: Options) type {
    const ISA = options.ISA(E);

    // The type of a single lane of the ISA.
    const Lane = ISA.Lane;
    const NLanes = 1024 / @bitSizeOf(Lane);
    const Lanes = [NLanes]ISA.Lane;

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
        /// The bit size of the element type.
        pub const T = @bitSizeOf(E);
        /// The number of elements in a single MM1024 register.
        pub const S = 1024 / T;

        pub const Vector = [1024]E;

        /// Represents the fastlanes virtual 1024bit SIMD register.
        pub const MM1024 = Lanes;

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

        pub inline fn load(ptr: *const anyopaque, n: u8) MM1024 {
            const regs: [*]const [128]u8 = @ptrCast(ptr);
            return @bitCast(regs[n]);
        }

        pub inline fn loadT(ptr: *const anyopaque, n: usize) MM1024 {
            return load(ptr, offsets[n]);
        }

        pub inline fn store(ptr: *anyopaque, n: usize, vec: MM1024) void {
            const regs: [*][128]u8 = @ptrCast(ptr);
            regs[n] = @bitCast(vec);
        }

        pub inline fn storeT(ptr: *anyopaque, n: usize, vec: MM1024) void {
            store(ptr, offsets[n], vec);
        }

        /// Shuffle the input vector into the unified transpose order.
        pub fn transpose(vec: Vector) Vector {
            // We defer to LLVM to attempt to optimize this transpose.
            const V = @Vector(1024, E);
            return @shuffle(E, @as(V, vec), @as(V, vec), transpose_mask);
        }

        /// Unshuffle the input vector from the unified transpose order.
        pub fn untranspose(vec: Vector) Vector {
            // We defer to LLVM to attempt to optimize this transpose.
            const V = @Vector(1024, E);
            return @shuffle(E, @as(V, vec), @as(V, vec), untranspose_mask);
        }

        pub inline fn subtract(a: MM1024, b: MM1024) MM1024 {
            @setEvalBranchQuota(4096);
            var result: Lanes = undefined;
            inline for (@as(Lanes, a), @as(Lanes, b), 0..) |lane_a, lane_b, i| {
                result[i] = ISA.subtract(lane_a, lane_b);
            }
            return @bitCast(result);
        }

        pub inline fn and_(a: MM1024, b: MM1024) MM1024 {
            var result: Lanes = undefined;
            inline for (@as(Lanes, a), @as(Lanes, b), 0..) |lane_a, lane_b, i| {
                result[i] = ISA.and_(lane_a, lane_b);
            }
            return @bitCast(result);
        }

        pub inline fn or_(a: MM1024, b: MM1024) MM1024 {
            var result: Lanes = undefined;
            inline for (@as(Lanes, a), @as(Lanes, b), 0..) |lane_a, lane_b, i| {
                result[i] = ISA.or_(lane_a, lane_b);
            }
            return @bitCast(result);
        }

        // forall T−bit lanes i in REG return (i & MASK) << N
        pub inline fn and_lshift(vec: MM1024, n: anytype, mask: E) MM1024 {
            var result: Lanes = undefined;
            inline for (@as(Lanes, vec), 0..) |lane, i| {
                result[i] = ISA.and_lshift(lane, n, mask);
            }
            return @bitCast(result);
        }

        // forall T−bit lanes i in REG return (i & (MASK << N)) >> N
        pub inline fn and_rshift(vec: MM1024, n: anytype, mask: E) MM1024 {
            var result: Lanes = undefined;
            inline for (@as(Lanes, vec), 0..) |lane, i| {
                result[i] = ISA.and_rshift(lane, n, mask);
            }
            return @bitCast(result);
        }
    };
}

test "fastlanez transpose" {
    const std = @import("std");
    const arange = @import("helper.zig").arange;
    const T = u32;
    const FL = FastLanez(T, .{});

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

    std.testing.refAllDecls(@import("bitpacking_demo.zig"));
    std.testing.refAllDecls(@import("bitpacking.zig"));
    std.testing.refAllDecls(@import("delta.zig"));
}
