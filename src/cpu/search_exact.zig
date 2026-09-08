const std = @import("std");
const slimy = @import("../slimy.zig");
const oracle = @import("oracle.zig");

pub const width = 256;
pub const tested_size: comptime_int = width - kernel.len + 1;
pub const half_kernel_width: comptime_int = @divFloor(kernel.len, 2);

pub fn computeSlime(world_seed: i64, min_x: i32, min_z: i32) [width][width]u8 {
    const lanes = width;

    const Vec64 = @Vector(lanes, i64);
    const Vec32 = @Vector(lanes, i32);

    const magic1: i32 = 4987142;
    const magic2: i32 = 5947611;

    const magic3: i32 = 4392871;
    const magic4: i32 = 389711;

    const magic5: Vec64 = @splat(987234911 ^ 0x5_de_ec_e6_6d);

    const multipliers: Vec64 = @splat(0x5_de_ec_e6_6d);
    const masks: Vec64 = @splat((1 << 48) - 1);

    const addends: Vec64 = @splat(0xb);

    var chunk: [width][width]u8 = undefined;

    var x_terms: [width]i64 = undefined;
    for (0..width) |i| {
        const x: i32 = min_x + @as(i32, @intCast(i));
        x_terms[i] = @as(i64, x *% x *% magic1) +% @as(i64, x *% magic2);
    }

    var z_terms: [width]i64 = undefined;
    for (0..width) |i| {
        const z: i32 = min_z + @as(i32, @intCast(i));
        z_terms[i] = world_seed + @as(i64, z *% z) *% magic3 +% @as(i64, z *% magic4);
    }

    for (0..width) |i| {
        const x_term: Vec64 = @splat(x_terms[i]);

        const seed0: Vec64 = (x_term +% z_terms) ^ magic5 & masks;

        const seed1 = (seed0 *% multipliers +% addends) & masks;

        const bits: Vec32 = @intCast(seed1 >> @splat(17));

        chunk[i] = @intFromBool(@mod(bits, @as(Vec32, @splat(10))) == @as(Vec32, @splat(0)));
    }

    return chunk;
}

/// For each chunk (x, z), outputs the amount of slime chunks in (x, z)..[x + 7, z]
pub fn computeColumns(data: *align(64) [width][width]u8) void {
    @setRuntimeSafety(false);

    const chunk_len = 7;
    var vec: @Vector(width, u8) = @splat(0);
    for (0..chunk_len) |x| {
        vec += data[x];
    }
    for (0..width - chunk_len) |x| {
        data[x] = (vec << @splat(4)) | data[x];
        vec +%= data[x + chunk_len];
        vec -%= data[x];
    }
    data[width - chunk_len] = (vec << @splat(4)) | data[width - chunk_len];
}

/// For every chunk within the searched area defined by this `SearchBlock`
/// checks whether the amount of slime chunk slime chunks in spawn range of a player
/// at the center of each chunk meets the given `threshold`
pub fn computeKernel(
    data: *align(64) [width][width]u8,
    min_x: i32,
    min_z: i32,
    params: slimy.SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
) void {
    for (0..width - kernel.len + 1) |x| {
        for (0..width - kernel.len + 1) |z| {
            var count: u8 = 0;

            var run_7_count: u16 = 0;
            inline for (run[0..15]) |location| run_7_count += data[x + location.x][z + location.z];
            count += @intCast(run_7_count >> 4);

            run_7_count = 0;
            inline for (run[15..]) |location| run_7_count += data[x + location.x][z + location.z];
            count += @intCast(run_7_count >> 4);

            var add_count: u16 = 0;
            inline for (add) |location| add_count += data[x + location.x][z + location.z];
            count += @intCast(add_count & 0xf);

            var sub_count: u16 = 0;
            inline for (sub) |location| sub_count += data[x + location.x][z + location.z];
            count -= @intCast(sub_count & 0xf);

            if (count >= params.threshold) {
                @branchHint(.cold);
                const real_x = @as(i32, @intCast(x + half_kernel_width)) + min_x;
                const real_z = @as(i32, @intCast(z + half_kernel_width)) + min_z;
                if (real_x >= params.x0 and
                    real_x <= params.x1 and
                    real_z >= params.z0 and
                    real_z <= params.z1)
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

const kernel: [17][17]u8 = .{
    "........+........".*,
    ".....+++@+++.....".*,
    "...++@@@@@@@++...".*,
    "..+@@@@@@@@@@@+..".*,
    "..@@@@@@@@@@@@@..".*,
    ".+@@@@@@@@@@@@@+.".*,
    ".@@@@@@@@@@@@@@@.".*,
    ".@@@@@@@.@@@@@@@.".*,
    "o@@--++...++--@@o".*,
    ".@@@@@@+.+@@@@@@.".*,
    ".@o@@@@@+@@@@@o@.".*,
    ".@o@@@@@@@@@@@o@.".*,
    "..o@@@@@@@@@@@o..".*,
    "..o@@@@@@@@@@@o..".*,
    "...@@@@@@@@@@@...".*,
    ".....oo@@@oo.....".*,
    "........@........".*,
};

// in a 15x15 centered block:
// say we have a score of x.
// what's the highest the true score can be?
// say all invalid squares are 0
// then say all 4 of the valid squares not counted are 1
// then the actual score would be x + 4
// so, if our threshold is t, and we see a score of t - 4, we must actually check.
// if our threshold is 50?
// what are the chances of getting count >= 50 - 4 in 225 squares?
// very low (0.0000022627259798069232), aka 1 in 441945

const Location = struct { x: i32, z: i32 };

/// add preprocessed value to count
const run = blk: {
    var coords: [26]Location = undefined;
    var i: usize = 0;
    for (kernel, 0..) |row, x| for (row, 0..) |char, z| {
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
    for (kernel, 0..) |row, x| for (row, 0..) |char, z| {
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
    for (kernel, 0..) |row, x| for (row, 0..) |char, z| {
        if (char == '-') {
            coords[i] = .{ .x = x, .z = z };
            i += 1;
        }
    };

    break :blk coords;
};

test computeSlime {
    const test_seed = @import("test_data.zig").test_seed;
    const data = computeSlime(test_seed, 0, 0);

    const block = @import("test_data.zig").block;
    for (block, 0..) |row, z| {
        for (row, 0..) |c, x| {
            try std.testing.expectEqual(c == 'O', data[x][z] == 1);
        }
    }
}

test computeColumns {
    var data: [width][width]u8 align(64) = computeSlime(0x51153, 0, 0);
    computeColumns(&data);

    const chunk_len = 7;
    for (0..width - chunk_len + 1) |x| {
        for (0..width) |z| {
            var count: u8 = 0;
            for (0..chunk_len) |j| count += data[x + j][z] & 0xf;
            try std.testing.expectEqual(count, data[x][z] >> 4);
        }
    }
}

test computeKernel {
    const Context = struct {
        fn reportResult(context: *std.ArrayList(slimy.Result), result: slimy.Result) void {
            context.append(std.testing.allocator, result) catch {};
        }
    };

    const test_seed = 0x51133;

    var results: std.ArrayList(slimy.Result) = .empty;
    defer results.deinit(std.testing.allocator);

    var block_data: [256][256]u8 align(64) = computeSlime(test_seed, 0, 0);
    computeColumns(&block_data);
    computeKernel(
        &block_data,
        0,
        0,
        .{
            .x0 = 0,
            .z0 = 0,
            .x1 = width,
            .z1 = width,
            .threshold = 0,
            .world_seed = test_seed,
        },
        &results,
        Context.reportResult,
    );

    try std.testing.expectEqual(tested_size * tested_size, results.items.len);
    for (results.items) |result| {
        try std.testing.expectEqual(
            oracle.computeKernelLocally(test_seed, result.x, result.z),
            result.count,
        );
    }
}

test "full search" {
    if (true) return;
    const Context = struct {
        fn reportResult(context: *std.ArrayList(slimy.Result), result: slimy.Result) void {
            context.append(std.testing.allocator, result) catch {};
        }
    };

    for (@as([]const u8, &.{ 0, 5, 10, 17, 22, 31, 39 })) |threshold| {
        var results: std.ArrayList(slimy.Result) = .empty;
        defer results.deinit(std.testing.allocator);

        var oracle_results: std.ArrayList(slimy.Result) = .empty;
        defer oracle_results.deinit(std.testing.allocator);

        const params: slimy.SearchParams = .{ .threshold = threshold, .world_seed = 0x51133, .x0 = -1000, .z0 = -1000, .x1 = 1000, .z1 = 1000 };

        oracle.search(params, &oracle_results, Context.reportResult);

        const blocks_w = std.math.divCeil(usize, @intCast(params.x1 - params.x0), tested_size) catch unreachable;
        const blocks_h = std.math.divCeil(usize, @intCast(params.z1 - params.z0), tested_size) catch unreachable;

        // split blocks as evenly as possible
        for (0..blocks_w * blocks_h) |block_index| {
            const block_x = block_index / blocks_w;
            const block_z = @mod(block_index, blocks_w);

            var data: [256][256]u8 align(64) = computeSlime(
                params.world_seed,
                params.x0 + @as(i32, @intCast(block_x * tested_size)) - half_kernel_width,
                params.z0 + @as(i32, @intCast(block_z * tested_size)) - half_kernel_width,
            );

            computeColumns(&data);

            computeKernel(
                &data,
                params.x0 + @as(i32, @intCast(block_x * tested_size)) - half_kernel_width,
                params.z0 + @as(i32, @intCast(block_z * tested_size)) - half_kernel_width,
                params,
                &results,
                Context.reportResult,
            );
        }

        std.sort.block(slimy.Result, results.items, {}, slimy.Result.sortLessThan);
        std.sort.block(slimy.Result, oracle_results.items, {}, slimy.Result.sortLessThan);
        try std.testing.expectEqualSlices(slimy.Result, oracle_results.items, results.items);
    }
}
