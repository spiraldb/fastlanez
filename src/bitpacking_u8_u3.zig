//! An implementation of the "unpack 3 -> 8" algorithm ported literally from the FastLanes paper.
const fl = @import("fastlanez.zig");

const E = u8;
const W = 3;
const FL = fl.FastLanez(E);

/// Decode 3-bit ints into 8-bit ints.
pub fn decode(in: *const FL.PackedBytes(3), out: *FL.Vector) void {
    comptime var mask: [W + 1]E = undefined;
    inline for (0..W + 1) |i| {
        mask[i] = (1 << i) - 1;
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

test "fastlanez unpack 3 -> 8" {
    const std = @import("std");

    // Setup an input of all "1" bits.
    const input: [384]u8 = .{255} ** 384;

    var output: [1024]u8 = undefined;
    decode(&input, &output);

    // Ensure all outputs are "0000111" => 7.
    const expected: [1024]u8 = .{7} ** 1024;
    try std.testing.expectEqual(expected, output);
}
