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

pub fn Delta2(comptime FL: type) type {
    return struct {
        pub fn encode(base: *const [FL.S]FL.E, input: *const FL.Vector, output: *FL.Vector) void {
            @setEvalBranchQuota(10_000);

            var prev: FL.MM = undefined;
            for (0..FL.NLanes) |l| {
                const lane_width = @bitSizeOf(FL.MM) / FL.T;

                prev = FL.load_base(base, 0);

                inline for (0..FL.T) |t| {
                    const offset = (FL.lane_offsets[t] / lane_width) + l;
                    const next = FL.load_mm(input, offset);
                    // const next = FL.load_transposed(input, l, t);
                    FL.store_mm(output, offset, next -% prev);
                    // FL.store_transposed(output, l, t, next -% prev);
                    prev = next;
                }
            }
        }
    };
}

test "fastlanez delta 2" {
    const std = @import("std");
    const fl = @import("fastlanes.zig");
    const arange = @import("helper.zig").arange;

    const T = u16;
    const FL = fl.FastLanez(T, .{});

    const base = [_]T{0} ** (1024 / @bitSizeOf(T));
    const input = arange(T, 1024);
    const tinput = FL.transpose(input);

    var actual: [1024]T = undefined;
    Delta2(FL).encode(&base, &tinput, &actual);
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
            base: [FL.S]T align(64),
            input: *const [1024]T,
            output: *[1024]T,

            pub fn setup() @This() {
                var gpa = std.testing.allocator;
                const input = gpa.alloc(T, 1024) catch unreachable;
                input[0..1024].* = FL.transpose(arange(T, 1024));

                return .{
                    .base = [_]T{0} ** (1024 / @bitSizeOf(T)),
                    .input = input[0..1024],
                    .output = (gpa.alloc(T, 1024) catch unreachable)[0..1024],
                };
            }

            pub fn deinit(self: *const @This()) void {
                var gpa = std.testing.allocator;
                gpa.destroy(self.input);
                gpa.destroy(self.output);
            }

            pub fn run(self: @This()) void {
                Delta2(FL).encode(&self.base, self.input, self.output);
                std.mem.doNotOptimizeAway(self.output);
            }
        });
    }

    inline for (.{ u8, u16, u32, u64 }) |T| {
        const FL = fl.FastLanez(T, .{});

        try Bench("delta decode " ++ @typeName(T), .{}).bench(struct {
            base: [FL.S]T,
            input: [1024]T,

            pub fn setup() @This() {
                return .{
                    .base = [_]T{0} ** (1024 / @bitSizeOf(T)),
                    .input = .{1} ** 1024,
                };
            }

            pub fn run(self: @This()) void {
                var output: [1024]T = undefined;
                const d = Delta(FL).init(.{});
                @call(.never_inline, @TypeOf(d).decode, .{ d, &self.base, &self.input, &output });
                // Delta2(FL).decode(&base, &input, &output);
                std.mem.doNotOptimizeAway(output);
            }
        });
    }
}
