const std = @import("std");
const builtin = @import("builtin");
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
    seed = (seed *% magic +% 0xB) & mask;
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
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
    comptime progressCallback: ?fn (@TypeOf(context), completed: u64, total: u64) void,
) !void {
    try Searcher(struct {
        ctx: @TypeOf(context),

        const Self = @This();

        pub fn reportResult(self: Self, result: slimy.Result) void {
            resultCallback(self.ctx, result);
        }
        pub fn reportProgress(self: Self, completed: u64, total: u64) void {
            if (progressCallback) |callback| {
                callback(self.ctx, completed, total);
            }
        }
    }).init(params, .{ .ctx = context }).search();
}

// Context should have the following functions:
//  pub fn reportResult(self: Context, result: slimy.Result) void;
//  pub fn reportProgress(self: Context, completed: u64, total: u64) void;
pub fn Searcher(comptime Context: type) type {
    return struct {
        world_seed: i64,
        threshold: u32,

        x0: i32,
        z0: i32,
        x1: i32,
        z1: i32,

        threads: u8,
        ctx: Context,

        const Self = @This();

        pub fn init(params: slimy.SearchParams, context: Context) Self {
            std.debug.assert(params.method.cpu > 0);
            return .{
                .world_seed = params.world_seed,
                .threshold = params.threshold,

                .x0 = params.x0,
                .x1 = params.x1,
                .z0 = params.z0,
                .z1 = params.z1,

                .threads = params.method.cpu,
                .ctx = context,
            };
        }

        pub fn search(self: Self) !void {
            if (self.threads == 1) {
                self.searchSinglethread();
            } else if (builtin.single_threaded) {
                unreachable;
            } else {
                try self.searchMultithread();
            }
        }

        pub fn searchSinglethread(self: Self) void {
            const total_chunks = @intCast(u64, self.x1 - self.x0) * @intCast(u64, self.z1 - self.z0);
            var completed_chunks: u64 = 0;
            const step = 100;

            var z0 = self.z0;
            while (z0 < self.z1) : (z0 += step) {
                const z1 = std.math.min(z0 + step, self.z1);

                var x0 = self.x0;
                while (x0 < self.x1) : (x0 += step) {
                    const x1 = std.math.min(x0 + step, self.x1);
                    self.searchArea(x0, x1, z0, z1);
                    completed_chunks += @intCast(u64, x1 - x0) * @intCast(u64, z1 - z0);

                    self.ctx.reportProgress(completed_chunks, total_chunks);
                }
            }
        }

        pub fn searchMultithread(
            self: Self,
        ) !void {
            var i: u8 = 0;
            var thr: ?std.Thread = null;
            while (i < self.threads) : (i += 1) {
                thr = try std.Thread.spawn(.{}, searchWorker, .{ self, i, thr });
            }
            thr.?.join();
        }
        fn searchWorker(self: Self, thread_idx: u8, prev_thread: ?std.Thread) void {
            // TODO: work stealing

            const thread_width = @intCast(u31, self.z1 - self.z0) / self.threads;
            const z0 = self.z0 + thread_idx * thread_width;
            const z1 = if (thread_idx == self.threads - 1)
                self.z1 // Last thread, consume all remaining area
            else
                z0 + thread_width;

            // TODO: progress reporting
            self.searchArea(self.x0, self.x1, z0, z1);

            // This creates a linked list of threads, so we can just join the last one from the main thread
            if (prev_thread) |thr| thr.join();
        }

        // TODO: cache isSlime results
        fn searchArea(
            self: Self,
            x0: i32,
            x1: i32,
            z0: i32,
            z1: i32,
        ) void {
            var z = z0;
            while (z < z1) : (z += 1) {
                var x = x0;
                while (x < x1) : (x += 1) {
                    const count = checkLocation(self.world_seed, x, z);
                    if (count >= self.threshold) {
                        self.ctx.reportResult(.{
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
