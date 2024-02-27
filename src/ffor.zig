pub fn FFoR(comptime FastLanes: type) type {
    const FL = FastLanes;

    // We need to be able to take our own arguments.
    // Maybe the encode function takes options? Or we use the struct value?
    return FL.Elementwise(struct {
        const Self = @This();

        reference: FL.MM,

        pub fn init(value: FL.E) Self {
            return Self{ .reference = FL.splat(value) };
        }

        pub fn encode(self: Self, word: FL.MM) FL.MM {
            return word -% self.reference;
        }

        pub fn decode(self: Self, word: FL.MM) FL.MM {
            return word +% self.reference;
        }
    });
}

test "fastlanez ffor" {
    const fl = @import("fastlanes.zig");
    const std = @import("std");
    const repeat = @import("helper.zig").repeat;

    const T = u16;
    const FL = fl.FastLanez(T, .{});
    const F = FFoR(FL).init(.{ .reference = FL.splat(1) });

    const input = repeat(T, 5, 1024);
    var output: [1024]T = undefined;

    F.encode(&input, &output);
    try std.testing.expectEqual(output, repeat(T, 4, 1024));

    var decoded: [1024]T = undefined;
    F.decode(&output, &decoded);
    try std.testing.expectEqual(decoded, input);
}

test "fastlanez ffor bench" {
    const std = @import("std");
    const fl = @import("fastlanes.zig");
    const Bench = @import("bench.zig").Bench;
    const arange = @import("helper.zig").arange;

    inline for (.{ u8, u16, u32, u64 }) |T| {
        const FL = fl.FastLanez(T, .{});

        try Bench("ffor encode " ++ @typeName(T), .{}).bench(struct {
            const F = FFoR(FL).init(.{ .reference = FL.splat(1) });
            const input = arange(T, 1024);

            pub fn run(_: @This()) void {
                var output: [1024]T = undefined;
                F.encode(&input, &output);
                std.mem.doNotOptimizeAway(output);
            }
        });
    }

    inline for (.{ u8, u16, u32, u64 }) |T| {
        const FL = fl.FastLanez(T, .{});

        try Bench("ffor decode " ++ @typeName(T), .{}).bench(struct {
            const F = FFoR(FL).init(.{ .reference = FL.splat(1) });
            const input: [1024]T = .{1} ** 1024;

            pub fn run(_: @This()) void {
                var output: [1024]T = undefined;
                F.decode(&input, &output);
                std.mem.doNotOptimizeAway(output);
            }
        });
    }
}
