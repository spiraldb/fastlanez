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

// ALP
comptime {
    const ALP = @import("./alp.zig").ALP;
    for (.{ f32, f64 }) |E| {
        const A = ALP(E);

        const Wrapper = struct {
            fn encode(in: *const [1024]E, e: u8, f: u8, out: *[1024]A.I, exceptions: *A.Exceptions) callconv(.C) void {
                @call(.always_inline, A.encode, .{ in, e, f, out, exceptions });
            }

            fn decode(in: *const [1024]A.I, e: u8, f: u8, out: *[1024]E) callconv(.C) void {
                @call(.always_inline, A.decode, .{ in, e, f, out });
            }
        };

        @export(Wrapper.encode, .{ .name = "fl_alp_encode" ++ @typeName(E) });
        @export(Wrapper.decode, .{ .name = "fl_alp_decode" ++ @typeName(E) });
    }
}
