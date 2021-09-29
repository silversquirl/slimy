const std = @import("std");
const slimy = @import("slimy.zig");

// Search mask; row-major; bottom-left origin
const mask_bitmap = blk: {
    const inner = 1;
    const outer = 8;

    const dim = 2 * outer + 1;
    var bitmap: [dim][dim]bool = undefined;
    for (bitmap) |*row, y| {
        for (row) |*bit, x| {
            const rx = @intCast(i32, x) - outer;
            const ry = @intCast(i32, y) - outer;
            const d2 = rx * rx + ry * ry;
            bit.* =
                // Outside inner circle
                inner * inner < d2 and
                // Inside outer circle
                d2 <= outer * outer;
        }
    }

    break :blk bitmap;
};
const mask_width = mask_bitmap[0].len;
const mask_height = mask_bitmap.len;

fn isSlime(world_seed: i64, x: i32, z: i32) bool {
    @setRuntimeSafety(false);

    // Init slime seed
    var seed = world_seed +%
        @as(i64, x * x *% 4987142) +
        @as(i64, x *% 5947611) +
        @as(i64, z * z) * 4392871 +
        @as(i64, z *% 389711);
    seed ^= 987234911;

    // Init LCG seed
    const magic = 0x5DEECE66D;
    const mask = (1 << 48) - 1;
    seed = (seed ^ magic) & mask;

    // Calculate random result
    seed = (seed *% magic + 0xB) & mask;
    const bits = @intCast(i32, seed >> 48 - 31);
    const val = @mod(bits, 10);

    std.debug.assert(bits >= val - 9);
    return val == 0;
}

test "isSlime" {
    const expected = [10][10]u1{
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 1, 0, 0, 0, 0 },
        .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 1, 0, 0, 0, 0, 0, 1 },
        .{ 0, 0, 0, 0, 0, 1, 0, 0, 0, 0 },
        .{ 0, 1, 0, 0, 1, 0, 0, 1, 0, 0 },
        .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
    };

    for (expected) |row, y| {
        for (row) |e, x| {
            try std.testing.expectEqual(
                e != 0,
                isSlime(1, @intCast(i32, x), @intCast(i32, y)),
            );
        }
    }
}
test "isSlime with Z 23" {
    try std.testing.expect(!isSlime(1, -1, 23));
}

fn checkLocation(world_seed: i64, cx: i32, cz: i32) u32 {
    @setRuntimeSafety(false);

    var count: u32 = 0;
    for (mask_bitmap) |row, mz| {
        for (row) |bit, mx| {
            const x = @intCast(i32, mx) + cx - row.len / 2;
            const z = @intCast(i32, mz) + cz - mask_bitmap.len / 2;
            count += @boolToInt(bit and isSlime(world_seed, x, z));
        }
    }
    return count;
}

pub fn search(
    params: slimy.SearchParams,
    context: anytype,
    comptime callback: fn (@TypeOf(context), slimy.Result) void,
) !void {
    const searcher = Searcher(.{
        .Context = @TypeOf(context),
        .resultCallback = callback,
        .Thread = std.Thread,
        .spawn = std.Thread.spawn,
    }).init(params, context);
    try searcher.search();
}

pub const SearchConfig = struct {
    Context: type,
    resultCallback: anytype, // fn (Context, slimy.Result) void
    Thread: type,
    spawn: anytype, // fn (std.Thread.SpawnConfig, comptime anytype, anytype) !Thread
};

pub fn Searcher(comptime config: SearchConfig) type {
    return struct {
        world_seed: i64,
        range: u31,
        threshold: u32,
        threads: u8,
        ctx: config.Context,

        const Self = @This();

        pub fn init(params: slimy.SearchParams, context: config.Context) Self {
            std.debug.assert(params.method.cpu > 0);
            return .{
                .world_seed = params.world_seed,
                .range = params.range,
                .threshold = params.threshold,
                .threads = params.method.cpu,
                .ctx = context,
            };
        }

        pub fn search(self: Self) !void {
            if (self.threads == 1) {
                self.searchSinglethread();
            } else if (std.builtin.single_threaded) {
                unreachable;
            } else {
                try self.searchMultithread();
            }
        }

        pub fn searchSinglethread(self: Self) void {
            self.searchArea(
                -@as(i32, self.range),
                self.range,
                -@as(i32, self.range),
                self.range,
            );
        }

        pub fn searchMultithread(
            self: Self,
        ) !void {
            var i: u8 = 0;
            var thr: ?config.Thread = null;
            while (i < self.threads) : (i += 1) {
                thr = try config.spawn(.{}, searchWorker, .{ self, i, thr });
            }
            thr.?.join();
        }
        fn searchWorker(self: Self, thread_idx: u8, prev_thread: ?std.Thread) void {
            // TODO: work stealing

            const thread_width = self.range * 2 / self.threads;
            const start_z = thread_idx * thread_width - @as(i32, self.range);
            const end_z = if (thread_idx == self.threads - 1)
                self.range // Last thread, consume all remaining area
            else
                start_z + thread_width;

            self.searchArea(
                start_z,
                end_z,
                -@as(i32, self.range),
                self.range,
            );

            // This creates a linked list of threads, so we can just join the last one from the main thread
            if (prev_thread) |thr| thr.join();
        }

        fn searchArea(
            self: Self,
            start_z: i32,
            end_z: i32,
            start_x: i32,
            end_x: i32,
        ) void {
            var z = start_z;
            while (z < end_z) : (z += 1) {
                var x = start_x;
                while (x < end_x) : (x += 1) {
                    const count = checkLocation(self.world_seed, x, z);
                    if (count >= self.threshold) {
                        config.resultCallback(self.ctx, .{
                            .x = x,
                            .z = z,
                            .count = count,
                        });
                    }
                }
            }
        }
    };
}
