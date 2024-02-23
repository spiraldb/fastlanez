const fl = @import("fastlanes.zig");

pub fn Delta(comptime E: type) type {
    return struct {
        const std = @import("std");
        pub const FL = fl.FastLanez(E, .{});

        pub fn encode(base: *const [FL.S]E, in: *const FL.Vector, out: *FL.Vector) void {
            var prev = FL.load(base, 0);
            inline for (0..FL.T) |i| {
                const next = FL.loadT(in, i);
                const result = FL.subtract(next, prev);
                FL.storeT(out, i, result);
                prev = next;
            }
        }
    };
}

test "fastlanez delta" {
    const std = @import("std");
    const arange = @import("helper.zig").arange;

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

test "fastlanez bench delta encode" {
    const std = @import("std");
    const Bench = @import("bench.zig").Bench;

    inline for (.{ u8, u16, u32, u64 }) |T| {
        try Bench("delta encode " ++ @typeName(T), .{}).bench(struct {
            const base = [_]T{0} ** (1024 / @bitSizeOf(T));
            const input: [1024]T = .{1} ** 1024;

            pub fn run() void {
                var output: [1024]T = undefined;
                Delta(T).encode(&base, &input, &output);
                std.mem.doNotOptimizeAway(output);
            }
        });
    }
}
