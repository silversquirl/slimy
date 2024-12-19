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
        searchSinglethread(params, context, resultCallback, progressCallback);
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
    comptime progressCallback: ?fn (@TypeOf(context), completed: u64, total: u64) void,
) void {
    std.debug.assert(params.method == .cpu);
    std.debug.assert(params.method.cpu == 1);
    std.debug.assert(params.x0 < params.x1);
    std.debug.assert(params.z0 < params.z1);
    const block_size = SearchBlock.tested_size;

    var completed_chunks: usize = 0;
    const width: u64 = @intCast(params.x1 - params.x0);
    const height: u64 = @intCast(params.z1 - params.z0);
    const total_chunks = width * height;

    var x = params.x0;
    while (x < params.x1) : (x += block_size) {
        var z = params.z0;
        while (z < params.z1) : (z += block_size) {
            var block = SearchBlock.initSimd(params.world_seed, x, z);
            block.preprocess();
            _ = block.calculateSliminess(params, context, resultCallback);
            completed_chunks += block_size * block_size;
            (progressCallback orelse continue)(context, completed_chunks, total_chunks);
        }
    }
}

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
    chunks_searched = std.atomic.Value(usize).init(0);

    var threads = std.BoundedArray(std.Thread, 255).init(0) catch unreachable;
    const thread_count = params.method.cpu;
    for (0..thread_count) |thread_index| {
        threads.append(try std.Thread.spawn(
            .{ .stack_size = 64 * 1024 },
            worker,
            .{
                params,
                context,
                resultCallback,
                progressCallback,
                thread_index,
                thread_count,
            },
        )) catch unreachable;
    }
    std.Thread.yield() catch {};
    for (threads.slice()) |thread| {
        thread.join();
    }
}

pub fn worker(
    params: slimy.SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
    comptime progressCallback: ?fn (@TypeOf(context), completed: u64, total: u64) void,
    thread_id: usize,
    thread_count: usize,
) !void {
    const block_size = SearchBlock.tested_size;

    const blocks_x = try std.math.divCeil(usize, @intCast(params.x1 - params.x0), block_size);
    const blocks_z = try std.math.divCeil(usize, @intCast(params.z1 - params.z0), block_size);

    // split blocks as evenly as possible
    const start_block = blocks_x * blocks_z * thread_id / thread_count;
    const end_block = blocks_x * blocks_z * (thread_id + 1) / thread_count;

    var i: usize = 0;
    for (start_block..end_block) |block_index| {
        const rel_block_x = block_index / blocks_x;
        const rel_block_z = @mod(block_index, blocks_x);
        var chunk = SearchBlock.initSimd(params.world_seed, params.x0 + @as(i32, @intCast(rel_block_x * block_size)), params.z0 + @as(i32, @intCast(rel_block_z * block_size)));
        chunk.preprocess();
        _ = chunk.calculateSliminess(params, context, resultCallback);
        i += 1;
        if (i == 20) {
            _ = chunks_searched.fetchAdd(i, .monotonic);
            i = 0;
            if (thread_id == 0 and progressCallback != null) {
                progressCallback.?(context, chunks_searched.raw, blocks_x * blocks_z);
            }
        }
    }
    _ = chunks_searched.fetchAdd(i, .monotonic);
}

var chunks_searched = std.atomic.Value(usize).init(0);
