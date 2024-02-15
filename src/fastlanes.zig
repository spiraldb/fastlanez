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
        pub const T = @bitSizeOf(E);
        pub const S = 1024 / T;

        /// A FL vector captures 1024 elements of type E.
        const Vector = [1024]E;
        const Base = [S]E;

        /// Represents the fastlanes virtual 1024-bit SIMD register.
        pub const MM1024 = ISA.MM1024;

        /// Offset required to iterate over 1024 bit vectors according to the unified transpose order.
        pub const offsets: [T]u8 = blk: {
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

        /// Element offset required to iterate over 1024 bit vectors according to the unified transpose order.
        pub const offsets1024: [T]u32 = blk: {
            var _offsets1024: [T]u32 = undefined;
            var offset = 0;
            for (0..T / 8) |o| {
                const order_offset = ORDER[o] * 16;
                for (0..8) |row| {
                    const row_offset = 128 * row;
                    _offsets1024[offset] = (order_offset + row_offset) / S;
                    offset += 1;
                }
            }
            break :blk _offsets1024;
        };

        pub inline fn load(ptr: *const anyopaque, n: comptime_int) MM1024 {
            const regs: [*]const [128]u8 = @ptrCast(ptr);
            return @bitCast(regs[n]);
        }

        pub inline fn loadT(ptr: *const anyopaque, n: comptime_int) MM1024 {
            return load(ptr, offsets[n]);
        }

        pub inline fn store(ptr: *anyopaque, n: comptime_int, vec: MM1024) void {
            const regs: [*][128]u8 = @ptrCast(ptr);
            regs[n] = @bitCast(vec);
        }

        pub inline fn storeT(ptr: *anyopaque, n: comptime_int, vec: MM1024) void {
            store(ptr, offsets[n], vec);
        }

        /// Shuffle the input vector into the unified transpose order.
        /// TODO(ngates): not sure there's much better than a scalar loop here.
        pub fn transpose(vec: Vector) Vector {
            return @shuffle(E, @as(V, vec), @as(V, vec), transpose_mask);
        }

        /// Unshuffle the input vector from the unified transpose order.
        pub fn untranspose(vec: Vector) Vector {
            return @shuffle(E, @as(V, vec), @as(V, vec), untranspose_mask);
        }

        pub inline fn or_(a: MM1024, b: MM1024) MM1024 {
            return ISA.or_(a, b);
        }

        // forall T−bit lanes i in REG return (i & MASK) << N
        pub inline fn and_lshift(vec: MM1024, n: anytype, mask: E) MM1024 {
            return ISA.and_lshift(vec, n, mask);
        }

        // forall T−bit lanes i in REG return (i & (MASK << N)) >> N
        pub inline fn and_rshift(vec: MM1024, n: anytype, mask: E) MM1024 {
            return ISA.and_rshift(vec, n, mask);
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

pub fn FastLanez_ZIMD(comptime E: type, comptime W: comptime_int) type {
    const V = @Vector(W / @bitSizeOf(E), E);
    const nvecs = 1024 / W;
    const nelems = 1024 / @bitSizeOf(E);

    return struct {
        // Our MM1024 type.

        pub const Width = W;
        pub const MM1024 = [nvecs]V;

        inline fn load(elems: *const [nelems]E) MM1024 {
            return @bitCast(elems.*);
        }

        inline fn store(register: MM1024, elems: *[nelems]E) void {
            elems.* = @bitCast(register);
        }

        inline fn subtract(a: MM1024, b: MM1024) MM1024 {
            var result: MM1024 = undefined;
            inline for (0..nvecs) |i| {
                result[i] = a[i] -% b[i];
            }
            return result;
        }

        inline fn or_(a: MM1024, b: MM1024) MM1024 {
            var result: MM1024 = undefined;
            inline for (0..nvecs) |i| {
                result[i] = a[i] | b[i];
            }
            return result;
        }

        // forall T−bit lanes i in REG return (i & MASK) << N
        inline fn and_lshift(reg: MM1024, n: u8, mask: E) MM1024 {
            // TODO(ngates): can we make this more efficient?
            var result: MM1024 = undefined;
            const maskvec: V = @splat(mask);
            inline for (0..nvecs) |i| {
                const nvec: V = @splat(n);
                result[i] = (reg[i] & maskvec) << @intCast(nvec);
            }
            return result;
        }

        // forall T−bit lanes i in REG return (i & (MASK << N)) >> N
        inline fn and_rshift(reg: MM1024, n: u8, mask: E) MM1024 {
            var result: MM1024 = undefined;
            const maskvec: V = @splat(mask);
            inline for (0..nvecs) |i| {
                const nvec: V = @splat(n);
                result[i] = (reg[i] & (maskvec << nvec)) >> @intCast(nvec);
            }
            return result;
        }
    };
}

pub fn Delta(comptime E: type) type {
    const ISA = FastLanez_ZIMD(E, 128);

    return struct {
        const std = @import("std");
        pub const FL = FastLanez(E, ISA);

        pub fn encode(base: *const FL.Base, in: *const FL.Vector, out: *FL.Vector) void {
            var prev: FL.MM1024 = @bitCast(base.*);
            inline for (0..FL.T) |i| {
                const next: FL.MM1024 = FL.loadT(in, i);
                const result = ISA.subtract(next, prev);
                FL.storeT(out, i, result);
                prev = next;
            }
        }
    };
}

pub fn BitPacking(comptime E: type, comptime P: type) type {
    const ISA = FastLanez_ZIMD(E, 128);

    // The packed size
    const W = @bitSizeOf(P);
    const B = 128 * W;

    return struct {
        pub const FL = FastLanez(E, ISA);
        pub const Vector = FL.Vector;

        /// Decode a packed byte stream in to a 1024 element vector.
        pub fn decode(in: *const [B]u8, out: *FL.Vector) void {
            // Add so our code more closely matches the psuedo-code
            var mask: [W + 1]E = undefined;
            inline for (0..W) |i| {
                mask[i + 1] = (1 << (i + 1)) - 1;
            }

            var r0: FL.MM1024 = undefined;
            var r1: FL.MM1024 = undefined;

            r0 = FL.load(in, 0);
            r1 = FL.and_rshift(r0, 0, mask[3]);
            FL.store(out, 0, r1);
            r1 = FL.and_rshift(r0, 3, mask[3]);
            FL.store(out, 1, r1);
            r1 = FL.and_rshift(r0, 6, mask[2]);
            r0 = FL.load(in, 1);
            FL.store(out, 2, FL.or_(r1, FL.and_lshift(r0, 2, mask[1])));
            r1 = FL.and_rshift(r0, 1, mask[3]);
            FL.store(out, 3, r1);
            r1 = FL.and_rshift(r0, 4, mask[3]);
            FL.store(out, 4, r1);
            r1 = FL.and_rshift(r0, 7, mask[1]);
            r0 = FL.load(in, 2);
            FL.store(out, 5, FL.or_(r1, FL.and_lshift(r0, 1, mask[2])));
            r1 = FL.and_rshift(r0, 2, mask[3]);
            FL.store(out, 6, r1);
            r1 = FL.and_rshift(r0, 5, mask[3]);
            FL.store(out, 7, r1);
        }
    };
}

test "fastlanez transpose" {
    const std = @import("std");
    const T = u32;
    const ISA = FastLanez_ZIMD(T, 256);
    const FL = FastLanez(T, ISA);

    const input: FL.Vector = arange(T, 1024);
    const transposed = FL.transpose(input);

    try std.testing.expectEqual(transposed[0], 0);
    try std.testing.expectEqual(transposed[1], 64);
    try std.testing.expectEqual(transposed[2], 128);
    try std.testing.expectEqual(transposed[16], 32);
    try std.testing.expectEqual(transposed[1017], 639);
    try std.testing.expectEqual(transposed[1023], 1023);
}

test "fastlanez delta" {
    const std = @import("std");
    const T = u16;
    const Codec = Delta(T);

    const base = [_]T{0} ** (1024 / @bitSizeOf(T));
    const input = arange(T, 1024);
    const tinput = Codec.FL.transpose(input);

    var actual: [1024]T = undefined;
    Codec.encode(&base, &tinput, &actual);

    actual = Codec.FL.untranspose(actual);

    for (0..1024) |i| {
        // Since fastlanes processes based on 16 blocks, we expect a zero delta every 1024 / 16 = 64 elements.
        if (i % @bitSizeOf(T) == 0) {
            try std.testing.expectEqual(i, actual[i]);
        } else {
            try std.testing.expectEqual(1, actual[i]);
        }
    }
}

test "fastlanez bitpack" {
    const std = @import("std");

    const Codec = BitPacking(u8, u3);

    const input: [384]u8 = @bitCast(repeat(u8, 255, 384)); // Setup an input of all "1" bits.
    var output: [1024]u8 = undefined;
    Codec.decode(&input, &output);

    try std.testing.expectEqual(output, repeat(u8, 7, 1024));
}

test "fastlanez delta bench" {
    const std = @import("std");
    const builtin = @import("builtin");
    const dbg = builtin.mode == .Debug;

    const warmup = 0;
    const iterations = if (dbg) 1_000 else 10_000_000;

    // if (true) return;

    inline for (.{ u16, u32, u64 }) |T| {
        inline for (.{Delta(T)}) |Codec| {
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
                Codec.encode(&base, &input, &actual);
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

fn repeat(comptime T: type, comptime v: T, comptime n: comptime_int) [n]T {
    var result: [n]T = undefined;
    for (0..n) |i| {
        result[i] = @intCast(v);
    }
    return result;
}

fn arange(comptime T: type, comptime n: comptime_int) [n]T {
    const std = @import("std");
    var result: [n]T = undefined;
    for (0..n) |i| {
        result[i] = @intCast(i % std.math.maxInt(T));
    }
    return result;
}
