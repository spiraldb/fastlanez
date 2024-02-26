/// A FastLanez ISA implemented using scalar operations.
pub fn FastLanez_ISA_Scalar(comptime E: type) type {
    return struct {
        pub const Lane = E;

        pub inline fn add(a: Lane, b: Lane) Lane {
            return a +% b;
        }

        pub inline fn subtract(a: Lane, b: Lane) Lane {
            return a -% b;
        }

        pub inline fn or_(a: Lane, b: Lane) Lane {
            return a | b;
        }

        pub inline fn and_lshift(lane: Lane, n: anytype, mask: Lane) Lane {
            return (lane & mask) << n;
        }

        pub inline fn and_rshift(lane: Lane, n: anytype, mask: Lane) Lane {
            return (lane & (mask << n)) >> n;
        }
    };
}

pub fn FastLanez_ISA_ZIMD(comptime vectorWidth: comptime_int) fn (E: type) type {
    const Factory = struct {
        pub fn create(comptime E: type) type {
            return struct {
                pub const Lane = @Vector(vectorWidth / @bitSizeOf(E), E);

                pub inline fn add(a: Lane, b: Lane) Lane {
                    return a +% b;
                }

                pub inline fn subtract(a: Lane, b: Lane) Lane {
                    return a -% b;
                }

                pub inline fn and_(a: Lane, b: Lane) Lane {
                    return a & b;
                }

                pub inline fn or_(a: Lane, b: Lane) Lane {
                    return a | b;
                }

                pub inline fn and_lshift(lane: Lane, n: u8, mask: E) Lane {
                    const maskvec: Lane = @splat(mask);
                    const nvec: Lane = @splat(n);
                    return (lane & maskvec) << @intCast(nvec);
                }

                pub inline fn and_rshift(lane: Lane, n: u8, mask: E) Lane {
                    const maskvec: Lane = @splat(mask);
                    const nvec: Lane = @splat(n);
                    return (lane & (maskvec << nvec)) >> @intCast(nvec);
                }
            };
        }
    };
    return Factory.create;
}
