const std = @import("std");
const math = std.math;

pub fn ALP(comptime E: type) type {
    if (@typeInfo(E) != .Float) {
        @compileError("ALP only supports floating point");
    }

    const fl = @import("./fastlanez.zig");
    const FL = fl.FastLanez(E);
    const FLI = fl.FastLanez(std.meta.Int(.signed, FL.T));

    return struct {
        pub const Exceptions = struct {
            exceptions: FL.Vector,
            count: usize,
        };

        /// Given 1024 floats, encode them as f * 10^e * 10^(-f)
        pub fn encode(in: *const FL.Vector, e: u8, f: u8, out: *FLI.Vector, exceptions: *Exceptions) void {
            @setFloatMode(.Optimized);
            exceptions.count = 0;

            inline for (0..FL.T) |i| {
                const next = FL.load(in, i);

                const encoded = fast_round(next * FL.splat(F10[e]) * FL.splat(i_F10[f]));

                // Check for any values that fail to round-trip.
                const decoded = encoded * FL.splat(F10[f]) * FL.splat(i_F10[e]);
                const exception_mask = decoded != next;

                exceptions.count += @reduce(.Add, @as(@Vector(FL.S, u8), @intFromBool(exception_mask)));
                FL.store(&exceptions.exceptions, i, @select(FL.E, exception_mask, next, FL.splat(0)));

                // Mask out the exceptions from the result so they don't affect bit-packing.
                FLI.store(out, i, @intFromFloat(@select(FL.E, exception_mask, FLI.splat(0.0), encoded)));
            }
        }

        /// Given 1024 floats, decode them as f * 10^f * 10^(-e)
        pub fn decode(in: *const FLI.Vector, e: u8, f: u8, out: *FL.Vector) void {
            inline for (0..FL.T) |i| {
                const next: FL.MM1024 = @floatFromInt(FLI.load(in, i));
                const decoded = next * FL.splat(F10[f]) * FL.splat(i_F10[e]);
                FL.store(out, i, decoded);
            }
        }

        const sweet: FL.MM1024 = @splat(blk: {
            const bits = math.floatFractionalBits(FL.E);
            break :blk @as(FL.E, @floatFromInt(1 << bits)) + @as(FL.E, @floatFromInt(1 << bits - 1));
        });

        /// Quickly round a vector of floats to the nearest integer
        pub inline fn fast_round(x: FL.MM1024) FL.MM1024 {
            return (x + sweet) - sweet;
        }

        const F10: [21]FL.E = blk: {
            @setEvalBranchQuota(4096);
            var f10: [21]FL.E = undefined;
            for (0..21) |i| {
                // We parse from a string to avoid floating point errors in generating powers of 10
                f10[i] = std.fmt.parseFloat(FL.E, "1" ++ "0" ** i) catch unreachable;
            }
            break :blk f10;
        };

        const i_F10: [21]FL.E = blk: {
            @setEvalBranchQuota(4096);
            var i_f10: [21]FL.E = undefined;
            i_f10[0] = 1.0;
            for (1..21) |i| {
                // We parse from a string to avoid floating point errors in generating powers of 10
                i_f10[i] = std.fmt.parseFloat(FL.E, "0." ++ "0" ** (i - 1) ++ "1") catch unreachable;
            }
            break :blk i_f10;
        };
    };
}

test "alp F10 i_F10" {
    inline for (.{ f32, f64 }) |T| {
        const A = ALP(T);
        try std.testing.expectEqual(1.0, A.F10[0]);
        try std.testing.expectEqual(10.0, A.F10[1]);
        try std.testing.expectEqual(100.0, A.F10[2]);
        try std.testing.expectEqual(1.0, A.i_F10[0]);
        try std.testing.expectEqual(0.1, A.i_F10[1]);
        try std.testing.expectEqual(0.01, A.i_F10[2]);
    }
}

test "alp" {
    const A = ALP(f64);
    const e = 14;
    const f = 12;

    const floats = .{1.23} ** 1024;

    var encoded: [1024]i64 = undefined;
    var exceptions: A.Exceptions = undefined;
    A.encode(&floats, e, f, &encoded, &exceptions);
    try std.testing.expectEqual(0, exceptions.count);

    var decoded: [1024]f64 = undefined;
    A.decode(&encoded, e, f, &decoded);
    try std.testing.expectEqual(floats, decoded);
}

test "alp exceptions" {
    const A = ALP(f64);
    // With a low e, f we can trigger an exception.
    const e = 6;
    const f = 4;
    const crazy = 1.11111111111111;

    const floats = .{1.23} ** 1022 ++ .{crazy} ** 2;
    var encoded: [1024]i64 = undefined;
    var exceptions: A.Exceptions = undefined;
    A.encode(&floats, e, f, &encoded, &exceptions);

    try std.testing.expectEqual(2, exceptions.count);
    try std.testing.expectEqual(.{0.0} ** 1022 ++ .{crazy} ** 2, exceptions.exceptions);
    try std.testing.expectEqual(.{123} ** 1022 ++ .{ 0, 0 }, encoded);
}
