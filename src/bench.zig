const std = @import("std");
const builtin = @import("builtin");
const cycleclock = @import("cycleclock");
const fl = @import("fastlanes.zig");

const dbg = builtin.mode == .Debug;

pub const Options = struct {
    warmup: comptime_int = if (dbg) 0 else 1_000,
    iterations: comptime_int = if (dbg) 1 else 3_000_000,
};

pub fn Bench(comptime name: []const u8, comptime options: Options) type {
    return struct {
        pub fn bench(comptime Unit: type) !void {
            std.debug.print("Benchmarking {s} - {} iterations", .{ name, options.iterations });

            const unit = if (@hasDecl(Unit, "setup")) Unit.setup() else Unit{};

            for (0..options.warmup) |_| {
                std.mem.doNotOptimizeAway(unit.run());
            }

            const start = cycleclock.now();
            for (0..options.iterations) |_| {
                std.mem.doNotOptimizeAway(unit.run());
            }
            const stop = cycleclock.now();
            const cycles = stop - start;

            if (cycles == 0) {
                std.debug.print(", failed to measure cycles.\n", .{});
                return;
            }

            const cycles_per_tuple = @as(f64, @floatFromInt(cycles)) / @as(f64, @floatFromInt(1024 * options.iterations));
            std.debug.print(", {d:.3} cycles per tuple", .{cycles_per_tuple});
            std.debug.print(", {} tuples per cycle\n", .{1024 * options.iterations / cycles});
        }
    };
}

fn bench_delta_pack() !void {
    const Delta = @import("./delta.zig").Delta;

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

fn bench_delta_unpack() !void {
    const Delta = @import("./delta.zig").Delta;

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

pub fn main() !void {
    try bench_delta_pack();
    try bench_delta_unpack();
}
