/// A FastLanez ISA implemented using scalar operations.
pub fn FastLanez_ISA_Scalar(comptime E: type) type {
    return struct {
        pub const MM = E;

        pub inline fn add(a: MM, b: MM) MM {
            return a +% b;
        }

        pub inline fn subtract(a: MM, b: MM) MM {
            return a -% b;
        }

        pub inline fn or_(a: MM, b: MM) MM {
            return a | b;
        }

        pub inline fn and_lshift(lane: MM, n: anytype, mask: MM) MM {
            return (lane & mask) << n;
        }

        pub inline fn and_rshift(lane: MM, n: anytype, mask: MM) MM {
            return (lane & (mask << n)) >> n;
        }
    };
}

pub fn FastLanez_ISA_ZIMD(comptime vectorWidth: comptime_int) fn (E: type) type {
    const Factory = struct {
        pub fn create(comptime E: type) type {
            return struct {
                pub const MM = @Vector(vectorWidth / @bitSizeOf(E), E);

                pub inline fn add(a: MM, b: MM) MM {
                    return a +% b;
                }

                pub inline fn subtract(a: MM, b: MM) MM {
                    return a -% b;
                }

                pub inline fn and_(a: MM, b: MM) MM {
                    return a & b;
                }

                pub inline fn or_(a: MM, b: MM) MM {
                    return a | b;
                }

                pub inline fn and_lshift(lane: MM, n: u8, mask: E) MM {
                    const maskvec: MM = @splat(mask);
                    const nvec: MM = @splat(n);
                    return (lane & maskvec) << @intCast(nvec);
                }

                pub inline fn and_rshift(lane: MM, n: u8, mask: E) MM {
                    const maskvec: MM = @splat(mask);
                    const nvec: MM = @splat(n);
                    return (lane & (maskvec << nvec)) >> @intCast(nvec);
                }
            };
        }
    };
    return Factory.create;
}
