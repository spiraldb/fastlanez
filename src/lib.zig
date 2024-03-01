//! The C library for FastLanez.
const fl = @import("./fastlanez.zig");
const std = @import("std");

// BitPacking
comptime {
    const BitPacking = @import("./bitpacking.zig").BitPacking;
    for (.{u8}) |E| {
        const FL = fl.FastLanez(E);

        for (1..@bitSizeOf(E)) |W| {
            // TODO(ngates): configure this in build.zig
            const dbg = @import("builtin").mode == .Debug;
            if (dbg and !std.math.isPowerOfTwo(W)) {
                // Avoid too much code-gen in debug mode.
                continue;
            }

            const Wrapper = struct {
                fn encode(in: *const FL.Vector, out: *FL.PackedBytes(W)) callconv(.C) void {
                    @call(.always_inline, BitPacking(FL).encode, .{ W, in, out });
                }
            };

            @export(Wrapper.encode, .{
                .name = "bitpack_" ++ @typeName(E) ++ "_" ++ @typeName(std.meta.Int(.unsigned, W)),
                .linkage = .Strong,
            });
        }
    }
}
