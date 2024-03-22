//! The C library for FastLanez.
const fl = @import("./fastlanez.zig");
const std = @import("std");

// Transpose
comptime {
    for (.{ u8, u16, u32, u64 }) |E| {
        const FL = fl.FastLanez(E);
        const Wrapper = struct {
            fn transpose(in: *const FL.Vector, out: *FL.Vector) callconv(.C) void {
                // TODO(ngates): check the performance of this. We may want tranpose to operate on pointers.
                out.* = FL.transpose(in.*);
            }

            fn untranspose(in: *const FL.Vector, out: *FL.Vector) callconv(.C) void {
                out.* = FL.untranspose(in.*);
            }
        };
        @export(Wrapper.transpose, .{ .name = "fl_transpose_" ++ @typeName(E) });
        @export(Wrapper.untranspose, .{ .name = "fl_untranspose_" ++ @typeName(E) });
    }
}

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

                fn decode(in: *const FL.PackedBytes(W), out: *FL.Vector) callconv(.C) void {
                    @call(.always_inline, BitPacking(FL).decode, .{ W, in, out });
                }
            };

            @export(Wrapper.encode, .{
                .name = "fl_bitpack_" ++ @typeName(E) ++ "_" ++ @typeName(std.meta.Int(.unsigned, W)),
            });
            @export(Wrapper.decode, .{
                .name = "fl_bitunpack_" ++ @typeName(E) ++ "_" ++ @typeName(std.meta.Int(.unsigned, W)),
            });
        }
    }
}

// Delta
comptime {
    const Delta = @import("./delta.zig").Delta;
    for (.{ u8, i8, u16, i16, u32, i32, u64, i64 }) |E| {
        const FL = fl.FastLanez(E);
        const D = Delta(FL);

        const Wrapper = struct {
            fn encode(
                in: *const FL.Vector,
                base: *FL.BaseVector,
                out: *FL.Vector,
            ) callconv(.C) void {
                D.encode(base, in, out);
                FL.store(base, 0, FL.load_transposed(in, FL.T - 1));
            }

            fn decode(in: *const FL.Vector, base: *const FL.BaseVector, out: *FL.Vector) callconv(.C) void {
                D.decode(base, in, out);
            }
        };

        @export(Wrapper.encode, .{ .name = "fl_delta_encode_" ++ @typeName(E) });
        @export(Wrapper.decode, .{ .name = "fl_delta_decode_" ++ @typeName(E) });
    }
}
