const std = @import("std");
const builtin = @import("builtin");
const cycleclock = @import("cycleclock");

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
