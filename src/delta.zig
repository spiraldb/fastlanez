pub fn Delta(comptime FastLanes: type) type {
    const FL = FastLanes;
    const E = FastLanes.E;

    return struct {
        const std = @import("std");

        pub fn encode(base: *const [FL.S]E, in: *const FL.Vector, out: *FL.Vector) void {
            var prev = FL.load(base, 0);
            inline for (0..FL.T) |i| {
                const next = FL.load(in, i);
                const result = FL.subtract(next, prev);
                prev = next;
                FL.store(out, i, result);
            }
        }

        pub fn decode(base: *const [FL.S]E, in: *const FL.Vector, out: *FL.Vector) void {
            var prev = FL.load(base, 0);
            inline for (0..FL.T) |i| {
                const delta = FL.load(in, i);
                const result = FL.add(prev, delta);
                prev = result;
                FL.store(out, i, result);
            }
        }

        pub fn pack(comptime W: comptime_int, base: *const [FL.S]E, in: *const FL.Vector, out: *FL.PackedBytes(W)) void {
            comptime var packer = FL.BitPacker(W){};
            var tmp: FL.MM1024 = undefined;

            var prev = FL.load(base, 0);
            inline for (0..FL.T) |i| {
                const next = FL.load(in, i);
                const result = FL.subtract(next, prev);
                prev = next;

                tmp = packer.pack(out, result, tmp);
            }
        }

        pub fn unpack(comptime W: comptime_int, base: *const [FL.S]E, in: *const FL.PackedBytes(W), out: *FL.Vector) void {
            comptime var packer = FL.BitUnpacker(W){};
            var tmp: FL.MM1024 = undefined;

            var prev = FL.load(base, 0);
            inline for (0..FL.T) |i| {
                const next, tmp = packer.unpack(in, tmp);
                const result = FL.add(prev, next);
                FL.store(out, i, result);
                prev = result;
            }
        }
    };
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
    Delta(FL).encode(&base, &tinput, &actual);

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

test "fastlanez bench delta encode" {
    const std = @import("std");
    const fl = @import("fastlanes.zig");
    const Bench = @import("bench.zig").Bench;

    inline for (.{ u8, u16, u32, u64 }) |T| {
        const FL = fl.FastLanez(T, .{});

        try Bench("delta encode " ++ @typeName(T), .{}).bench(struct {
            const base = [_]T{0} ** (1024 / @bitSizeOf(T));
            const input: [1024]T = .{1} ** 1024;

            pub fn run(_: @This()) void {
                var output: [1024]T = undefined;
                Delta(FL).encode(&base, &input, &output);
                std.mem.doNotOptimizeAway(output);
            }
        });
    }
}

test "fastlanez bench delta decode" {
    const std = @import("std");
    const fl = @import("fastlanes.zig");
    const Bench = @import("bench.zig").Bench;

    inline for (.{ u8, u16, u32, u64 }) |T| {
        const FL = fl.FastLanez(T, .{});

        try Bench("delta decode " ++ @typeName(T), .{}).bench(struct {
            const base = [_]T{0} ** (1024 / @bitSizeOf(T));
            const input: [1024]T = .{1} ** 1024;

            pub fn run(_: @This()) void {
                var output: [1024]T = undefined;
                Delta(FL).decode(&base, &input, &output);
                std.mem.doNotOptimizeAway(output);
            }
        });
    }
}

test "fastlanez bench delta pack" {
    const std = @import("std");
    const fl = @import("fastlanes.zig");
    const Bench = @import("bench.zig").Bench;

    inline for (.{ u8, u16, u32, u64 }) |T| {
        const FL = fl.FastLanez(T, .{});

        try Bench("delta pack " ++ @typeName(T), .{}).bench(struct {
            const base = [_]T{0} ** (1024 / @bitSizeOf(T));
            const input: [1024]T = .{1} ** 1024;

            pub fn run(_: @This()) void {
                var output: [384]u8 = undefined;
                Delta(FL).pack(3, &base, &input, &output);
                std.mem.doNotOptimizeAway(output);
            }
        });
    }
}

test "fastlanez bench delta unpack" {
    const std = @import("std");
    const fl = @import("fastlanes.zig");
    const Bench = @import("bench.zig").Bench;

    inline for (.{ u8, u16, u32, u64 }) |T| {
        const FL = fl.FastLanez(T, .{});

        try Bench("delta unpack " ++ @typeName(T), .{}).bench(struct {
            base: [1024 / @bitSizeOf(T)]T,
            delta: [384]u8,

            pub fn setup() @This() {
                const base = [_]T{0} ** (1024 / @bitSizeOf(T));
                const input: [1024]T = .{1} ** 1024;
                var delta: [384]u8 = undefined;
                Delta(FL).pack(3, &base, &input, &delta);
                return .{ .base = base, .delta = delta };
            }

            pub fn run(self: *const @This()) void {
                var output: [1024]T = undefined;
                Delta(FL).unpack(3, &self.base, &self.delta, &output);
                std.mem.doNotOptimizeAway(output);
            }
        });
    }
}
