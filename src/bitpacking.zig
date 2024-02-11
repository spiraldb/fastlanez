pub fn BitPacking(comptime FL: type) type {
    return struct {
        pub fn encode(comptime W: comptime_int, in: *const FL.Vector, out: *FL.PackedBytes(W)) void {
            comptime var packer = FL.bitpacker(W);
            var tmp: FL.MM1024 = undefined;
            // FIXME(ngates): this pack function doesn't work if the loop isn't inlined at comptime.
            //  We should either accept i as an argument to make it harder to misuse? Or avoid stateful packers?
            inline for (0..FL.T) |i| {
                tmp = packer.pack(out, FL.load(in, i), tmp);
            }
        }

        pub fn decode(comptime W: comptime_int, in: *const FL.PackedBytes(W), out: *FL.Vector) void {
            comptime var unpacker = FL.bitunpacker(W);
            var tmp: FL.MM1024 = undefined;
            inline for (0..FL.T) |i| {
                const next, tmp = unpacker.unpack(in, tmp);
                FL.store(out, i, next);
            }
        }
    };
}

test "bitpack" {
    const std = @import("std");
    const fl = @import("./fastlanez.zig");
    const BP = BitPacking(fl.FastLanez(u8));

    const ints: [1024]u8 = .{2} ** 1024;
    var packed_ints: [384]u8 = undefined;
    BP.encode(3, &ints, &packed_ints);

    // Decimal 2 repeated as 3-bit integers in blocks of 1024 bits.
    try std.testing.expectEqual(
        .{0b10010010} ** 128 ++ .{0b00100100} ** 128 ++ .{0b01001001} ** 128,
        packed_ints,
    );

    var output: [1024]u8 = undefined;
    BP.decode(3, &packed_ints, &output);
    try std.testing.expectEqual(.{2} ** 1024, output);
}
