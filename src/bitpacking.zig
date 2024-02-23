const fl = @import("fastlanes.zig");

pub fn BitPacking(comptime E: type, comptime W: comptime_int) type {
    const T = @bitSizeOf(E); // The element size

    return struct {
        pub const FL = fl.FastLanez(E, .{});
        pub const Vector = FL.Vector;
        pub const Kernel = fn (FL.MM1024) FL.MM1024;

        pub fn pack(in: *const FL.Vector, out: *[128 * W]u8) void {
            const Closure = struct {
                fn noop(vec: FL.MM1024) FL.MM1024 {
                    return vec;
                }
            };
            return fused_pack(in, out, Closure.noop);
        }

        // Pack a 1024 element vector of E into a byte stream of W-bit elements.
        pub fn fused_pack(in: *const FL.Vector, out: *[128 * W]u8, kernel: Kernel) void {
            // Which 1024-bit output register we're writing to
            comptime var out_idx = 0;

            comptime var shift_bits = 0;
            comptime var mask_bits = W;

            var tmp: FL.MM1024 = @bitCast([_]u8{0} ** 128);

            inline for (0..T) |t| {
                // Grab the next input vector and apply the kernel
                const src: FL.MM1024 = kernel(FL.loadT(in, t));

                // If we didn't take all W bits last time, then we load the remainder
                if (mask_bits < W) {
                    tmp = FL.or_(tmp, FL.and_rshift(src, mask_bits, mask(shift_bits)));
                }

                // Update the number of mask bits
                mask_bits = @min(T - shift_bits, W);

                // Pull the masked bits into the tmp register
                tmp = FL.or_(tmp, FL.and_lshift(src, shift_bits, mask(mask_bits)));
                shift_bits += W;

                if (shift_bits >= T) {
                    // If we have a full 1024 bits, then store it and reset the tmp register
                    FL.store(out, out_idx, tmp);
                    tmp = @bitCast([_]u8{0} ** 128);
                    out_idx += 1;
                    shift_bits -= T;
                }
            }
        }

        /// Decode a packed byte stream in to a 1024 element vector.
        pub fn unpack(in: *const [128 * W]u8, out: *FL.Vector) void {
            var tmp: FL.MM1024 = FL.load(in, 0);

            comptime var in_idx = 1;
            comptime var shift_bits = 0;
            inline for (0..T) |t| {
                const mask_bits = @min(T - shift_bits, W);

                var sink = FL.and_rshift(tmp, shift_bits, mask(mask_bits));

                if (mask_bits != W) {
                    tmp = FL.load(in, in_idx);
                    in_idx += 1;

                    sink = FL.or_(sink, FL.and_lshift(tmp, mask_bits, mask(W - mask_bits)));

                    shift_bits = W - mask_bits;
                } else {
                    shift_bits += W;
                }

                FL.store(out, t, sink);
            }
        }

        // Create a mask of the first `bits` bits.
        inline fn mask(comptime bits: comptime_int) E {
            return (1 << bits) - 1;
        }
    };
}

test "fastlanez bitpack" {
    const std = @import("std");
    const BP = BitPacking(u8, 3);

    const ints: [1024]u8 = .{2} ** 1024;
    var packed_ints: [384]u8 = undefined;
    BP.pack(&ints, &packed_ints);

    // Decimal 2 repeated as 3-bit integers in blocks of 1024 bits.
    try std.testing.expectEqual(
        .{0b10010010} ** 128 ++ .{0b00100100} ** 128 ++ .{0b01001001} ** 128,
        packed_ints,
    );

    var output: [1024]u8 = undefined;
    BP.unpack(&packed_ints, &output);
    try std.testing.expectEqual(.{2} ** 1024, output);
}

test "fastlanez bitpack pack bench" {
    const std = @import("std");
    const Bench = @import("bench.zig").Bench;

    const BP = BitPacking(u8, 3);
    const ints: [1024]u8 = .{2} ** 1024;

    try Bench("pack u8 -> u3", .{}).bench(struct {
        pub fn run() void {
            var packed_ints: [384]u8 = undefined;
            BP.pack(&ints, &packed_ints);
            std.mem.doNotOptimizeAway(packed_ints);
        }
    });
}

test "fastlanez bitpack unpack bench" {
    const std = @import("std");
    const Bench = @import("bench.zig").Bench;

    const BP = BitPacking(u8, 3);

    // Decimal 2 repeated as 3-bit integers in blocks of 1024 bits.
    const packed_ints: [384]u8 = .{0b10010010} ** 128 ++ .{0b00100100} ** 128 ++ .{0b01001001} ** 128;

    try Bench("unpack u8 <- u3", .{}).bench(struct {
        pub fn run() void {
            var unpacked_ints: [1024]u8 = undefined;
            BP.unpack(&packed_ints, &unpacked_ints);
            std.mem.doNotOptimizeAway(unpacked_ints);
        }
    });
}
