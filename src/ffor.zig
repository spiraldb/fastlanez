const fl = @import("fastlanes.zig");

pub fn FFoR(comptime E: type) type {
    return struct {
        const std = @import("std");
        pub const FL = fl.FastLanez(E, .{});

        pub fn pack(comptime W: comptime_int, reference: E, in: *const FL.Vector, out: *FL.PackedVector(W)) void {
            inline for (0..FL.T) |t| {
                const next = FL.subtract(FL.load(in, t), reference);
                // Ah, can we make PackedVector a stateful thing?
                FL.pack(W, out, t, next);
            }
        }

        /// Fused kernel for unpacking adding the reference value to each vector.
        pub fn unpack_ffor(comptime W: comptime_int, reference: E, in: *const FL.PackedVector(W), out: *FL.Vector) void {
            inline for (0..FL.T) |t| {
                const next = FL.add(FL.unpack(W, in, t), reference);
                FL.store(out, t, next);
            }
        }
    };
}

test "fastlanez ffor" {
    const std = @import("std");
    const repeat = @import("helper.zig").repeat;

    const T = u16;
    const F = FFoR(T);

    const input = repeat(T, 5, 1024);
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
