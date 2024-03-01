//! The C library for FastLanez.
const fl = @import("./fastlanez.zig");
const std = @import("std");

// BitPacking
comptime {
    const BitPacking = @import("./bitpacking.zig").BitPacking;
    for (.{u8}) |E| {
        const FL = fl.FastLanez(E);

        const bit_packing_widths = blk: {
            var widths_: [FL.T]u8 = undefined;
            for (0..FL.T) |i| {
                widths_[i] = @intCast(i);
            }
            break :blk widths_;
        };

        for (bit_packing_widths) |W| {
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
