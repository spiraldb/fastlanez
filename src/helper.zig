pub fn arange(comptime T: type, comptime n: comptime_int) [n]T {
    @setEvalBranchQuota(10_000);
    const std = @import("std");
    var result: [n]T = undefined;
    for (0..n) |i| {
        result[i] = @intCast(i % std.math.maxInt(T));
    }
    return result;
}
