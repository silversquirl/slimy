const std = @import("std");

/// Tests whether the given chunk at (x, z) is a slime chunk
pub fn isSlime(world_seed: i64, x: i32, z: i32) bool {
    var random = Random.init(getRandomSeed(world_seed, x, z));
    return random.nextInt(10) == 0;
}

/// Tests whether the given chunk at (x, z) is a slime chunk
/// Uses a biased random function that is faster but very occasionally
/// (<1 in 100,000,000) gives an incorrect result
pub fn isSlimeBiased(world_seed: i64, x: i32, z: i32) bool {
    var random = Random.init(getRandomSeed(world_seed, x, z));
    return random.nextIntBiased(10) == 0;
}

/// Returns the seed used by the PRNG for the chunk (x, z)
pub fn getRandomSeed(world_seed: i64, x: i32, z: i32) i64 {
    return world_seed +%
        @as(i64, x *% x *% 4987142) +%
        @as(i64, x *% 5947611) +%
        @as(i64, z *% z) *% 4392871 +%
        @as(i64, z *% 389711) ^
        987234911;
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

            const biased = bits - val +% (bound - 1) < 0;
            if (!biased) break;
        }
        return val;
    }

    /// Calculates a random number between 0 (inclusive) and `bound` (exclusive)
    /// Skips bias correction, but very occasionally (<1 in 100,000,000) gives an incorrect result
    pub fn nextIntBiased(self: *@This(), comptime bound: i32) i32 {
        if (bound <= 0) @compileError("bound must be positive");

        if (comptime std.math.isPowerOfTwo(bound)) {
            return @intCast((bound * @as(i64, self.next(31))) >> 31);
        }

        const bits: i32 = self.next(31);
        const val: i32 = @mod(bits, bound);
        return val;
    }

    test nextIntBiased {
        // We expect `nextIntBiased` to be incorrect on this seed
        const seed: i64 = 304837631;
        var random1 = @This().init(seed);
        var random2 = @This().init(seed);
        try std.testing.expect(random1.nextInt(10) != random2.nextIntBiased(10));
    }
};

comptime {
    _ = Random;
}

test isSlime {
    const test_block = @import("../test_data.zig").block;
    for (test_block, 0..) |row, z| {
        for (row, 0..) |c, x| {
            try std.testing.expectEqual(c == 'O', isSlime(0x51133, @intCast(x), @intCast(z)));
        }
    }

    const random = @import("../test_data.zig").random;
    for (random) |location| {
        try std.testing.expectEqual(location.slime, isSlime(0x51133, location.x, location.z));
    }
}
