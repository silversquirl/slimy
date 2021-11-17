const std = @import("std");
const common = @import("common.zig");
const slimy = @import("slimy.zig");
const zc = @import("zcompute");

pub fn search(
    params: slimy.SearchParams,
    callback_context: anytype,
    comptime resultCallback: fn (@TypeOf(callback_context), slimy.Result) void,
    comptime progressCallback: ?fn (@TypeOf(callback_context), completed: u64, total: u64) void,
) !void {
    var ctx = zc.Context.init(std.heap.c_allocator, .{}) catch return error.VulkanInit;
    defer ctx.deinit();

    var shad = zc.Shader(&.{
        zc.pushConstant("params", 0, GpuParams),
        zc.storageBuffer("result_count", 0, zc.Buffer(u32)),
        zc.storageBuffer("results", 1, zc.Buffer(slimy.Result)),
    }).initBytes(&ctx, @embedFile("shader/search.spv")) catch return error.ShaderInit;
    defer shad.deinit();

    // Result buffers - two of these so we can double-buffer
    var results: [2]ResultBuffers = undefined;
    results[0] = ResultBuffers.init(&ctx) catch return error.BufferInit;
    defer results[0].deinit();
    results[1] = ResultBuffers.init(&ctx) catch return error.BufferInit;
    defer results[1].deinit();

    var buf_idx: u1 = 0;

    const useed = @bitCast(u64, params.world_seed);
    const gpu_params = GpuParams{
        .world_seed = .{
            @intCast(u32, useed >> 32),
            @truncate(u32, useed),
        },
        .offset = .{ params.x0, params.z0 },
        .threshold = params.threshold,
    };

    const search_size = [2]u32{
        @intCast(u32, @as(i33, params.x1) - params.x0),
        @intCast(u32, @as(i33, params.z1) - params.z0),
    };
    var z: u32 = 0;
    while (z < search_size[1]) : (z += batch_size[1]) {
        const batch_z = @minimum(search_size[1] - z, batch_size[1]);

        var x: u32 = 0;
        while (x < search_size[0]) : (x += batch_size[0]) {
            const batch_x = @minimum(search_size[0] - x, batch_size[0]);

            if (progressCallback) |cb| {
                const chunk_index = x + z * search_size[0];
                cb(callback_context, chunk_index, search_size[0] * search_size[1]);
            }

            shad.exec(std.time.ns_per_s, .{
                .x = batch_x,
                .y = batch_z,
                .baseX = x,
                .baseY = z,
            }, .{
                .params = gpu_params,
                .result_count = results[buf_idx].count,
                .results = results[buf_idx].results,
            }) catch |err| switch (err) {
                error.Timeout => return error.Timeout,
                else => return error.ShaderExec,
            };
            buf_idx ^= 1;

            if (x != 0 or z != 0) {
                try results[buf_idx].report(callback_context, resultCallback);
            }
        }
    }

    if (!(shad.waitTimeout(std.time.ns_per_s) catch return error.ShaderExec)) {
        return error.Timeout;
    }
    buf_idx ^= 1;
    try results[buf_idx].report(callback_context, resultCallback);
}

const ResultBuffers = struct {
    count: zc.Buffer(u32),
    results: zc.Buffer(slimy.Result),

    fn init(ctx: *zc.Context) !ResultBuffers {
        const count = try zc.Buffer(u32).init(ctx, 1, .{ .map = true, .storage = true });
        errdefer count.deinit();
        (try count.map())[0] = 0;
        count.unmap();

        const results = try zc.Buffer(slimy.Result).init(ctx, batch_size[0] * batch_size[1], .{
            .map = true,
            .storage = true,
        });
        errdefer results.deinit();

        return ResultBuffers{ .count = count, .results = results };
    }

    fn deinit(self: ResultBuffers) void {
        self.results.deinit();
        self.count.deinit();
    }

    fn report(
        self: ResultBuffers,
        callback_context: anytype,
        comptime resultCallback: fn (@TypeOf(callback_context), slimy.Result) void,
    ) !void {
        const count_mem = self.count.map() catch return error.MemoryMapFailed;
        const count = count_mem[0];
        count_mem[0] = 0;
        self.count.unmap();

        const result_mem = self.results.map() catch return error.MemoryMapFailed;
        for (result_mem[0..count]) |res| {
            resultCallback(callback_context, res);
        }
        self.results.unmap();
    }
};

const batch_size = [2]u32{ 1024, 1024 };

const GpuParams = extern struct {
    world_seed: [2]u32,
    offset: [2]i32,
    threshold: i32,
};
