const std = @import("std");

const slimy = @import("../slimy.zig");
const oracle = @import("oracle.zig");

pub const width = 256;
pub const kernel_size = 15;
pub const tested_size = width - kernel_size + 1;
pub const half_kernel_width = @divFloor(kernel_size, 2);

pub fn computeSlime(world_seed: i64, min_x: i32, min_z: i32) [256]u256 {
    const lanes = width;

    const Vec64 = @Vector(lanes, i64);
    const Vec32 = @Vector(lanes, i32);

    const magic1: i32 = 4987142;
    const magic2: i32 = 5947611;

    const magic3: Vec32 = @splat(4392871);
    const magic4: Vec32 = @splat(389711);

    const magic5: Vec64 = @splat(987234911 ^ 0x5_de_ec_e6_6d);

    const multipliers: Vec64 = @splat(0x5_de_ec_e6_6d);
    const masks: Vec64 = @splat((1 << 48) - 1);

    const addends: Vec64 = @splat(0xb);

    var chunk: [width]u256 = undefined;

    var z_terms: [width]i64 = undefined;
    for (0..width) |i| {
        const z: i32 = min_z + @as(i32, @intCast(i));
        z_terms[i] = world_seed + @as(i64, z *% z) *% magic3[0] +% @as(i64, z *% magic4[0]);
    }

    var x_terms: [width]i64 = undefined;
    for (0..width) |i| {
        const x: i32 = min_x + @as(i32, @intCast(i));
        x_terms[i] = @as(i64, x *% x *% magic1) +% @as(i64, x *% magic2);
    }

    for (0..width) |i| {
        const x_term: Vec64 = @splat(x_terms[i]);

        const seed0: Vec64 = (x_term +% z_terms) ^ magic5 & masks;

        const seed1 = (seed0 *% multipliers +% addends) & masks;

        const bits: Vec32 = @intCast(seed1 >> @splat(17));

        chunk[i] = @bitCast(@intFromBool(@mod(bits, @as(Vec32, @splat(10))) == @as(Vec32, @splat(0))));
    }

    return chunk;
}

pub fn computeColumnsPacked(
    data: *align(64) const [256][16]u16,
    out: *align(64) [256][256]u8,
) void {
    for (0..4) |z| {
        var sum: @Vector(64, u8) = @splat(0);
        var previous_rows: [kernel_size]@Vector(64, u8) = undefined;

        inline for (0..kernel_size) |i| {
            const row: @Vector(64, u8) =
                @intFromBool(@as(
                    @Vector(64, bool),
                    @bitCast(data[i][z * 4 ..][0..4].*),
                ));

            previous_rows[i] = row;
            sum +%= row;
        }

        for (0..(256 - kernel_size) / kernel_size) |block| {
            inline for (0..kernel_size) |i| {
                const x = block * kernel_size + i;

                out[x][z * 64 ..][0..64].* = sum;

                const new_row: @Vector(64, u8) = @intFromBool(@as(
                    @Vector(64, bool),
                    @bitCast(data[x + kernel_size][z * 4 ..][0..4].*),
                ));

                sum +%= new_row -% previous_rows[i];
                previous_rows[i] = new_row;
            }
        }
        // do the remainder
        inline for ((256 - kernel_size) / kernel_size * kernel_size..256 - kernel_size, 0..) |x, i| {
            out[x][z * 64 ..][0..64].* = sum;

            const new_row: @Vector(64, u8) = @intFromBool(@as(
                @Vector(64, bool),
                @bitCast(data[x + kernel_size][z * 4 ..][0..4].*),
            ));

            sum +%= new_row -% previous_rows[i];
            previous_rows[i] = new_row;
        }
        // do the last element
        out[256 - kernel_size][z * 64 ..][0..64].* = sum;
    }
}

pub fn transpose(
    src: *align(64) const [width][width]u8,
    dst: *align(64) [width][width]u8,
) void {
    const block_width = 8;
    for (0..width / block_width) |x| {
        inline for (0..width / block_width) |z| {
            transpose8x8(src, dst, x * block_width, z * block_width);
        }
    }
}

fn transpose8x8(
    src: *align(64) const [width][width]u8,
    dst: *align(64) [width][width]u8,
    row: usize,
    col: usize,
) void {
    var block: [8][8]u8 = undefined;
    for (row.., 0..8) |x, i| {
        block[i] = src[x][col..][0..8].*;
    }

    const block_vec: @Vector(64, u8) = @bitCast(block);
    const permute_mask: @Vector(64, u8) = .{
        0, 8,  16, 24, 32, 40, 48, 56,
        1, 9,  17, 25, 33, 41, 49, 57,
        2, 10, 18, 26, 34, 42, 50, 58,
        3, 11, 19, 27, 35, 43, 51, 59,
        4, 12, 20, 28, 36, 44, 52, 60,
        5, 13, 21, 29, 37, 45, 53, 61,
        6, 14, 22, 30, 38, 46, 54, 62,
        7, 15, 23, 31, 39, 47, 55, 63,
    };

    const block_transposed: [8][8]u8 = @bitCast(@shuffle(u8, block_vec, undefined, permute_mask));
    for (col.., 0..8) |x, i| {
        dst[x][row..][0..8].* = block_transposed[i];
    }
}

pub fn computeColumns(
    src: *align(64) const [256][256]u8,
    out: *align(64) [256][256]u8,
) void {
    for (0..4) |z| {
        var sum: @Vector(64, u8) = @splat(0);
        var previous_rows: [kernel_size]@Vector(64, u8) = undefined;

        inline for (0..kernel_size) |i| {
            const row: @Vector(64, u8) = src[i][z * 64 ..][0..64].*;

            previous_rows[i] = row;
            sum +%= row;
        }

        for (0..(256 - kernel_size) / kernel_size) |block| {
            inline for (0..kernel_size) |i| {
                const x = block * kernel_size + i;

                out[x][z * 64 ..][0..64].* = sum;

                const new_row: @Vector(64, u8) = src[x + kernel_size][z * 64 ..][0..64].*;

                sum +%= new_row -% previous_rows[i];
                previous_rows[i] = new_row;
            }
        }
        // do the remainder
        inline for ((256 - kernel_size) / kernel_size * kernel_size..256 - kernel_size, 0..) |x, i| {
            out[x][z * 64 ..][0..64].* = sum;

            const new_row: @Vector(64, u8) = src[x + kernel_size][z * 64 ..][0..64].*;

            sum +%= new_row -% previous_rows[i];
            previous_rows[i] = new_row;
        }
        // do the last element
        out[256 - kernel_size][z * 64 ..][0..64].* = sum;
    }
}

pub fn search(
    data: *align(64) const [256][256]u8,
    min_x: i32,
    min_z: i32,
    params: slimy.SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
) void {
    const run_length = 15;
    const threshold: @Vector(64, u8) = @splat(params.threshold -| 4);
    for (0..width - run_length + 1) |x| {
        const counts0: @Vector(64, u8) = data[x][0..][0..64].*;
        const counts1: @Vector(64, u8) = data[x][64..][0..64].*;
        const counts2: @Vector(64, u8) = data[x][128..][0..64].*;
        const counts3: @Vector(64, u8) = data[x][192..][0..64].*;

        if (@reduce(.Or, counts0 > threshold) or @reduce(.Or, counts1 > threshold) or @reduce(.Or, counts2 > threshold) or @reduce(.Or, counts3 > threshold)) {
            @branchHint(.cold);
            for (data[x][0 .. width - run_length + 1], 0..) |count, z| {
                if (count >= params.threshold -| 4) {
                    confirm(
                        @as(i32, @intCast(z)) + min_x + half_kernel_width,
                        @as(i32, @intCast(x)) + min_z + half_kernel_width,
                        params,
                        context,
                        resultCallback,
                    );
                }
            }
        }
    }
}

pub noinline fn confirm(
    real_x: i32,
    real_z: i32,
    params: @import("../slimy.zig").SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
) void {
    if (real_x >= params.x0 and
        real_z >= params.z0 and
        real_x <= params.x1 and
        real_z <= params.z1)
    {
        const actual_count = oracle.computeKernelLocally(params.world_seed, real_x, real_z);
        if (actual_count >= params.threshold) {
            resultCallback(context, .{
                .x = real_x,
                .z = real_z,
                .count = actual_count,
            });
        }
    }
}

test computeSlime {
    const test_data = @import("test_data.zig");

    const sample = computeSlime(test_data.test_seed, 0, 0);
    for (0..test_data.block.len) |x| {
        for (0..test_data.block.len) |z| {
            const row: @Vector(256, u1) = @bitCast(sample[x]);
            try std.testing.expectEqual(test_data.block[z][x] == 'O', row[z] == 1);
        }
    }
    for (0..width) |x| {
        for (0..width) |z| {
            const row: @Vector(256, u1) = @bitCast(sample[x]);
            try std.testing.expectEqual(row[z] == 1, oracle.isSlime(0x51133, @intCast(x), @intCast(z)));
        }
    }
}

test computeColumnsPacked {
    const sample: [width]u256 align(64) = computeSlime(0x51133, 0, 0);
    var out: [width][width]u8 align(64) = @splat(@splat(0));
    computeColumnsPacked(@ptrCast(&sample), &out);

    for (0..width - kernel_size + 1) |x| {
        for (0..width) |z| {
            var count: u8 = 0;
            for (0..kernel_size) |j| {
                const row: @Vector(256, u1) = @bitCast(sample[x + j]);
                count += row[z];
            }
            try std.testing.expectEqual(count, out[x][z]);
        }
    }

    for (0..width - kernel_size + 1) |x| {
        for (0..width) |z| {
            var count: u8 = 0;
            for (0..kernel_size) |j| {
                count += @intFromBool(oracle.isSlime(
                    0x51133,
                    @intCast(x + j),
                    @intCast(z),
                ));
            }
            try std.testing.expectEqual(count, out[x][z]);
        }
    }
}

test computeColumns {
    var src: [width][width]u8 align(64) = undefined;

    var rand_impl: std.Random.Pcg = .init(0x51133);
    for (0..width) |x| {
        for (0..width) |z| {
            src[x][z] = rand_impl.random().int(u4);
        }
    }

    var out: [width][width]u8 align(64) = @splat(@splat(0));
    computeColumns(&src, &out);

    for (0..width - kernel_size + 1) |x| {
        for (0..width) |z| {
            var count: u8 = 0;
            for (0..kernel_size) |j| {
                count += src[x + j][z];
            }
            try std.testing.expectEqual(count, out[x][z]);
        }
    }
}

test transpose {
    var src: [width][width]u8 align(64) = undefined;

    var rand_impl: std.Random.Pcg = .init(0x51133);
    for (0..width) |x| {
        for (0..width) |z| {
            src[x][z] = rand_impl.random().int(u4);
        }
    }

    var out: [width][width]u8 align(64) = @splat(@splat(0));
    transpose(&src, &out);

    for (0..width) |x| {
        for (0..width) |z| {
            try std.testing.expectEqual(src[x][z], out[z][x]);
        }
    }
}

test search {
    const Context = struct {
        fn reportResult(context: *std.ArrayList(slimy.Result), result: slimy.Result) void {
            context.append(std.testing.allocator, result) catch {};
        }
    };

    var results: std.ArrayList(slimy.Result) = .empty;
    defer results.deinit(std.testing.allocator);

    const sample: [width]u256 align(64) = computeSlime(0x51133, 0, 0);

    var runs: [width][width]u8 align(64) = @splat(@splat(0));
    computeColumnsPacked(@ptrCast(&sample), &runs);

    var runs_transpose: [width][width]u8 align(64) = @splat(@splat(0));
    transpose(&runs, &runs_transpose);

    var complete_kernel: [width][width]u8 align(64) = @splat(@splat(0));
    computeColumns(&runs_transpose, &complete_kernel);

    search(&complete_kernel, 0, 0, .{ .x0 = -10000, .x1 = 10000, .z0 = -10000, .z1 = 10000, .threshold = 0, .world_seed = 0x51133 }, &results, Context.reportResult);

    for (0..width - kernel_size + 1) |x| {
        for (0..width - kernel_size + 1) |z| {
            var count: u8 = 0;
            for (0..kernel_size) |x_inner| {
                for (0..kernel_size) |z_inner| {
                    count += @intFromBool(oracle.isSlime(
                        0x51133,
                        @intCast(x + x_inner),
                        @intCast(z + z_inner),
                    ));
                }
            }
            try std.testing.expectEqual(count, complete_kernel[z][x]);
        }
    }

    for (results.items) |result| {
        try std.testing.expectEqual(
            oracle.computeKernelLocally(0x51133, result.x, result.z),
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

            const slime: [256]u256 align(64) = computeSlime(
                params.world_seed,
                params.x0 + @as(i32, @intCast(block_x * tested_size)) - half_kernel_width,
                params.z0 + @as(i32, @intCast(block_z * tested_size)) - half_kernel_width,
            );

            var runs: [256][256]u8 align(64) = undefined;
            computeColumnsPacked(@ptrCast(&slime), &runs);

            var runs_transpose: [256][256]u8 align(64) = undefined;
            transpose(&runs, &runs_transpose);

            var complete_kernel: [256][256]u8 align(64) = undefined;
            computeColumns(&runs_transpose, &complete_kernel);

            search(
                &complete_kernel,
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
