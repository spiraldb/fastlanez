pub fn BitPacking(comptime FastLanes: type) type {
    const FL = FastLanes;

    return struct {
        const std = @import("std");

        pub fn pack(comptime W: comptime_int, in: *const FL.Vector, out: *FL.PackedBytes(W)) void {
            comptime var packer = FL.BitPacker(W){};
            var tmp: FL.MM1024 = undefined;
            inline for (0..FL.T) |i| {
                tmp = packer.pack(out, FL.load_raw(in, i), tmp);
            }
        }

        pub fn unpack(comptime W: comptime_int, in: *const FL.PackedBytes(W), out: *FL.Vector) void {
            comptime var unpacker = FL.BitUnpacker(W){};
            var tmp: FL.MM1024 = undefined;
            inline for (0..FL.T) |i| {
                const next, tmp = unpacker.unpack(in, tmp);
                FL.store_raw(out, i, next);
            }
        }
    };
}

test "fastlanez bitpack" {
    const std = @import("std");
    const fl = @import("./fastlanes.zig");
    const BP = BitPacking(fl.FastLanez(u8, .{}));

    const ints: [1024]u8 = .{2} ** 1024;
    var packed_ints: [384]u8 = undefined;
    BP.pack(3, &ints, &packed_ints);

    // Decimal 2 repeated as 3-bit integers in blocks of 1024 bits.
    try std.testing.expectEqual(
        .{0b10010010} ** 128 ++ .{0b00100100} ** 128 ++ .{0b01001001} ** 128,
        packed_ints,
    );

    var output: [1024]u8 = undefined;
    BP.unpack(3, &packed_ints, &output);
    try std.testing.expectEqual(.{2} ** 1024, output);
}

test "fastlanez bitpack pack bench" {
    const std = @import("std");
    const fl = @import("./fastlanes.zig");
    const Bench = @import("bench.zig").Bench;
    const BP = BitPacking(fl.FastLanez(u8, .{}));
    const ints: [1024]u8 = .{2} ** 1024;

    try Bench("pack u8 -> u3", .{}).bench(struct {
        pub fn run(_: @This()) void {
            var packed_ints: [384]u8 = undefined;
            BP.pack(3, &ints, &packed_ints);
            std.mem.doNotOptimizeAway(packed_ints);
        }
    });
}

test "fastlanez bitpack unpack bench" {
    const std = @import("std");
    const fl = @import("./fastlanes.zig");
    const Bench = @import("bench.zig").Bench;
    const BP = BitPacking(fl.FastLanez(u8, .{}));

    // Decimal 2 repeated as 3-bit integers in blocks of 1024 bits.
    const packed_ints: [384]u8 = .{0b10010010} ** 128 ++ .{0b00100100} ** 128 ++ .{0b01001001} ** 128;

    try Bench("unpack u8 <- u3", .{}).bench(struct {
        pub fn run(_: @This()) void {
            var unpacked_ints: [1024]u8 = undefined;
            BP.unpack(3, &packed_ints, &unpacked_ints);
            std.mem.doNotOptimizeAway(unpacked_ints);
        }
    });
}
