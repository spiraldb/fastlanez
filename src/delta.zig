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

test "fastlanez delta bench" {
    const std = @import("std");
    const arange = @import("helper.zig").arange;

    const builtin = @import("builtin");
    const dbg = builtin.mode == .Debug;

    const warmup = 0;
    const iterations = if (dbg) 1_000 else 10_000_000;

    inline for (.{ u16, u32, u64 }) |T| {
        inline for (.{Delta(T)}) |Codec| {
            const base = [_]T{0} ** (1024 / @bitSizeOf(T));
            const input = arange(T, 1024);

            for (0..warmup) |_| {
                var actual: [1024]T = undefined;
                Codec.encode(base, input, &actual);
            }

            var time: i128 = 0;
            for (0..iterations) |_| {
                const start = std.time.nanoTimestamp();
                var actual: [1024]T = undefined;
                Codec.encode(&base, &input, &actual);
                std.mem.doNotOptimizeAway(actual);
                // Codec.encode(base, input, &actual);
                const stop = std.time.nanoTimestamp();
                time += stop - start;
            }

            const clock_freq = 3.48; // GHz

            const total_nanos = @as(f64, @floatFromInt(time));
            const total_ms = total_nanos / 1_000_000;
            const total_cycles = total_nanos * clock_freq;

            const total_elems = iterations * 1024;
            const elems_per_cycle = total_elems / total_cycles;
            const cycles_per_elem = total_cycles / total_elems;

            std.debug.print("Completed {} iterations of {}\n", .{ iterations, Codec });
            std.debug.print("\t{d:.2} ms total.\n", .{total_ms});
            std.debug.print("\t{d:.1} elems / cycle\n", .{elems_per_cycle});
            std.debug.print("\t{d:.1} cycles / elem\n", .{cycles_per_elem});
            std.debug.print("\t{d:.2} billion elems / second\n", .{total_elems / total_nanos});
            std.debug.print("\n", .{});
        }
    }
}
