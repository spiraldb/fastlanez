const fl = @import("fastlanes.zig");

pub fn BitPacking(comptime E: type, comptime P: type) type {
    const T = @bitSizeOf(E); // The element size
    const W = @bitSizeOf(P); // The packed size
    const B = 128 * W;

    return struct {
        pub const FL = fl.FastLanez(E, .{});
        pub const Vector = FL.Vector;

        // Pack a 1024 element vector of E into a byte stream of P-bit elements.
        // Unlike decode, this works for arbitrary P, not just 3.
        pub fn pack(in: *const FL.Vector, out: *[W]FL.MM1024) void {
            _ = in;
            // Create the masks for each bit width up to W.
            var mask: [W + 1]E = undefined;
            inline for (0..W) |i| {
                mask[i + 1] = (1 << (i + 1)) - 1;
            }

            // The offset within each E.
            const bit_offset = 0;
            _ = bit_offset;
            const tmp: FL.MM1024 = undefined;

            inline for (0..T) |t| {
                FL.store(out, t, tmp);
            }
        }

        /// Decode a packed byte stream in to a 1024 element vector.
        pub fn decode(in: *const [W]FL.MM1024, out: *FL.Vector) void {
            // Add so our code more closely matches the psuedocode
            var mask: [W + 1]E = undefined;
            inline for (0..W) |i| {
                mask[i + 1] = (1 << (i + 1)) - 1;
            }

            var r0: FL.MM1024 = undefined;
            var r1: FL.MM1024 = undefined;

            // TODO(ngates): can we just use loadT/storeT always?
            // Don't think so. Since FL is specialized to E, rather than P.
            // If each function took a type, then perhaps?

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

test "fastlanez bitpack" {
    const std = @import("std");
    const repeat = @import("helper.zig").repeat;

    const Codec = BitPacking(u8, u3);

    const input: [384]u8 = @bitCast(repeat(u8, 255, 384)); // Setup an input of all "1" bits.
    var output: [1024]u8 = undefined;
    Codec.decode(&input, &output);

    try std.testing.expectEqual(output, repeat(u8, 7, 1024));
}
