const std = @import("std");

/// This is experimentally faster than the value std.simd.suggestVectorLength gives, which is 4
pub const lanes = 8;

pub const Vec64 = @Vector(lanes, i64);
pub const Vec32 = @Vector(lanes, i32);
pub const Vecb = @Vector(lanes, bool);

/// Tests whether the chunks [x, y]..(x, z + lanes) are slime chunks
pub fn areSlime(world_seed: i64, x: i32, z: i32) Vecb {
    var random = Random.init(getRandomSeeds(world_seed, x, z));
    return random.nextInts(10) == @as(Vec32, @splat(0));
}

/// Tests whether the chunks [x, y]..(x, z + lanes) are slime chunks
/// Uses a biased random function that is faster but very occasionally
/// (<1 in 100,000,000) gives an incorrect result
pub fn areSlimeBiased(world_seed: i64, x: i32, z: i32) Vecb {
    var random = Random.init(getRandomSeeds(world_seed, x, z));
    return random.nextIntsBiased(10) == @as(Vec32, @splat(0));
}

/// Returns the seeds used by the PRNG for chunks [x, z]..(x, z + lanes)
/// See scalar.zig
pub fn getRandomSeeds(world_seed: i64, x: i32, z: i32) Vec64 {
    const world_seeds: Vec64 = @splat(world_seed);

    const x_increment: Vec64 = @splat(
        @as(i64, x *% x *% 4987142) +%
            @as(i64, x *% 5947611),
    );

    const magic1: Vec64 = @splat(4392871);
    const magic2: Vec32 = @splat(389711);

    const zs: Vec32 = @as(Vec32, @splat(z)) + @as(Vec32, .{ 0, 1, 2, 3, 4, 5, 6, 7 });
    const z_increment =
        @as(Vec64, zs *% zs) *% magic1 +%
        @as(Vec64, zs *% magic2);

    const magic3: Vec64 = @splat(987234911);
    return world_seeds +% x_increment +% z_increment ^ magic3;
}

/// Calculates `lanes` random numbers in parallel
pub const Random = struct {
    seed: Vec64,

    pub const multiplier: Vec64 = @splat(0x5deece66d);
    pub const mask: Vec64 = @splat((1 << 48) - 1);
    pub const addend: Vec64 = @splat(0xb);

    pub fn init(seed: Vec64) @This() {
        return .{ .seed = seed ^ multiplier & mask };
    }

    pub fn next(self: *@This(), comptime bits: i32) Vec32 {
        self.seed = (self.seed *% multiplier +% addend) & mask;
        return @intCast(self.seed >> @as(Vec64, @splat(48 - bits)));
    }

    /// Calculates `lanes` random numbers between 0 (inclusive) and `bound` (exclusive)
    pub fn nextInts(self: *@This(), comptime bound: i32) Vec32 {
        if (bound <= 0) @compileError("bound must be positive");

        if (comptime std.math.isPowerOfTwo(bound)) {
            return @intCast((bound * @as(i64, self.next(31))) >> 31);
        }

        const bounds: Vec32 = @splat(bound);

        const bits: Vec32 = self.next(31);
        const val: Vec32 = @mod(bits, bounds);
        const biased = bits - val +% @as(Vec32, @splat(bound - 1)) < @as(Vec32, @splat(0));
        if (@reduce(.Or, biased)) {
            return self.fixBias(bound, val, biased);
        }
        return val;
    }

    pub noinline fn fixBias(self: *@This(), comptime bound: i32, val_in: Vec32, biased_in: Vecb) Vec32 {
        @setCold(true);
        const bounds: Vec32 = @splat(bound);

        var bits: Vec32 = self.next(31);
        var val: Vec32 = val_in;
        var biased = biased_in;

        while (@reduce(.Or, biased)) {
            bits = self.next(31);
            val = @select(i32, biased, @mod(bits, bounds), val);
            biased = @bitCast(
                @intFromBool(biased) &
                    @intFromBool(bits - val +% @as(Vec32, @splat(bound - 1)) <
                    @as(Vec32, @splat(0))),
            );
        }
        return val;
    }

    /// Calculates `lanes` random numbers between 0 (inclusive) and `bound` (exclusive)
    /// Skips bias correction, but very occasionally (<1 in 100,000,000) gives an incorrect result
    pub fn nextIntsBiased(self: *@This(), comptime bound: i32) Vec32 {
        if (bound <= 0) @compileError("bound must be positive");

        if (comptime std.math.isPowerOfTwo(bound)) {
            return @intCast((bound * @as(i64, self.next(31))) >> 31);
        }

        const bounds: Vec32 = @splat(bound);

        const bits: Vec32 = self.next(31);
        const val: Vec32 = @mod(bits, bounds);
        return val;
    }

    test nextIntsBiased {
        // We expect `nextIntsBiased` to be incorrect on this seed
        const seed: i64 = 304837631;
        var random1 = @This().init(@splat(seed));
        var random2 = @This().init(@splat(seed));
        try std.testing.expect(random1.nextInts(10)[0] != random2.nextIntsBiased(10)[0]);
    }
};

comptime {
    _ = Random;
}

test areSlime {
    const test_block = @import("../test_data.zig").block;
    for (test_block, 0..) |row, z| {
        for (row, 0..) |c, x| {
            try std.testing.expectEqual(c == 'O', areSlime(0x51133, @intCast(x), @intCast(z))[0]);
        }
    }

    const random = @import("../test_data.zig").random;
    for (random) |location| {
        try std.testing.expectEqual(location.slime, areSlime(0x51133, location.x, location.z)[0]);
    }
}

test "scalar simd parity" {
    var rng = std.Random.DefaultPrng.init(0x51133);
    const rand = rng.random();

    for (0..10000) |_| {
        const x = rand.intRangeAtMost(i32, -30_000_000 / 16, 30_000_000 / 16);
        const z = rand.intRangeAtMost(i32, -30_000_000 / 16, 30_000_000 / 16);
        try std.testing.expectEqual(@import("scalar.zig").isSlime(0x51133, x, z), areSlime(0x51133, x, z)[0]);
    }
}
