const fl = @import("fastlanes.zig");

const E = u8;
const T = @bitSizeOf(E);
const W = 3;
const FL = fl.FastLanez(E, .{});

/// Decode 3-bit ints into 8-bit ints.
pub fn decode(in: *const [128 * 3]u8, out: *FL.Vector) void {
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

test "fastlanez unpack 3 -> 8" {
    const std = @import("std");
    const repeat = @import("helper.zig").repeat;

    // Setup an input of all "1" bits.
    const input: [384]u8 = @bitCast(repeat(u8, 255, 384));

    var output: [1024]u8 = undefined;
    decode(@ptrCast(&input), &output);

    // Ensure all outputs are "0000111" => 7.
    try std.testing.expectEqual(output, repeat(u8, 7, 1024));
}
