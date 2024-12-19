const std = @import("std");
const scalar = @import("slime_check/scalar.zig");
const simd = @import("slime_check/simd.zig");
const slimy = @import("../slimy.zig");

pub const size = 256;
pub const tested_size: comptime_int = size - mask.len + 1;
pub const offset: comptime_int = @divFloor(mask.len, 2);

comptime {
    var cell: Cell = .{ .slime = 0b0000, .strip_count = 0b1111 };
    std.debug.assert(@as(u8, @bitCast(cell)) == 0b11110000);
    cell = .{ .slime = 0b1101, .strip_count = 0b1000 };
    std.debug.assert(@as(u8, @bitCast(cell)) == 0b10001101);
}

pub const Cell = packed struct {
    /// least significant bits
    slime: u4,
    /// most significant bits
    strip_count: u4,
};

data: [size * size]Cell,
min_x: i32,
min_z: i32,

/// initialized chunks with scalar code
pub fn initScalar(world_seed: i64, min_x: i32, min_z: i32) @This() {
    var chunk: @This() = .{
        .data = undefined,
        .min_x = min_x - offset,
        .min_z = min_z - offset,
    };
    for (0..size) |rel_x| {
        for (0..size) |rel_z| {
            const abs_x: i32 = min_x - offset + @as(i32, @intCast(rel_x));
            const abs_z: i32 = min_z - offset + @as(i32, @intCast(rel_z));

            chunk.data[rel_x * size + rel_z] = .{
                .slime = @intFromBool(scalar.isSlime(world_seed, abs_x, abs_z)),
                .strip_count = 0,
            };
        }
    }
    return chunk;
}

/// Initialize chunks with simd routine
pub fn initSimd(world_seed: i64, min_x: i32, min_z: i32) @This() {
    const lanes = simd.lanes;
    comptime std.debug.assert(@mod(size, lanes) == 0);

    var chunk: @This() = .{
        .data = undefined,
        .min_x = min_x - offset,
        .min_z = min_z - offset,
    };
    for (0..size) |rel_x| {
        for (0..size / lanes) |j| {
            const rel_z = j * lanes;
            const abs_x: i32 = min_x - offset + @as(i32, @intCast(rel_x));
            const abs_z: i32 = min_z - offset + @as(i32, @intCast(rel_z));
            const slime = simd.areSlime(world_seed, abs_x, abs_z);
            for (0..lanes) |z_offset| {
                chunk.data[rel_x * size + rel_z + z_offset] = .{
                    .slime = @intFromBool(slime[z_offset]),
                    .strip_count = 0,
                };
            }
        }
    }
    return chunk;
}

/// For each chunk (x, z), outputs the amount of slime chunks in (x, z - 7)..[x, z]
/// to a separate buffer
pub fn preprocess(self: *@This()) void {
    const chunk_len = 7;
    comptime std.debug.assert(size >= chunk_len);
    for (0..size) |x| {
        for (x * size..x * size + size - chunk_len + 1) |i| {
            var count: u8 = 0;
            for (0..chunk_len) |j| count += @bitCast(self.data[i + j]);
            count &= 0xf;
            self.data[i].strip_count = @intCast(count);
        }
    }
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

const Coord = struct { x: usize, z: usize };

/// add preprocessed value to count
const use_preprocessed = blk: {
    var buf: [30]Coord = undefined;
    var coords = std.ArrayListUnmanaged(Coord).initBuffer(&buf);
    for (mask, 0..) |row, x| {
        for (row, 0..) |char, z| {
            if (char == '+' or char == '-') coords.appendAssumeCapacity(.{ .x = x, .z = z });
        }
    }
    const coords_final = coords.items[0..coords.items.len];
    break :blk coords_final.*;
};

/// add slime value of cell to count
const add = blk: {
    var buf: [30]Coord = undefined;
    var coords = std.ArrayListUnmanaged(Coord).initBuffer(&buf);
    for (mask, 0..) |row, x| {
        for (row, 0..) |char, z| {
            if (char == 'o') coords.appendAssumeCapacity(.{ .x = x, .z = z });
        }
    }
    const coords_final = coords.items[0..coords.items.len];
    break :blk coords_final.*;
};

/// subtract binary value of cell from count
const sub = blk: {
    var buf: [30]Coord = undefined;
    var coords = std.ArrayListUnmanaged(Coord).initBuffer(&buf);
    for (mask, 0..) |row, x| {
        for (row, 0..) |char, z| {
            if (char == '-') coords.appendAssumeCapacity(.{ .x = x, .z = z });
        }
    }
    const coords_final = coords.items[0..coords.items.len];
    break :blk coords_final.*;
};

/// For every chunk within the searched area defined by this `SearchBlock`
/// checks whether the amount of slime chunk slime chunks in spawn range of a player
/// at the center of each chunk meets the given `threshold`
pub fn calculateSliminess(
    self: *@This(),
    params: slimy.SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
) usize {
    var sufficiently_slimy_chunks: usize = 0;
    for (0..size - mask.len + 1) |x| {
        for (0..size - mask.len + 1) |z| {
            var count: u8 = 0;

            // The .strip_count field is stored in the upper 4 bits of the Cell struct.
            // The other field is .slime, which is u4 for padding purposes but is actually stores bool.
            // To access .strip_count, zig/llvm shifts the backing int of Cell (u8) left: >> 4.
            // However, since .slime is guaranteed to be 0 or 1, we can just directly add the backing
            // ints together up to 15 times before overflow occurs and shift >> 4 at the end.
            // Since use_preprocessed contains more than 15 elements, we split it into two sub-arrays.
            // This optimization saves 24 (26 - 2) right shifts, and combined with similar optimizations for
            // add_count and sub_count, speeds up the function by over 80%.
            // I tried signalling to LLVM that the padding bits are always 0 with asserts,
            // but it was unable to perform the optimization. I discussed it with qwerasd in the Zig discord
            // and they said, after experimentation, "it seems like it does not have any concept of 'the lower
            // bits will never overflow in to this area, so we don't need to pre-shift'".

            var preprocessed_count_1: u16 = 0;
            for (use_preprocessed[0..15]) |location| {
                preprocessed_count_1 += @as(u8, @bitCast(self.data[x * size + z + location.x * size + location.z]));
            }
            var preprocessed_count_2: u16 = 0;
            for (use_preprocessed[15..]) |location| {
                preprocessed_count_2 += @as(u8, @bitCast(self.data[x * size + z + location.x * size + location.z]));
            }
            count += @intCast((preprocessed_count_1 >> 4) + (preprocessed_count_2 >> 4));

            var add_count: u16 = 0;
            for (add) |location| add_count += @as(u8, @bitCast(self.data[x * size + z + location.x * size + location.z]));
            count += @intCast(add_count & 0xf);

            var sub_count: u16 = 0;
            for (sub) |location| sub_count += @as(u8, @bitCast(self.data[x * size + z + location.x * size + location.z]));
            count -= @intCast(sub_count & 0xf);

            if (count >= params.threshold) {
                sufficiently_slimy_chunks += 1;
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
    return sufficiently_slimy_chunks;
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

pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    const width, const height = comptime blk: {
        if (fmt.len == 0) break :blk .{ 32, 32 };
        if (fmt[0] != '[' or fmt[fmt.len - 1] != ']') @compileError("format for ProcessingChunk must be surrounded with brackets");

        var parts = std.mem.splitScalar(u8, fmt[1 .. fmt.len - 1], 'x');
        const width = std.fmt.parseInt(
            usize,
            parts.next() orelse @compileError("bad format string for ProcessingChunk"),
            10,
        ) catch @compileError("bad format string for ProcessingChunk");
        const height = std.fmt.parseInt(
            usize,
            parts.next() orelse @compileError("bad format string for ProcessingChunk"),
            10,
        ) catch @compileError("bad format string for ProcessingChunk");

        break :blk .{ width, height };
    };
    for (0..width) |x| {
        for (0..height) |z| {
            try writer.print("{c} ", .{@as(u8, if (self.data[z * size + x].slime == 1) 254 else '.')});
        }
        try writer.print("\n", .{});
    }
    _ = options;
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
    const chunk = initScalar(0x51133, offset, offset);

    const block = @import("test_data.zig").block;
    for (block, 0..) |row, z| {
        for (row, 0..) |c, x| {
            try std.testing.expectEqual(c == 'O', chunk.data[x * size + z].slime == 1);
        }
    }
}

test initSimd {
    const chunk = initSimd(0x51133, offset, offset);

    const block = @import("test_data.zig").block;
    for (block, 0..) |row, z| {
        for (row, 0..) |c, x| {
            try std.testing.expectEqual(c == 'O', chunk.data[x * size + z].slime == 1);
        }
    }
}

test "initSimd and initScalar parity" {
    try std.testing.expectEqualSlices(
        Cell,
        &initScalar(0x51133, 0xbeef, -0x51133135).data,
        &initSimd(0x51133, 0xbeef, -0x51133135).data,
    );
}

test preprocess {
    if (true) return error.SkipZigTest;

    var chunk = initSimd(0x51133, offset, offset);
    chunk.preprocess();
    for (0..size) |x| {
        for (0..size) |z| {
            std.debug.print("{: ^3}", .{chunk.data[x * size + z].strip_count});
        }
        std.debug.print("\n", .{});
    }
}

test format {
    if (true) return error.SkipZigTest;
    const chunk = initScalar(0x51133, offset, offset);
    std.debug.print("{0[32x32]}", .{chunk});
}

test calculateSliminess {
    var results = std.ArrayList(slimy.Result).init(std.testing.allocator);
    defer results.deinit();

    var chunk = initSimd(0x51133, 0, 0);
    chunk.preprocess();
    _ = chunk.calculateSliminess(
        .{ .x0 = 0, .x1 = size, .z0 = 0, .z1 = size, .method = undefined, .threshold = 0, .world_seed = 0x51133 },
        &results,
        reportResultTest,
    );
    try std.testing.expectEqual(tested_size * tested_size, results.items.len);
    for (results.items) |result| {
        try std.testing.expectEqual(calculateSliminessForLocation(0x51133, result.x, result.z), result.count);
    }
}

pub fn reportResultTest(context: *std.ArrayList(slimy.Result), result: slimy.Result) void {
    context.append(result) catch {};
}
