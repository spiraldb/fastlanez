const std = @import("std");
const Allocator = std.mem.Allocator;

// Apache Arrow is only 64 byte aligned, meaning we cannot always be zero-copy with 1024 bit vectors
// unless we convince Arrow (fork? Recompile?) to align to 128 bytes.
const FLWidth = 512;

fn FLVec(comptime V: type) type {
    return @Vector(FLWidth / @bitSizeOf(V), V);
}

/// Pack and unpack integers of width T into packed width W.
pub fn PackedInts(comptime T: u8, comptime W: u8) type {
    return struct {
        pub const V = @Type(.{ .Int = .{ .signedness = .unsigned, .bits = T } });
        pub const P = @Type(.{ .Int = .{ .signedness = .unsigned, .bits = W } });

        const elemsPerTranche = FLWidth;
        const bytesPerTranche = @as(usize, W) * @sizeOf(FLVec(V));

        /// The number of bytes required to encode the given elements.
        pub fn encodedSize(length: usize) usize {
            const ntranches = length / elemsPerTranche;
            const remainder = length % FLWidth;
            const remainderBytes = ((W * remainder) + 7) / 8;
            return (ntranches * bytesPerTranche) + remainderBytes;
        }

        pub fn encode(elems: []const V, encoded: []align(128) u8) void {
            // Encode as many tranches as we can, and then fallback to scalar?
            const ntranches = elems.len / elemsPerTranche;

            const in: []const FLVec(V) = @alignCast(std.mem.bytesAsSlice(FLVec(V), std.mem.sliceAsBytes(elems[0 .. ntranches * elemsPerTranche])));
            var out: []FLVec(V) = @alignCast(std.mem.bytesAsSlice(FLVec(V), encoded[0 .. ntranches * bytesPerTranche]));

            for (0..ntranches) |i| {
                encode_tranche(in[T * i ..][0..T], out[W * i ..][0..W]);
            }

            // Is there a nicer fallback to have?
            const remaining = elems[ntranches * elemsPerTranche ..];
            var packedInts = std.PackedIntSlice(P){
                .bytes = encoded[ntranches * bytesPerTranche ..],
                .bit_offset = 0,
                .len = remaining.len,
            };
            for (remaining, 0..) |e, i| {
                packedInts.set(i, @truncate(e));
            }
        }

        /// A single tranche takes T input vectors and produces W output vectors.
        fn encode_tranche(in: *const [T]FLVec(V), out: *[W]FLVec(V)) void {
            comptime var bitIdx = 0;
            comptime var outIdx = 0;
            var tmp: FLVec(V) = undefined;
            inline for (0..T) |t| {
                // Grab the next input vector and mask out the bits of W
                var src = in[t];
                src = src & bitmask(W);

                // Either we reset tmp, or we OR it into tmp.
                // If we didn't assign, we would need to reset to zero which
                // adds an extra instruction.
                if (bitIdx == 0) {
                    tmp = src;
                } else {
                    tmp |= src << @splat(bitIdx);
                }
                bitIdx += W;

                if (bitIdx == T) {
                    // We've exactly filled tmp with packed ints
                    out[outIdx] = tmp;
                    outIdx += 1;
                    bitIdx = 0;
                } else if (bitIdx > T) {
                    // The last value didn't completely fit, so store what
                    // we have and carry forward the remainder to the next
                    // loop using tmp.
                    out[outIdx] = tmp;
                    outIdx += 1;
                    bitIdx -= T;

                    tmp = src >> @splat(W - bitIdx);
                }
            }
        }

        pub fn decode(encoded: []align(128) const u8, elems: []V) void {
            const ntranches = elems.len / elemsPerTranche;

            const in: []const FLVec(V) = @alignCast(std.mem.bytesAsSlice(FLVec(V), encoded[0 .. ntranches * bytesPerTranche]));
            var out: []FLVec(V) = @alignCast(std.mem.bytesAsSlice(FLVec(V), std.mem.sliceAsBytes(elems[0 .. ntranches * elemsPerTranche])));
            for (0..ntranches) |i| {
                decode_tranche(in[W * i ..][0..W], out[T * i ..][0..T]);
            }

            const remaining = elems[ntranches * elemsPerTranche ..];
            const packedInts = std.PackedIntSlice(P){
                .bytes = @constCast(encoded[ntranches * bytesPerTranche ..]),
                .bit_offset = 0,
                .len = remaining.len,
            };
            for (0..remaining.len) |i| {
                remaining[i] = packedInts.get(i);
            }
        }

        fn decode_tranche(in: *const [W]FLVec(V), out: *[T]FLVec(V)) void {
            // Construct a bit-mask to extract integers of width W
            var src = in[0];
            comptime var inIdx = 1;
            comptime var bitIdx: usize = 0;
            inline for (0..T) |t| {
                // Take as many bits as we can without overflowing T
                const bits = @min(T - bitIdx, W);

                const tmp = and_rshift(src, bitIdx, bitmask(bits));
                bitIdx += bits;

                if (bitIdx < T) {
                    // We have all the bits for the output t
                    out[t] = tmp;
                } else {
                    // Otherwise, we may need to load some bits from the next input
                    if (inIdx == in.len) {
                        // No more input
                        out[t] = tmp;
                        return;
                    }

                    src = in[inIdx];
                    inIdx += 1;

                    // TODO(ngates): check that this gets optimized away if W == bits
                    out[t] = tmp | and_lshift(src, bits, bitmask(W - bits));
                    bitIdx = W - bits;
                }
            }
        }

        pub fn count_exceptions(elems: []const V) usize {
            var count: usize = 0;
            for (elems) |elem| {
                if (T - @clz(elem) > W) {
                    count += 1;
                }
            }
            return count;
        }

        pub fn collect_exceptions(elems: []const V, exception_indices: []u64, exceptions: []V) void {
            // TODO(ngates): SIMD
            var offset: usize = 0;
            for (elems, 0..) |elem, i| {
                if (T - @clz(elem) > W) {
                    if (offset >= exception_indices.len) {
                        std.debug.print("Expected {} exceptions, found more\n", .{exceptions.len});
                        @panic("FAILED");
                    }
                    std.debug.assert(offset < exception_indices.len);
                    exception_indices[offset] = i;
                    exceptions[offset] = elem;
                    offset += 1;
                }
            }
        }

        inline fn bitmask(comptime bits: comptime_int) FLVec(V) {
            return @splat((1 << bits) - 1);
        }

        // forall T−bit lanes i in REG return (i & MASK) << N
        inline fn and_lshift(vec: FLVec(V), n: anytype, mask: FLVec(V)) FLVec(V) {
            // TODO(ngates): can we make this more efficient?
            const nVec: FLVec(V) = @splat(n);
            return (vec & mask) << @intCast(nVec);
        }

        // forall T−bit lanes i in REG return (i & (MASK << N)) >> N
        inline fn and_rshift(vec: FLVec(V), n: anytype, mask: FLVec(V)) FLVec(V) {
            const nVec: FLVec(V) = @splat(n);
            return (vec & (mask << nVec)) >> @intCast(nVec);
        }
    };
}

test "fastlanes packedints encodedSize" {
    // Pack 8 bit ints into 2 bit ints.
    try std.testing.expectEqual(@as(usize, 256), PackedInts(8, 2).encodedSize(1024));

    // Pack 8 bit ints into 6 bit ints
    try std.testing.expectEqual(@as(usize, 768), PackedInts(8, 6).encodedSize(1024));
}

test "fastlanes packedints" {
    // We test int packing for all values of 1<W<T and T in {8, 16, 32, 64};
    // Also with a reasonable spread of values for N to catch edge cases.

    const Ns = [_]usize{ 0, 6, 100, FLWidth, 10_000 };
    const Ts = [_]u8{ 8, 16, 32, 64 };

    inline for (Ts) |t| {
        //This is a lot of code-gen for tests. Maybe we should run it? Maybe not.
        //inline for (1..t) |w| {
        for (Ns) |n| {
            try testPackedInts(n, t, @intCast((t + 1) / 2));
        }
        //}
    }
}

fn testPackedInts(N: usize, comptime T: u8, comptime W: u8) !void {
    const ally = std.testing.allocator;
    const ints = PackedInts(T, W);

    // Setup N values cycling through 0..T
    var values = try ally.alignedAlloc(ints.V, 128, N);
    defer ally.free(values);
    for (0..N) |i| {
        // Cycle through the values 0 -> maxInt(Packed)
        const value = i % (std.math.maxInt(ints.P) + 1);
        values[i] = @truncate(value);
    }

    const bytes = try ally.alignedAlloc(u8, 128, ints.encodedSize(N));
    defer ally.free(bytes);
    ints.encode(values, bytes);

    const result = try ally.alignedAlloc(ints.V, 128, N);
    defer ally.free(result);
    ints.decode(bytes, result);

    try std.testing.expectEqualSlices(ints.V, values, result);
}

fn benchPackedInts(N: usize, comptime T: u8, comptime W: u8) !void {
    const ally = std.testing.allocator;
    const ints = PackedInts(T, W);

    // Setup N values. Can be constant, has no impact on performance.
    const values = try ally.alignedAlloc(ints.V, 128, N);
    defer ally.free(values);
    @memset(values, 1);

    // Create an output slice
    const bytes = try ally.alignedAlloc(u8, 128, ints.encodedSize(N));
    defer ally.free(bytes);

    // Encode the ints
    var timer = try std.time.Timer.start();
    ints.encode(values, bytes);
    const encode_ns = timer.lap();
    std.debug.print("FL ENCODE u{} -> u{}: {} ints in {}ms\n", .{ T, W, N, encode_ns / 1_000_000 });
    std.debug.print("{} million ints per second\n", .{1000 * N / (encode_ns + 1)});

    timer.reset();
    ints.decode(bytes, values);
    const decode_ns = timer.lap();
    std.debug.print("FL DECODE u{} -> u{}: {} ints in {}ms\n", .{ T, W, N, decode_ns / 1_000_000 });
    std.debug.print("{} million ints per second\n", .{1000 * N / (decode_ns + 1)});
}
