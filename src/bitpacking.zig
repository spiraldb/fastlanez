const fl = @import("fastlanes.zig");

pub fn BitPacking(comptime E: type, comptime W: comptime_int) type {
    const T = @bitSizeOf(E); // The element size

    // Create masks for each bit width up to W. mask[2] will mask the right-most 2-bits, and so on.
    // TODO(ngates): turn into a comptime function
    const mask: [W + 1]E = blk: {
        var mask_: [W + 1]E = undefined;
        inline for (0..W) |i| {
            mask_[i + 1] = (1 << (i + 1)) - 1;
        }
        break :blk mask_;
    };

    return struct {
        pub const FL = fl.FastLanez(E, .{});
        pub const Vector = FL.Vector;

        const std = @import("std");

        // Pack a 1024 element vector of E into a byte stream of W-bit elements.
        pub fn pack(in: *const FL.Vector, out: *[128 * W]u8) void {
            // Which 1024-bit output register we're writing to
            comptime var out_idx = 0;

            var tmp: FL.MM1024 = @bitCast([_]u8{0} ** 128);

            comptime var shift_bits = 0;
            comptime var mask_bits = W;

            inline for (0..T) |t| {
                // Grab the next input vector
                const src = FL.load(in, t);

                // If we didn't take all W bits last time, then we need to load the remainder
                if (mask_bits < W) {
                    tmp = FL.or_(tmp, FL.and_rshift(src, shift_bits, mask[W - shift_bits]));
                }

                // Either we can take W bits, or we take less than W bits
                // and we have to fill it up in the next load.
                mask_bits = @min(T - shift_bits, W);

                // Take the first W bits.
                tmp = FL.or_(tmp, FL.and_lshift(src, shift_bits, mask[mask_bits]));
                shift_bits += W;

                if (shift_bits >= T) {
                    FL.store(out, out_idx, tmp);
                    out_idx += 1;
                    shift_bits -= T;
                    tmp = @bitCast([_]u8{0} ** 128);
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

                // @compileLog("Mask", mask_bits, "Shift", shift_bits);
                var sink = FL.and_rshift(tmp, shift_bits, mask[mask_bits]);

                if (mask_bits != W) {
                    tmp = FL.load(in, in_idx);
                    in_idx += 1;

                    // @compileLog("** Mask", W - mask_bits, "Shift", 0);
                    sink = FL.or_(sink, FL.and_lshift(tmp, mask_bits, mask[W - mask_bits]));
                    std.debug.print("SINK {any}\n", .{sink});

                    shift_bits = W - mask_bits;
                } else {
                    shift_bits += W;
                }

                std.debug.print("OUT {any}\n", .{sink});
                FL.store(out, t, sink);
            }
        }
    };
}

test "fastlanez bitpack" {
    const std = @import("std");
    const repeat = @import("helper.zig").repeat;

    const BP = BitPacking(u8, 3);

    const ints: [1024]u8 = repeat(u8, 2, 1024);
    var packed_ints: [384]u8 = undefined;
    BP.pack(&ints, &packed_ints);
    std.debug.print("PACKED {any}\n", .{packed_ints});
    // try std.testing.expectEqual([_]u8{ 1, 2, 3 } ** 128, packed_ints);

    var output: [1024]u8 = undefined;
    BP.unpack(&packed_ints, &output);

    try std.testing.expectEqual(repeat(u8, 2, 1024), output);
}
