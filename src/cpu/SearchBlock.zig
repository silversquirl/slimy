const std = @import("std");
const scalar = @import("slime_check.zig").scalar;
const simd = @import("slime_check.zig").simd;
const slimy = @import("../slimy.zig");

pub const width = 256;
pub const tested_size: comptime_int = width - mask.len + 1;
pub const offset: comptime_int = @divFloor(mask.len, 2);

data: [width][width]u8,
min_x: i32,
min_z: i32,

/// initialized chunks with scalar code
pub inline fn initScalar(self: *@This(), world_seed: i64, min_x: i32, min_z: i32) void {
    self.min_x = min_x - offset;
    self.min_z = min_z - offset;

    for (0..width) |rel_x| {
        for (0..width) |rel_z| {
            const abs_x: i32 = min_x - offset + @as(i32, @intCast(rel_x));
            const abs_z: i32 = min_z - offset + @as(i32, @intCast(rel_z));

            self.data[rel_x][rel_z] = @intFromBool(scalar.isSlime(world_seed, abs_x, abs_z));
        }
    }
}

pub fn initSimd(self: *@This(), world_seed: i64, min_x: i32, min_z: i32) void {
    @setRuntimeSafety(false);

    const lanes = width;

    self.min_x = min_x - offset;
    self.min_z = min_z - offset;

    const Vec64 = @Vector(lanes, i64);
    const Vec32 = @Vector(lanes, i32);

    const magic1: i32 = 4987142;
    const magic2: i32 = 5947611;

    const magic3: Vec32 = @splat(4392871);
    const magic4: Vec32 = @splat(389711);

    const magic5: Vec64 = @splat(987234911);

    const multipliers: Vec64 = @splat(0x5deece66d);
    const masks: Vec64 = @splat((1 << 48) - 1);
    const addends: Vec64 = @splat(0xb);

    const world_seeds: Vec64 = @splat(world_seed);

    const zs: Vec32 = @as(Vec32, @splat(self.min_z)) + std.simd.iota(i32, lanes);
    const zs_premultiplied: Vec64 =
        @as(Vec64, zs *% zs) *% magic3 +%
        @as(Vec64, zs *% magic4);

    for (0..width) |i| {
        const x: i32 = self.min_x + @as(i32, @intCast(i));
        const x_premultiplied: i64 =
            @as(i64, x *% x *% magic1) +%
            @as(i64, x *% magic2);
        const xs_premultiplied: Vec64 = @splat(x_premultiplied);

        var seed: Vec64 = (world_seeds +%
            xs_premultiplied +%
            zs_premultiplied) ^
            magic5;

        seed = seed ^ multipliers & masks;

        seed = (seed *% multipliers +% addends) & masks;

        const bits: Vec32 = @intCast(seed >> @splat(17));

        self.data[i] = @intFromBool(@mod(bits, @as(Vec64, @splat(10))) == @as(Vec64, @splat(0)));
    }
}

/// For each chunk (x, z), outputs the amount of slime chunks in (x, z - 7)..[x, z]
/// to a separate buffer
pub fn preprocess(self: *@This()) void {
    @setRuntimeSafety(false);

    const chunk_len = 7;
    for (0..width) |x| {
        for (0..width - chunk_len + 1) |z| {
            var count: u8 = 0;
            for (0..chunk_len) |j| count +%= @bitCast(self.data[x][z + j]);
            self.data[x][z] |= count << 4;
        }
    }
    // const chunk_len = 7;
    // var vec: @Vector(width, u8) = @splat(0);
    // for (0..chunk_len) |x| {
    //     vec += self.data[x];
    // }
    // for (0..width - chunk_len) |x| {
    //     self.data[x] = (vec << @splat(4)) | self.data[x];
    //     vec += self.data[x + chunk_len];
    //     vec -= self.data[x];
    // }
    // self.data[width - chunk_len] = (vec << @splat(4)) | self.data[width - chunk_len];
}

/// [.@] - ignore
/// [+] - use preprocessed value
/// [-] - use preprocessed value but subtract slime value of chunk
/// [o] - use slime value of chunk
const mask: [17][17]u8 = .{
    strip(". . . . . . . . o . . . . . . . .".*),
    strip(". . . . . + @ @ @ @ @ @ . . . . .".*),
    strip(". . . + @ @ @ @ @ @ o o o o . . .".*),
    strip(". . + @ @ @ @ @ - @ @ @ @ @ @ . .".*),
    strip(". . + @ @ @ @ @ - @ @ @ @ @ @ . .".*),
    strip(". + @ @ @ @ @ @ + @ @ @ @ @ @ o .".*),
    strip(". + @ @ @ @ @ @ + @ @ @ @ @ @ o .".*),
    strip(". + @ @ @ @ @ @ . + @ @ @ @ @ @ .".*),
    strip("+ @ @ @ @ @ @ . . . + @ @ @ @ @ @".*),
    strip(". + @ @ @ @ @ @ . + @ @ @ @ @ @ .".*),
    strip(". + @ @ @ @ @ @ + @ @ @ @ @ @ o .".*),
    strip(". + @ @ @ @ @ @ + @ @ @ @ @ @ o .".*),
    strip(". . + @ @ @ @ @ - @ @ @ @ @ @ . .".*),
    strip(". . + @ @ @ @ @ - @ @ @ @ @ @ . .".*),
    strip(". . . + @ @ @ @ @ @ o o o o . . .".*),
    strip(". . . . . + @ @ @ @ @ @ . . . . .".*),
    strip(". . . . . . . . o . . . . . . . .".*),
};

/// Strips spaces from string
pub fn strip(string: [17 + 16]u8) [17]u8 {
    var out: [17]u8 = undefined;
    var i = 0;
    for (string) |char| {
        if (char != ' ') {
            out[i] = char;
            i += 1;
        }
    }
    return out;
}

const Location = struct { x: usize, z: usize };

/// add preprocessed value to count
const run_7 = blk: {
    var coords: [26]Location = undefined;
    var i: usize = 0;
    for (mask, 0..) |row, x| for (row, 0..) |char, z| {
        if (char == '+' or char == '-') {
            coords[i] = .{ .x = x, .z = z };
            i += 1;
        }
    };

    break :blk coords;
};

/// add slime value of cell to count
const add = blk: {
    var coords: [14]Location = undefined;
    var i: usize = 0;
    for (mask, 0..) |row, x| for (row, 0..) |char, z| {
        if (char == 'o') {
            coords[i] = .{ .x = x, .z = z };
            i += 1;
        }
    };

    break :blk coords;
};

/// subtract binary value of cell from count
const sub = blk: {
    var coords: [4]Location = undefined;
    var i: usize = 0;
    for (mask, 0..) |row, x| for (row, 0..) |char, z| {
        if (char == '-') {
            coords[i] = .{ .x = x, .z = z };
            i += 1;
        }
    };

    break :blk coords;
};

/// For every chunk within the searched area defined by this `SearchBlock`
/// checks whether the amount of slime chunk slime chunks in spawn range of a player
/// at the center of each chunk meets the given `threshold`
pub fn calculateSliminess(
    self: *@This(),
    params: slimy.SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
) void {
    for (0..width - mask.len + 1) |x| {
        for (0..width - mask.len + 1) |z| {
            var count: u8 = 0;

            var run_7_count: u16 = 0;
            inline for (run_7[0..15]) |location| run_7_count += self.data[x + location.x][z + location.z];
            count += @intCast(run_7_count >> 4);

            run_7_count = 0;
            inline for (run_7[15..]) |location| run_7_count += self.data[x + location.x][z + location.z];
            count += @intCast(run_7_count >> 4);

            var add_count: u16 = 0;
            inline for (add) |location| add_count += self.data[x + location.x][z + location.z];
            count += @intCast(add_count & 0xf);

            var sub_count: u16 = 0;
            inline for (sub) |location| sub_count += self.data[x + location.x][z + location.z];
            count -= @intCast(sub_count & 0xf);

            if (count >= params.threshold) {
                @branchHint(.cold);
                const real_x = @as(i32, @intCast(x + offset)) + self.min_x;
                const real_z = @as(i32, @intCast(z + offset)) + self.min_z;
                if (real_x >= params.x0 and real_x < params.x1 and
                    real_z >= params.z0 and real_z < params.z1)
                {
                    resultCallback(context, .{
                        .x = real_x,
                        .z = real_z,
                        .count = count,
                    });
                }
            }
        }
    }
}

pub fn calculateSliminessForLocation(world_seed: i64, x: i32, z: i32) u8 {
    var count: u8 = 0;
    for (0..mask.len) |x_0| {
        for (0..mask.len) |z_0| {
            const slime = scalar.isSlime(
                world_seed,
                x + @as(i32, @intCast(x_0)) - offset,
                z + @as(i32, @intCast(z_0)) - offset,
            );
            count += @intFromBool(bit_mask[x_0][z_0] and slime);
        }
    }
    return count;
}

const bit_mask: [17][17]bool = blk: {
    const inner = 1;
    const outer = 8;
    const dim = 2 * outer + 1;
    var dist_mask: [dim][dim]bool = undefined;
    for (&dist_mask, 0..) |*row, y| {
        for (row, 0..) |*bit, x| {
            const rx = @as(i32, @intCast(x)) - outer;
            const ry = @as(i32, @intCast(y)) - outer;
            const d2 = rx * rx + ry * ry;
            bit.* = inner * inner < d2 and d2 <= outer * outer;
        }
    }
    break :blk dist_mask;
};

test initScalar {
    const test_seed = @import("test_data.zig").test_seed;

    var chunk: @This() = undefined;
    chunk.initScalar(test_seed, offset, offset);

    const block = @import("test_data.zig").block;
    for (block, 0..) |row, z| {
        for (row, 0..) |c, x| {
            try std.testing.expectEqual(c == 'O', chunk.data[x][z] == 1);
        }
    }
}

test initSimd {
    const test_seed = @import("test_data.zig").test_seed;
    var chunk: @This() = undefined;
    chunk.initSimd(test_seed, offset, offset);

    const block = @import("test_data.zig").block;
    for (block, 0..) |row, z| {
        for (row, 0..) |c, x| {
            try std.testing.expectEqual(c == 'O', chunk.data[x][z] == 1);
        }
    }
}

test "initSimd/initScalar parity" {
    var chunk1: @This() = undefined;
    var chunk2: @This() = undefined;
    chunk1.initScalar(0x51133, 0xbeef, -0x51133135);
    chunk2.initSimd(0x51133, 0xbeef, -0x51133135);
    try std.testing.expectEqual(
        chunk1,
        chunk2,
    );
}

test preprocess {
    if (true) return error.SkipZigTest;

    var chunk = initSimd(0x51133, offset, offset);
    chunk.preprocess();
    for (0..width) |x| {
        for (0..width) |z| {
            std.debug.print("{}", .{chunk.data[x][z] >> 4});
        }
        std.debug.print("\n", .{});
    }
}

test calculateSliminess {
    // if (true) return error.SkipZigTest;

    const Context = struct {
        allocator: std.mem.Allocator,
        results: *std.ArrayList(slimy.Result),
        fn reportResult(context: @This(), result: slimy.Result) void {
            context.results.append(context.allocator, result) catch {};
        }
    };

    const test_seed = 0x51133;
    var results: std.ArrayList(slimy.Result) = .empty;
    defer results.deinit(std.testing.allocator);
    var chunk: @This() = undefined;
    chunk.initSimd(test_seed, 0, 0);
    chunk.preprocess();
    chunk.calculateSliminess(
        .{ .x0 = 0, .x1 = width, .z0 = 0, .z1 = width, .method = undefined, .threshold = 22, .world_seed = test_seed },
        @as(Context, .{ .allocator = std.testing.allocator, .results = &results }),
        Context.reportResult,
    );

    // try std.testing.expectEqual(tested_size * tested_size, results.items.len);
    for (results.items) |result| {
        std.testing.expectEqual(calculateSliminessForLocation(test_seed, result.x, result.z), result.count) catch {};
    }
}
