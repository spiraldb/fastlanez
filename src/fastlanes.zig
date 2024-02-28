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
    ISA: fn (comptime E: type) type = isa.FastLanez_ISA_ZIMD(128),
    // ISA: fn (comptime E: type) type = isa.FastLanez_ISA_Scalar,
};

pub fn FastLanez(comptime Element: type, comptime options: Options) type {
    return struct {
        /// The type of the element.
        pub const E = Element;
        /// The bit size of the element type.
        pub const T = @bitSizeOf(E);
        /// The number of elements in a single MM1024 word.
        pub const S = 1024 / T;
        /// A vector of 1024 elements.
        pub const Vector = [1024]E;

        const ISA = options.ISA(Element);
        pub const splat = ISA.splat;

        /// The variable width SIMD word as supported by the ISA.
        pub const MM = ISA.MM;
        /// The virtual 1024-bit SIMD word.
        pub const MM1024 = [nwords]ISA.MM;

        pub const NLanes = 1024 / @bitSizeOf(MM);
        pub const NRows = T;

        // The number of MM words in an MM1024 word.
        const nwords = 1024 / @bitSizeOf(MM);
        /// The number of elements in an MM word.
        const m = @bitSizeOf(MM) / T;

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

        /// Element offsets for a single lane.
        pub const lane_offsets: [T]usize = blk: {
            var _offsets: [T]usize = undefined;
            var offset = 0;

            // The arrangement of the tiles as per the unified transpose layout. See Figure 6.
            const tile_cols = 64 / T;
            const tile_rows = 8 / tile_cols;

            for (0..tile_rows) |tile| {
                // Within each tile, loop over the 8 element rows.
                for (0..8) |r| {
                    // Compute a element offset based on the unified tranpose order.
                    _offsets[offset] = (ORDER[tile] * 16) + (r * 128);
                    // @compileLog(l, col, tr, tile, _offsets[offset]);
                    offset += 1;
                }
            }

            break :blk _offsets;
        };

        /// MM offsets required to iterate over a 1024 element vector.
        pub const mm_offsets: [T * nwords]usize = blk: {
            @setEvalBranchQuota(8192);
            var _offsets: [T * nwords]usize = undefined;
            var offset = 0;

            // The arrangement of the tiles as per the unified transpose layout. See Figure 6.
            const tile_cols = 64 / T;
            const tile_rows = 8 / tile_cols;

            // Loop over the lanes of the arrangement.
            for (0..nwords) |l| {
                // Figure out which tile column we're in.
                const col = l * m / 16;

                // Figure out the element offset within the tile.
                const elem = (l * m) % 16;

                // Within each lane, loop over the rows of tiles
                for (0..tile_rows) |tr| {
                    // Compute which tile we're in.
                    const tile = ORDER[col] + tr;

                    // Within each tile, loop over the 8 element rows.
                    for (0..8) |r| {
                        // Compute a element offset based on the unified tranpose order.
                        _offsets[offset] = ((ORDER[tile] * 16) + (r * 128) + elem);
                        // @compileLog(l, col, tr, tile, _offsets[offset]);
                        offset += 1;
                    }
                }
            }

            break :blk _offsets;
        };

        /// The MM offsets within an S-element (1024-bit) base vector.
        pub const mm_base_offsets: [nwords]comptime_int = blk: {
            var _offsets: [nwords]comptime_int = undefined;
            var offset = 0;

            // The arrangement of the tiles as per the unified transpose layout. See Figure 6.
            const tile_cols = 64 / T;
            const tile_rows = 8 / tile_cols;

            // Loop over the lanes of the arrangement.
            for (0..nwords) |l| {
                // Figure out which tile column we're in.
                const col = l * m / 16;

                // Figure out the element offset within the tile.
                const elem = (l * m) % 16;

                // Compute which tile we're in.
                const tile = ORDER[col];

                // Compute a element offset based on the unified tranpose order.
                _offsets[offset] = ((ORDER[tile] * 16 / tile_rows) + elem);
                offset += 1;
            }

            break :blk _offsets;
        };

        /// TODO(ngates): should this use the transpose ordering? Not sure it actually makes a difference?
        /// Maybe to cache locality?
        pub fn Elementwise(comptime Codec: type) type {
            return struct {
                const Self = @This();

                codec: Codec,

                pub fn init(codec: Codec) Self {
                    return .{ .codec = codec };
                }

                pub fn encode(self: Self, in: *const Vector, out: *Vector) void {
                    @setEvalBranchQuota(8192);

                    // TODO(ngates): extract the lane offset from the mm_offsets so we can loop over it at runtime.
                    inline for (mm_offsets) |offset| {
                        const next: MM = load_mm(in, offset / m);
                        const result = self.codec.encode(next);
                        store_mm(out, offset / m, result);
                    }
                }

                pub fn decode(self: Self, in: *const Vector, out: *Vector) void {
                    @setEvalBranchQuota(8192);

                    inline for (mm_offsets) |offset| {
                        const next: MM = load_mm(in, offset / m);
                        const result = self.codec.decode(next);
                        store_mm(out, offset / m, result);
                    }
                }
            };
        }

        pub fn Pairwise(comptime Codec: type) type {
            return struct {
                const Self = @This();

                codec: Codec,

                pub fn init(codec: Codec) Self {
                    return .{ .codec = codec };
                }

                /// Note: it is assumed the base is already transposed.
                pub fn encode(self: Self, base: *const [S]E, in: *const Vector, out: *Vector) void {
                    @setEvalBranchQuota(8192);
                    var prev: MM = undefined;

                    inline for (mm_offsets, 0..) |offset, i| {
                        if (comptime i % T == 0) {
                            prev = load_mm(base, i / T);
                        }

                        const next: MM = load_mm(in, offset / m);
                        const result = self.codec.encode(prev, next);
                        store_mm(out, offset / m, result);
                        prev = next;
                    }
                }

                pub fn decode(self: Self, base: *const [S]E, in: *const Vector, out: *Vector) void {
                    @setEvalBranchQuota(8192);
                    var prev: MM = undefined;

                    inline for (mm_offsets, 0..) |offset, i| {
                        if (comptime i % T == 0) {
                            prev = load_mm(base, i / T);
                        }

                        const next: MM = load_mm(in, offset / m);
                        const result = self.codec.decode(prev, next);
                        store_mm(out, offset / m, result);
                        prev = result;
                    }
                }
            };
        }

        pub inline fn load_base(ptr: anytype, lane: comptime_int) MM {
            return load_mm(ptr, lane);
        }

        pub inline fn load_transposed(ptr: anytype, lane: comptime_int, row: comptime_int) MM {
            return load_mm(ptr, mm_offsets[(lane * T) + row] / m);
        }

        pub inline fn store_transposed(ptr: anytype, lane: comptime_int, row: comptime_int, word: MM) void {
            return store_mm(ptr, mm_offsets[(lane * T) + row] / m, word);
        }

        /// Load the physical nth MM word from the input buffer.
        pub inline fn load_mm(ptr: anytype, n: usize) MM {
            const Array = @typeInfo(@TypeOf(ptr)).Pointer.child;
            const words: *const [@sizeOf(Array) / @sizeOf(MM)][@sizeOf(MM)]u8 = @ptrCast(ptr);
            return @bitCast(words[n]);
        }

        /// Store the physical nth MM word into the output buffer.
        pub inline fn store_mm(ptr: anytype, n: usize, value: MM) void {
            const Array = @typeInfo(@TypeOf(ptr)).Pointer.child;
            const words: *[@sizeOf(Array) / @sizeOf(MM)][@sizeOf(MM)]u8 = @ptrCast(ptr);
            words[n] = @bitCast(value);
        }

        /// Load the logical nth 1024bit word from the input buffer. Respecting the unified transpose order.
        pub inline fn load(ptr: anytype, n: usize) MM1024 {
            return load_raw(ptr, offsets[n]);
        }

        /// Load the physical nth 1024bit word from the input buffer.
        pub inline fn load_raw(ptr: anytype, n: u8) MM1024 {
            const Array = @typeInfo(@TypeOf(ptr)).Pointer.child;
            const words: *const [@sizeOf(Array) / 128][128]u8 = @ptrCast(ptr);
            return @bitCast(words[n]);
        }

        /// Store the logical nth 1024bit word into the output buffer. Respecting the unified transpose order.
        pub inline fn store(ptr: anytype, n: usize, vec: MM1024) void {
            store_raw(ptr, offsets[n], vec);
        }

        /// Store the physical nth 1024bit word into the output buffer.
        pub inline fn store_raw(ptr: anytype, n: usize, word: MM1024) void {
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

        /// A struct for bitpacking into an output buffer.
        pub fn BitPacker(comptime Width: comptime_int) type {
            return struct {
                const Self = @This();

                /// The number of times store has been called. The position in the input vector, so to speak.
                t: comptime_int = 0,
                /// The position in the output that we're writing to. Will finish equal to Width.
                out_idx: comptime_int = 0,

                shift_bits: comptime_int = 0,
                mask_bits: comptime_int = Width,

                /// Invoke to store the next vector.
                pub inline fn pack(comptime self: *Self, out: *PackedBytes(Width), word: MM1024, state: MM1024) MM1024 {
                    var tmp: MM1024 = undefined;
                    if (self.t == 0) {
                        tmp = @bitCast([_]u8{0} ** 128);
                    } else {
                        tmp = state;
                    }

                    if (self.t > T) {
                        @compileError("Store called too many times");
                    }
                    self.t += 1;

                    // If we didn't take all W bits last time, then we load the remainder
                    if (self.mask_bits < Width) {
                        tmp = or_(tmp, and_rshift(word, self.mask_bits, bitmask(self.shift_bits)));
                    }

                    // Update the number of mask bits
                    self.mask_bits = @min(T - self.shift_bits, Width);

                    // Pull the masked bits into the tmp register
                    tmp = or_(tmp, and_lshift(word, self.shift_bits, bitmask(self.mask_bits)));
                    self.shift_bits += Width;

                    if (self.shift_bits >= T) {
                        // If we have a full 1024 bits, then store it and reset the tmp register
                        store_raw(out, self.out_idx, tmp);
                        tmp = @bitCast([_]u8{0} ** 128);
                        self.out_idx += 1;
                        self.shift_bits = T;
                    }

                    return tmp;
                }
            };
        }

        pub fn BitUnpacker(comptime Width: comptime_int) type {
            return struct {
                const Self = @This();

                t: comptime_int = 0,

                input_idx: comptime_int = 0,
                shift_bits: comptime_int = 0,

                pub inline fn unpack(comptime self: *Self, input: *const PackedBytes(Width), state: MM1024) struct { MM1024, MM1024 } {
                    if (self.t > T) {
                        @compileError("Store called too many times");
                    }
                    self.t += 1;

                    var tmp: MM1024 = undefined;
                    if (self.input_idx == 0) {
                        tmp = load_raw(input, 0);
                        self.input_idx += 1;
                    } else {
                        tmp = state;
                    }

                    const mask_bits = @min(T - self.shift_bits, Width);

                    var next = and_rshift(tmp, self.shift_bits, bitmask(mask_bits));

                    if (mask_bits != Width) {
                        tmp = load_raw(input, self.input_idx);
                        self.input_idx += 1;

                        next = or_(next, and_lshift(tmp, mask_bits, bitmask(Width - mask_bits)));

                        self.shift_bits = Width - mask_bits;
                    } else {
                        self.shift_bits += Width;
                    }

                    return .{ next, tmp };
                }
            };
        }

        pub inline fn add(a: MM1024, b: MM1024) MM1024 {
            @setEvalBranchQuota(64_000);
            var result: MM1024 = undefined;
            inline for (@as(MM1024, a), @as(MM1024, b), 0..) |lane_a, lane_b, i| {
                result[i] = ISA.add(lane_a, lane_b);
            }
            return @bitCast(result);
        }

        pub inline fn subtract(a: MM1024, b: MM1024) MM1024 {
            @setEvalBranchQuota(64_000);
            var result: MM1024 = undefined;
            inline for (@as(MM1024, a), @as(MM1024, b), 0..) |lane_a, lane_b, i| {
                result[i] = ISA.subtract(lane_a, lane_b);
            }
            return @bitCast(result);
        }

        pub inline fn and_(a: MM1024, b: MM1024) MM1024 {
            var result: MM1024 = undefined;
            inline for (@as(MM1024, a), @as(MM1024, b), 0..) |lane_a, lane_b, i| {
                result[i] = ISA.and_(lane_a, lane_b);
            }
            return @bitCast(result);
        }

        pub inline fn or_(a: MM1024, b: MM1024) MM1024 {
            @setEvalBranchQuota(64_000);
            var result: MM1024 = undefined;
            inline for (@as(MM1024, a), @as(MM1024, b), 0..) |lane_a, lane_b, i| {
                result[i] = ISA.or_(lane_a, lane_b);
            }
            return @bitCast(result);
        }

        // forall T−bit lanes i in REG return (i & MASK) << N
        pub inline fn and_lshift(vec: MM1024, n: anytype, mask: E) MM1024 {
            @setEvalBranchQuota(64_000);
            var result: MM1024 = undefined;
            inline for (@as(MM1024, vec), 0..) |lane, i| {
                result[i] = ISA.and_lshift(lane, n, mask);
            }
            return @bitCast(result);
        }

        // forall T−bit lanes i in REG return (i & (MASK << N)) >> N
        pub inline fn and_rshift(vec: MM1024, n: anytype, mask: E) MM1024 {
            @setEvalBranchQuota(64_000);
            var result: MM1024 = undefined;
            inline for (@as(MM1024, vec), 0..) |lane, i| {
                result[i] = ISA.and_rshift(lane, n, mask);
            }
            return @bitCast(result);
        }

        // Create a mask of the first `bits` bits.
        inline fn bitmask(comptime bits: comptime_int) E {
            return (1 << bits) - 1;
        }
    };
}

// This unified transpose layout allows us to operate efficiently using a variety of SIMD lane widths.
const ORDER: [8]comptime_int = .{ 0, 4, 2, 6, 1, 5, 3, 7 };

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

    // std.testing.refAllDecls(@import("bitpacking_demo.zig"));
    // std.testing.refAllDecls(@import("bitpacking.zig"));
    std.testing.refAllDecls(@import("delta.zig"));
    std.testing.refAllDecls(@import("ffor.zig"));
}
