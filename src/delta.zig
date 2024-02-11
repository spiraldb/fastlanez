pub fn Delta(comptime FastLanes: type) type {
    const FL = FastLanes;

    return struct {
        const std = @import("std");

        pub fn encode(base: *const FL.BaseVector, in: *const FL.Vector, out: *FL.Vector) void {
            var prev: FL.MM1024 = FL.load(base, 0);
            inline for (0..FL.T) |i| {
                const next = FL.load_transposed(in, i);
                const delta = FL.subtract(next, prev);
                prev = next;
                FL.store_transposed(out, i, delta);
            }
        }

        pub fn decode(base: *const FL.BaseVector, in: *const FL.Vector, out: *FL.Vector) void {
            var prev = FL.load(base, 0);
            inline for (0..FL.T) |i| {
                const delta = FL.load_transposed(in, i);
                const result = FL.add(prev, delta);
                prev = result;
                FL.store_transposed(out, i, result);
            }
        }

        pub fn pack(comptime W: comptime_int, base: *const FL.BaseVector, in: *const FL.Vector, out: *FL.PackedBytes(W)) void {
            comptime var packer = FL.bitpacker(W);
            var tmp: FL.MM1024 = undefined;

            var prev: FL.MM1024 = FL.load(base, 0);
            inline for (0..FL.T) |i| {
                const next = FL.load_transposed(in, i);
                const result = FL.subtract(next, prev);
                prev = next;

                tmp = packer.pack(out, result, tmp);
            }
        }

        pub fn unpack(comptime W: comptime_int, base: *const FL.BaseVector, in: *const FL.PackedBytes(W), out: *FL.Vector) void {
            comptime var packer = FL.bitunpacker(W);
            var tmp: FL.MM1024 = undefined;

            var prev: FL.MM1024 = FL.load(base, 0);
            inline for (0..FL.T) |i| {
                const next, tmp = packer.unpack(in, tmp);
                const result = FL.add(prev, next);
                FL.store_transposed(out, i, result);
                prev = result;
            }
        }
    };
}

test "fastlanez delta" {
    const std = @import("std");
    const fl = @import("fastlanez.zig");
    const arange = @import("helper.zig").arange;

    const T = u16;
    const FL = fl.FastLanez(T);

    const base: FL.BaseVector = .{0} ** FL.S;
    const input: FL.Vector = FL.transpose(arange(T, 1024));

    var actual: [1024]T = undefined;
    Delta(FL).encode(&base, &input, &actual);

    actual = FL.untranspose(actual);

    for (0..1024) |i| {
        // Since fastlanes processes based on 16 blocks, we expect a zero delta every 1024 / 16 = 64 elements.
        if (i % @bitSizeOf(T) == 0) {
            try std.testing.expectEqual(i, actual[i]);
        } else {
            try std.testing.expectEqual(1, actual[i]);
        }
    }
}
