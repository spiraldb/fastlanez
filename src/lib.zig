//! The C library for FastLanez.
const fl = @import("./fastlanez.zig");
const std = @import("std");

// BitPacking
comptime {
    const BitPacking = @import("./bitpacking.zig").BitPacking;
    for (.{ u8, u16, u32, u64 }) |E| {
        const FL = fl.FastLanez(E);

        for (1..FL.T) |W| {
            const Wrapper = struct {
                fn encode(in: *const FL.Vector, out: *FL.PackedBytes(W)) callconv(.C) void {
                    @call(.always_inline, BitPacking(FL).encode, .{ W, in, out });
                }
            };

            @export(Wrapper.encode, .{
                .name = "fl_bitpack_" ++ @typeName(E) ++ "_" ++ @typeName(std.meta.Int(.unsigned, W)),
            });
        }
    }
}
