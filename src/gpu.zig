const std = @import("std");
const common = @import("common.zig");
const slimy = @import("slimy.zig");
const zc = @import("zcompute");
const log = std.log.scoped(.gpu);

pub fn search(
    params: slimy.SearchParams,
    callback_context: anytype,
    comptime resultCallback: fn (@TypeOf(callback_context), slimy.Result) void,
    comptime progressCallback: ?fn (@TypeOf(callback_context), completed: u64, total: u64) void,
) !void {
    var ctx = Context{};
    try ctx.init();
    defer ctx.deinit();
    try ctx.search(params, callback_context, resultCallback, progressCallback);
}

pub const Context = struct {
    inited: bool = false,

    ctx: zc.Context = undefined,
    shad: Shader = undefined,
    buffers: [2]ResultBuffers = undefined,
    buf_idx: u1 = 0,

    const Shader = zc.Shader(&.{
        zc.pushConstant("params", 0, GpuParams),
        zc.storageBuffer("result_count", 0, zc.Buffer(u32)),
        zc.storageBuffer("results", 1, zc.Buffer(slimy.Result)),
    });

    pub fn init(self: *Context) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        self.ctx = zc.Context.init(arena.allocator(), .{}) catch |err| {
            log.err("Vulkan init error: {s}", .{@errorName(err)});
            return error.VulkanInit;
        };

        self.shad = Shader.initBytes(arena.allocator(), &self.ctx, @embedFile("shader/search.spv")) catch |err| {
            log.err("Shader init error: {s}", .{@errorName(err)});
            return error.ShaderInit;
        };
        errdefer self.shad.deinit();

        // Result buffers - two of these so we can double-buffer
        self.buffers[0] = ResultBuffers.init(&self.ctx) catch |err| {
            log.err("Buffer 0 init error: {s}", .{@errorName(err)});
            return error.BufferInit;
        };
        errdefer self.buffers[0].deinit();
        self.buffers[1] = ResultBuffers.init(&self.ctx) catch |err| {
            log.err("Buffer 1 init error: {s}", .{@errorName(err)});
            return error.BufferInit;
        };
        errdefer self.buffers[1].deinit();

        log.debug("init ok", .{});
        self.inited = true;
    }

    pub fn deinit(self: Context) void {
        self.buffers[0].deinit();
        self.buffers[1].deinit();
        self.shad.deinit();
        self.ctx.deinit();
    }

    pub fn search(
        self: *Context,
        params: slimy.SearchParams,
        callback_context: anytype,
        comptime resultCallback: fn (@TypeOf(callback_context), slimy.Result) void,
        comptime progressCallback: ?fn (@TypeOf(callback_context), completed: u64, total: u64) void,
    ) !void {
        std.debug.assert(self.inited);

        log.debug("start search", .{});
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
            const batch_z = @min(search_size[1] - z, batch_size[1]);

            var x: u32 = 0;
            while (x < search_size[0]) : (x += batch_size[0]) {
                const batch_x = @min(search_size[0] - x, batch_size[0]);

                if (progressCallback) |cb| {
                    const chunk_index = x + z * @as(u64, search_size[0]);
                    cb(callback_context, chunk_index, @as(u64, search_size[0]) * search_size[1]);
                }

                self.shad.exec(std.time.ns_per_s, .{
                    .x = batch_x,
                    .y = batch_z,
                    .baseX = x,
                    .baseY = z,
                }, .{
                    .params = gpu_params,
                    .result_count = self.buffers[self.buf_idx].count,
                    .results = self.buffers[self.buf_idx].results,
                }) catch |err| switch (err) {
                    error.Timeout => return error.Timeout,
                    else => return error.ShaderExec,
                };
                self.buf_idx ^= 1;

                if (x != 0 or z != 0) { // If we're the first batch, there are no previous results to report
                    try self.buffers[self.buf_idx].report(callback_context, resultCallback);
                }
            }
        }

        if (!(self.shad.waitTimeout(std.time.ns_per_s) catch return error.ShaderExec)) {
            return error.Timeout;
        }
        self.buf_idx ^= 1;
        try self.buffers[self.buf_idx].report(callback_context, resultCallback);
    }
};

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
