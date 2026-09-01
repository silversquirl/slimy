const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const slimy = @import("slimy.zig");
const SearchBlock = @import("cpu/SearchBlock.zig");

pub fn search(
    params: slimy.SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
    comptime progressCallback: ?fn (@TypeOf(context), completed: u64, total: u64) void,
) !void {
    std.debug.assert(params.method == .cpu);
    std.debug.assert(params.method.cpu > 0);
    if (params.method.cpu == 1) {
        try searchSinglethread(params, context, resultCallback, progressCallback);
    } else if (builtin.single_threaded) {
        unreachable;
    } else {
        try searchMultithread(params, context, resultCallback, progressCallback);
    }
}

pub fn searchSinglethread(
    params: slimy.SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
    comptime maybeProgressCallback: ?fn (@TypeOf(context), completed: u64, total: u64) void,
) !void {
    std.debug.assert(params.method == .cpu);
    std.debug.assert(params.method.cpu == 1);
    std.debug.assert(params.x0 < params.x1);
    std.debug.assert(params.z0 < params.z1);
    chunks_searched = .init(0);

    try worker(params, context, resultCallback, maybeProgressCallback, 0, 1);
}

var chunks_searched: std.atomic.Value(usize) = .init(0);

pub fn searchMultithread(
    params: slimy.SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
    comptime progressCallback: ?fn (@TypeOf(context), completed: u64, total: u64) void,
) !void {
    std.debug.assert(params.method == .cpu);
    std.debug.assert(params.method.cpu > 1);
    std.debug.assert(params.x0 < params.x1);
    std.debug.assert(params.z0 < params.z1);

    // Reset chunk search counter
    chunks_searched = .init(0);

    var threads: [std.math.maxInt(@TypeOf(params.method.cpu)) + 1]std.Thread = undefined;
    const thread_count = params.method.cpu;
    for (threads[0..thread_count], 0..) |*thread, thread_index| {
        thread.* = try .spawn(
            .{},
            worker,
            .{
                params,
                context,
                resultCallback,
                progressCallback,
                thread_index,
                thread_count,
            },
        );
        std.log.scoped(.thread).debug("spawned thread {}", .{thread_index});
    }
    std.Thread.yield() catch {};
    for (threads[0..thread_count]) |thread| {
        thread.join();
    }
}

pub fn worker(
    params: slimy.SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
    comptime maybeProgressCallback: ?fn (@TypeOf(context), completed: u64, total: u64) void,
    thread_id: usize,
    thread_count: usize,
) !void {
    _ = &resultCallback;
    _ = &maybeProgressCallback;
    std.log.scoped(.thread).debug("thread {} entered", .{thread_id});
    const block_size = SearchBlock.tested_size;

    const blocks_x = std.math.divCeil(usize, @intCast(params.x1 - params.x0), block_size) catch unreachable;
    const blocks_z = std.math.divCeil(usize, @intCast(params.z1 - params.z0), block_size) catch unreachable;

    // split blocks as evenly as possible
    const start_block = blocks_x * blocks_z * thread_id / thread_count;
    const end_block = blocks_x * blocks_z * (thread_id + 1) / thread_count;

    var blocks_completed: usize = 0;
    for (start_block..end_block) |block_index| {
        const block_x = block_index / blocks_x;
        const block_z = @mod(block_index, blocks_x);

        var chunk: SearchBlock = undefined;
        chunk.initSimd(
            params.world_seed,
            params.x0 + @as(i32, @intCast(block_x * block_size)),
            params.z0 + @as(i32, @intCast(block_z * block_size)),
        );
        // chunk.preprocess();
        // chunk.calculateSliminess(params, context, resultCallback);

        std.mem.doNotOptimizeAway(&chunk);

        blocks_completed += 1;

        // avoid contention; don't update every block
        // only first thread performs callback to avoid overhead
        if (blocks_completed >= 100) {
            _ = chunks_searched.fetchAdd(blocks_completed * block_size * block_size, .monotonic);
            if (thread_id == 0) {
                if (maybeProgressCallback) |progressCallback| {
                    progressCallback(context, chunks_searched.raw, blocks_x * blocks_z * block_size * block_size);
                }
            }
        }
    }

    _ = chunks_searched.fetchAdd(blocks_completed, .monotonic);
    // TODO: implement work stealing
    std.log.scoped(.thread).debug("thread {} finished", .{thread_id});
}
