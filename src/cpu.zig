const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const slimy = @import("slimy.zig");
const search_exact = @import("cpu/search_exact.zig");
const search_early_out = @import("cpu/search_early_out.zig");

var chunks_searched: std.atomic.Value(usize) = .init(0);

pub fn search(
    params: slimy.SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
    comptime progressCallback: ?fn (@TypeOf(context), completed: u64, total: u64) void,
    thread_count: u8,
) std.Thread.SpawnError!void {
    std.debug.assert(thread_count > 0);
    if (thread_count == 1) {
        searchSinglethread(params, context, resultCallback, progressCallback);
    } else if (builtin.single_threaded) {
        unreachable;
    } else {
        try searchMultithread(params, context, resultCallback, progressCallback, thread_count);
    }
}

const SearchStrategy = enum { exact, early_out };

pub fn searchSinglethread(
    params: slimy.SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
    comptime maybeProgressCallback: ?fn (@TypeOf(context), completed: u64, total: u64) void,
) void {
    std.debug.assert(params.x0 < params.x1);
    std.debug.assert(params.z0 < params.z1);

    const search_strategy: SearchStrategy = if (params.threshold <= 45) .exact else .early_out;

    worker(params, context, resultCallback, maybeProgressCallback, search_strategy, 0, 1);
}

pub fn searchMultithread(
    params: slimy.SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
    comptime progressCallback: ?fn (@TypeOf(context), completed: u64, total: u64) void,
    thread_count: u8,
) !void {
    std.debug.assert(params.x0 < params.x1);
    std.debug.assert(params.z0 < params.z1);

    const search_strategy: SearchStrategy = if (params.threshold <= 45) .exact else .early_out;

    chunks_searched = .init(0);

    var threads: [std.math.maxInt(@TypeOf(thread_count)) + 1]std.Thread = undefined;
    for (threads[0..thread_count], 0..) |*thread, thread_index| {
        thread.* = try .spawn(.{}, worker, .{
            params,
            context,
            resultCallback,
            progressCallback,
            search_strategy,
            thread_index,
            thread_count,
        });
        std.log.scoped(.thread).debug("spawned thread {}", .{thread_index});
    }
    for (threads[0..thread_count], 0..) |thread, thread_index| {
        thread.join();
        std.log.scoped(.thread).debug("thread {} finished", .{thread_index});
    }
}

pub fn worker(
    params: slimy.SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
    comptime maybeProgressCallback: ?fn (@TypeOf(context), completed: u64, total: u64) void,
    search_strategy: SearchStrategy,
    thread_index: usize,
    thread_count: usize,
) void {
    std.log.scoped(.thread).debug("thread {} entered", .{thread_index});
    const block_size: usize = if (search_strategy == .exact) search_exact.tested_size else search_early_out.tested_size;

    const blocks_w = std.math.divCeil(usize, @intCast(params.x1 - params.x0), block_size) catch unreachable;
    const blocks_h = std.math.divCeil(usize, @intCast(params.z1 - params.z0), block_size) catch unreachable;

    // split blocks as evenly as possible
    const start_block = blocks_w * blocks_h * thread_index / thread_count;
    const end_block = blocks_w * blocks_h * (thread_index + 1) / thread_count;

    var blocks_completed: usize = 0;
    for (start_block..end_block) |block_index| {
        const block_x = block_index / blocks_w;
        const block_z = @mod(block_index, blocks_w);

        if (search_strategy == .exact) {
            var block_data: [256][256]u8 align(64) = search_exact.computeSlime(
                params.world_seed,
                params.x0 + @as(i32, @intCast(block_x * block_size)) - search_exact.half_kernel_width,
                params.z0 + @as(i32, @intCast(block_z * block_size)) - search_exact.half_kernel_width,
            );
            search_exact.computeColumns(&block_data);
            search_exact.computeKernel(
                &block_data,
                params.x0 + @as(i32, @intCast(block_x * block_size)) - search_exact.half_kernel_width,
                params.z0 + @as(i32, @intCast(block_z * block_size)) - search_exact.half_kernel_width,
                params,
                context,
                resultCallback,
            );
        } else {
            const slime: [256]u256 align(64) = search_early_out.computeSlime(
                params.world_seed,
                params.x0 + @as(i32, @intCast(block_x * block_size)) - search_early_out.half_kernel_width,
                params.z0 + @as(i32, @intCast(block_z * block_size)) - search_early_out.half_kernel_width,
            );

            var runs: [256][256]u8 align(64) = undefined;
            search_early_out.computeColumnsPacked(@ptrCast(&slime), &runs);

            var runs_transpose: [256][256]u8 align(64) = undefined;
            search_early_out.transpose(&runs, &runs_transpose);

            var complete_kernel: [256][256]u8 align(64) = @splat(@splat(0));
            search_early_out.computeColumns(&runs_transpose, &complete_kernel);

            search_early_out.search(
                &complete_kernel,
                params.x0 + @as(i32, @intCast(block_x * block_size)) - search_early_out.half_kernel_width,
                params.z0 + @as(i32, @intCast(block_z * block_size)) - search_early_out.half_kernel_width,
                params,
                context,
                resultCallback,
            );
        }
        blocks_completed += 1;

        // avoid contention, don't update every block
        // only first thread performs callback to avoid overhead
        if (blocks_completed >= 1000) {
            _ = chunks_searched.fetchAdd(blocks_completed * block_size * block_size, .monotonic);
            if (thread_index == 0) {
                if (maybeProgressCallback) |progressCallback| {
                    progressCallback(context, chunks_searched.raw, blocks_w * blocks_h * block_size * block_size);
                }
            }
            blocks_completed = 0;
        }
    }

    // Add remaining blocks
    _ = chunks_searched.fetchAdd(blocks_completed, .monotonic);

    // TODO: implement work stealing
    std.log.scoped(.thread).debug("thread {} finished", .{thread_index});
}
