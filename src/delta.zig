pub fn Delta(comptime FastLanes: type) type {
    const FL = FastLanes;

    return FL.Pairwise(struct {
        const Self = @This();

        pub inline fn encode(_: Self, prev: FL.MM, next: FL.MM) FL.MM {
            return next -% prev;
        }

        pub inline fn decode(_: Self, prev: FL.MM, next: FL.MM) FL.MM {
            return prev +% next;
        }
    });
}

test "fastlanez delta" {
    const std = @import("std");
    const fl = @import("fastlanes.zig");
    const arange = @import("helper.zig").arange;

    const T = u16;
    const FL = fl.FastLanez(T, .{});

    const base = [_]T{0} ** (1024 / @bitSizeOf(T));
    const input = arange(T, 1024);
    const tinput = FL.transpose(input);

    var actual: [1024]T = undefined;
    Delta(FL).init(.{}).encode(&base, &tinput, &actual);
    std.mem.doNotOptimizeAway(actual);

    actual = FL.untranspose(actual);

    for (0..1024) |i| {
        // We expecte a delta == i for every T'th element since it is compared with the base vector.
        if (i % @bitSizeOf(T) == 0) {
            try std.testing.expectEqual(i, actual[i]);
        } else {
            try std.testing.expectEqual(1, actual[i]);
        }
    }
}

test "fastlanez delta bench" {
    const std = @import("std");
    const fl = @import("fastlanes.zig");
    const Bench = @import("bench.zig").Bench;
    const arange = @import("helper.zig").arange;

    inline for (.{ u8, u16, u32, u64 }) |T| {
        const FL = fl.FastLanez(T, .{});

        try Bench("delta encode " ++ @typeName(T), .{}).bench(struct {
            const base = [_]T{0} ** (1024 / @bitSizeOf(T));
            const input = arange(T, 1024);
            const tinput = FL.transpose(input);

            pub fn run(_: @This()) void {
                var output: [1024]T = undefined;
                Delta(FL).init(.{}).encode(&base, &tinput, &output);
                std.mem.doNotOptimizeAway(output);
            }
        });
    }

    inline for (.{ u8, u16, u32, u64 }) |T| {
        const FL = fl.FastLanez(T, .{});

        try Bench("delta decode " ++ @typeName(T), .{}).bench(struct {
            const base = [_]T{0} ** (1024 / @bitSizeOf(T));
            const input: [1024]T = .{1} ** 1024;

            pub fn run(_: @This()) void {
                var output: [1024]T = undefined;
                Delta(FL).init(.{}).decode(&base, &input, &output);
                std.mem.doNotOptimizeAway(output);
            }
        });
    }
}
