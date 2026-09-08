/// Reference implementations using simple, unoptimized scalar code.
const std = @import("std");
const slimy = @import("../slimy.zig");

/// Tests whether the chunk at (x, z) is a slime chunk
pub fn isSlime(world_seed: i64, x: i32, z: i32) bool {
    var random: Random = .init(getRandomSeed(world_seed, x, z));
    return random.nextInt(10) == 0;
}

/// Tests whether the chunk at (x, z) is a slime chunk
/// Uses a biased random function that is faster but very
/// occasionally (8 in 2147483648) gives an incorrect result
pub fn isSlimeBiased(world_seed: i64, x: i32, z: i32) bool {
    var random: Random = .init(getRandomSeed(world_seed, x, z));
    return random.nextIntBiased(10) == 0;
}

/// Returns the seed used to initialize PRNG for the chunk (x, z)
pub fn getRandomSeed(world_seed: i64, x: i32, z: i32) i64 {
    return world_seed +%
        @as(i64, x *% x *% 4987142) +%
        @as(i64, x *% 5947611) +%
        @as(i64, z *% z) *% 4392871 +%
        @as(i64, z *% 389711) ^
        987234911;
}

pub fn computeKernelLocally(world_seed: i64, x: i32, z: i32) u8 {
    var count: u8 = 0;

    const inner = 1;
    const outer = 8;

    var x_0: i32 = -outer;
    while (x_0 <= outer) : (x_0 += 1) {
        var z_0: i32 = -outer;
        while (z_0 <= outer) : (z_0 += 1) {
            const slime = isSlime(
                world_seed,
                x_0 + x,
                z_0 + z,
            );
            const d2 = x_0 * x_0 + z_0 * z_0;

            count += @intFromBool(d2 > inner * inner and d2 <= outer * outer and slime);
        }
    }
    return count;
}

pub fn search(
    params: slimy.SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
) void {
    @setRuntimeSafety(false);
    var x: i32 = params.x0;
    while (x <= params.x1) : (x += 1) {
        var z: i32 = params.z0;
        while (z <= params.z1) : (z += 1) {
            const count = computeKernelLocally(params.world_seed, x, z);
            if (count >= params.threshold) resultCallback(context, .{
                .count = count,
                .x = x,
                .z = z,
            });
        }
    }
}

/// A linear congruential pseudo-random number generator. Ported from the Java standard library.
pub const Random = struct {
    seed: i64,

    pub const multiplier = 0x5deece66d;
    pub const mask = (1 << 48) - 1;
    pub const addend = 0xb;

    pub fn init(seed: i64) @This() {
        return .{ .seed = seed ^ multiplier & mask };
    }

    pub fn next(self: *@This(), comptime bits: i32) i32 {
        self.seed = (self.seed *% multiplier +% addend) & mask;
        return @intCast(self.seed >> 48 - bits);
    }

    /// Calculates a random number between 0 (inclusive) and `bound` (exclusive)
    pub fn nextInt(self: *@This(), comptime bound: i32) i32 {
        if (bound <= 0) @compileError("bound must be positive");

        if (comptime std.math.isPowerOfTwo(bound)) {
            return @intCast((bound * @as(i64, self.next(31))) >> 31);
        }

        var bits: i32 = undefined;
        var val: i32 = undefined;
        while (true) {
            bits = self.next(31);
            val = @mod(bits, bound);

            const biased: bool = bits - val +% (bound - 1) < 0;

            if (biased) {
                continue;
            }
            return val;
        }
    }

    /// Calculates a random number between 0 (inclusive) and `bound` (exclusive)
    /// Skips bias correction and is thus slightly faster, but very
    /// occasionally (8 in 2147483648) gives an incorrect result
    pub fn nextIntBiased(self: *@This(), comptime bound: i32) i32 {
        if (bound <= 0) @compileError("bound must be positive");

        if (comptime std.math.isPowerOfTwo(bound)) {
            return @intCast((bound * @as(i64, self.next(31))) >> 31);
        }

        const bits: i32 = self.next(31);
        return @mod(bits, bound);
    }

    test nextIntBiased {
        // We expect `nextIntBiased` to be incorrect on this seed
        const seed: i64 = 304837631;
        var random1: Random = .init(seed);
        var random2: Random = .init(seed);
        try std.testing.expect(random1.nextInt(10) != random2.nextIntBiased(10));
    }

    test "bias check parity" {
        if (true) return error.SkipZigTest;

        const bound = 10;
        for (0..std.math.maxInt(i31) + 1) |bits_u64| {
            const bits: i32 = @intCast(bits_u64);
            const val: i32 = @mod(bits, bound);
            // first is used in java implementation
            // second one is faster
            try std.testing.expectEqual(
                bits - val +% (bound - 1) < 0,
                bits > 2147483639,
            );
        }
    }

    test "bias rate" {
        if (true) return error.SkipZigTest;
        var pcg: std.Random.Pcg = .init(0x51133);
        const pcg_rand = pcg.random();

        for (0..2_000_000_000) |_| {
            const world_seed = pcg_rand.int(i64);
            const x = pcg_rand.intRangeAtMost(i32, -30_000_000 / 16, 30_000_000 / 16);
            const z = pcg_rand.intRangeAtMost(i32, -30_000_000 / 16, 30_000_000 / 16);

            var random: Random = .init(getRandomSeed(
                world_seed,
                x,
                z,
            ));

            if (random.next(31) > 2147483639) {
                // recalculate bits
                var rand: Random = .init(getRandomSeed(world_seed, x, z));
                std.debug.print("seed: {}, raw: {}\n", .{ rand.seed, rand.next(31) });
                std.debug.print("{} {} {}\n", .{ world_seed, x, z });
            }
        }
    }
};

test {
    _ = Random;
}

test isSlime {
    const test_seed = @import("test_data.zig").test_seed;
    const test_block = @import("test_data.zig").block;
    for (test_block, 0..) |row, z| {
        for (row, 0..) |c, x| {
            try std.testing.expectEqual(c == 'O', isSlime(test_seed, @intCast(x), @intCast(z)));
        }
    }

    const random = @import("test_data.zig").random;
    for (random) |location| {
        try std.testing.expectEqual(location.slime, isSlime(test_seed, location.x, location.z));
    }
}
