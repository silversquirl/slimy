const std = @import("std");
const slimy = @import("slimy.zig");
const SearchBlock = @import("cpu/SearchBlock.zig");

export fn searchInit(
    world_seed: i64,
    threshold: u8,
    x0: i32,
    x1: i32,
    z0: i32,
    z1: i32,
    worker_id: u8,
    worker_count: u8,
) void {
    searcher = AsyncSearcher.init(
        .{
            .world_seed = world_seed,
            .threshold = threshold,
            .x0 = x0,
            .x1 = x1,
            .z0 = z0,
            .z1 = z1,
            .method = .{ .cpu = 1 },
        },
        worker_id,
        worker_count,
    );
}

export fn searchStep() bool {
    return searcher.step();
}

export fn searchProgress() f64 {
    const current: f64 = @floatFromInt(searcher.end_block - searcher.current_block);
    const total: f64 = @floatFromInt(searcher.end_block - searcher.start_block);
    return 1 - current / total;
}

var searcher: AsyncSearcher = undefined;

const AsyncSearcher = struct {
    params: slimy.SearchParams,
    worker_id: u8,
    worker_count: u8,
    current_block: usize,
    start_block: usize,
    end_block: usize,
    blocks_x: usize,
    pub fn init(
        params: slimy.SearchParams,
        worker_id: u8,
        worker_count: u8,
    ) AsyncSearcher {
        const block_size = SearchBlock.tested_size;

        const blocks_x = std.math.divCeil(usize, @intCast(params.x1 - params.x0), block_size) catch |e| {
            debugLog("error {}", .{e});
            @panic("bad");
        };
        const blocks_z = std.math.divCeil(usize, @intCast(params.z1 - params.z0), block_size) catch |e| {
            debugLog("error {}", .{e});
            @panic("bad");
        };

        const start_block = blocks_x * blocks_z * worker_id / worker_count;
        const end_block = blocks_x * blocks_z * (worker_id + 1) / worker_count;

        return .{
            .params = params,
            .worker_id = worker_id,
            .worker_count = worker_count,
            .current_block = start_block,
            .start_block = start_block,
            .end_block = end_block,
            .blocks_x = blocks_x,
        };
    }

    /// Search 10 blocks, then yield to event loop
    /// Returns true when done
    fn step(self: *AsyncSearcher) bool {
        const params = self.params;
        const block_size = SearchBlock.tested_size;

        // debugLog("searching blocks {} - {}", .{ self.start_block, @min(self.start_block + 10, self.end_block) });
        for (self.current_block..@min(self.current_block + 10, self.end_block)) |block_index| {
            const rel_block_x = block_index / self.blocks_x;
            const rel_block_z = @mod(block_index, self.blocks_x);

            var chunk = SearchBlock.initSimd(params.world_seed, params.x0 + @as(i32, @intCast(rel_block_x * block_size)), params.z0 + @as(i32, @intCast(rel_block_z * block_size)));
            chunk.preprocess();
            _ = chunk.calculateSliminess(params, void{}, reportResult);
        }
        self.current_block += 10;
        return self.current_block >= self.end_block;
    }

    pub fn reportResult(_: void, res: slimy.Result) void {
        resultCallback(res.x, res.z, res.count);
    }

    pub fn reportProgress(self: *AsyncSearcher, completed: u64, total: u64) void {
        const resolution = 10_000;
        const progress = resolution * completed / total;
        const fraction = @as(f64, @floatFromInt(progress)) / resolution;
        self.progress = fraction;
    }
};

extern "slimy" fn resultCallback(x: i32, z: i32, count: u32) void;

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, fmt, args) catch return;
    consoleLog(str.ptr, str.len);
}

extern "slimy" fn consoleLog(ptr: [*]const u8, len: usize) void;

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    _ = ret_addr;
    debugLog("{s}", .{msg});
    unreachable;
}
