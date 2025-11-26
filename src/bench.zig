const std = @import("std");
const cpuinfo = @import("cpuinfo");
const slimy = @import("slimy.zig");
const version = @import("version.zig");
const zc = @import("zcompute");

pub fn main() u8 {
    mainInternal() catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        return 1;
    };
    return 0;
}

fn mainInternal() !void {
    var stdout = std.fs.File.stdout().writer(&.{});
    const w = &stdout.interface;

    try w.print("slimy benchmark v{f}\n\n", .{version.version});

    try benchCpu(w);

    try w.writeByte('\n');
    if (@import("build_consts").gpu_support)
        try benchGpu(w)
    else
        try w.print("skipping gpu benchmark; built without gpu support\n", .{});
}

fn printGpuHeader(out: *std.Io.Writer, gpu: slimy.gpu.Context) !void {
    const gpu_name = std.mem.sliceTo(&gpu.ctx.device_properties.device_name, 0);
    const gpu_type: []const u8 = switch (gpu.ctx.device_properties.device_type) {
        .integrated_gpu => "integrated",
        .discrete_gpu => "discrete",
        .virtual_gpu => "virtual",
        .cpu => "software renderer",
        .other => "other",
        _ => "unknown",
    };
    try out.print("GPU: {s} ({s})\n", .{ gpu_name, gpu_type });
}

fn printCpuHeader(out: *std.Io.Writer) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const cpu_info = try cpuinfo.get(arena.allocator());
    try out.print("CPU: {f}\n", .{cpu_info});
}

const Collector = struct {
    buf: [64]slimy.Result = undefined,
    n: u6 = 0,

    pub fn reset(self: *Collector) void {
        self.n = 0;
    }

    pub fn result(self: *Collector, res: slimy.Result) void {
        self.buf[self.n] = res;
        self.n += 1;
    }

    pub fn check(self: *Collector, expected: []const slimy.Result) !void {
        std.sort.block(slimy.Result, self.buf[0..self.n], {}, slimy.Result.sortLessThan);
        std.debug.assert(
            std.sort.isSorted(slimy.Result, expected, {}, slimy.Result.sortLessThan),
        );
        try std.testing.expectEqualSlices(slimy.Result, expected, self.buf[0..self.n]);
    }
};

fn targetParams(rate: u128, target_secs: u8, method: slimy.SearchMethod) slimy.SearchParams {
    const num_locations = rate * target_secs;
    const width: u31 = @intCast(std.math.sqrt(num_locations));
    const height: u31 = @intCast(num_locations / width);
    return .{
        .world_seed = test_seed,
        .threshold = 100,

        .x0 = 0,
        .z0 = 0,
        .x1 = width,
        .z1 = height,

        .method = method,
    };
}

fn benchGpu(w: *std.Io.Writer) !void {
    var gpu_context: slimy.gpu.Context = .{};
    try gpu_context.init();
    try printGpuHeader(w, gpu_context);

    var collector: Collector = .{};
    var params = warmup_params;
    params.method = .gpu;
    var timer: std.time.Timer = try .start();

    try w.writeAll("Performing warmup test...");
    try gpu_context.search(params, &collector, Collector.result, null);

    const approx_gpu_rate = locationRate(timer.read(), params);
    try w.writeAll(" Validating results...");
    try collector.check(expected_warmup_results);
    try w.writeAll(" OK\n");

    collector.reset();

    // 3x ~5s GPU benchmark
    try w.writeAll("Performing 3x GPU runs");
    var gpu_rate: u128 = approx_gpu_rate;
    for (0..3) |i| {
        try w.writeByte('.');
        gpu_rate += try benchGpuIter(&gpu_context, gpu_rate / (i + 1), 5);
    }
    gpu_rate = (gpu_rate - approx_gpu_rate) / 3; // Mean
    try w.print(
        " {f} locations per second\n",
        .{@as(
            std.fmt.Alt(u128, formatIntGrouped),
            .{ .data = gpu_rate },
        )},
    );
}

fn benchGpuIter(gpu_context: *slimy.gpu.Context, rate: u128, target_secs: u8) !u128 {
    const params = targetParams(rate, target_secs, .gpu);
    var timer: std.time.Timer = try .start();
    try gpu_context.search(params, {}, devNull, null);
    return locationRate(timer.read(), params);
}

fn benchCpu(w: *std.Io.Writer) !void {
    try printCpuHeader(w);
    var collector: Collector = .{};
    var params = warmup_params;
    params.method = .{ .cpu = std.math.lossyCast(u8, try std.Thread.getCpuCount()) };
    var timer: std.time.Timer = try .start();

    try w.writeAll("Performing warmup test...");
    try slimy.cpu.search(params, &collector, Collector.result, null);

    const approx_cpu_rate = locationRate(timer.read(), params);
    try w.writeAll(" Validating results...");
    try collector.check(expected_warmup_results);
    try w.writeAll(" OK\n");

    collector.reset();

    // 3x ~5s CPU benchmark
    try w.writeAll("Performing 3x CPU runs");
    var cpu_rate: u128 = approx_cpu_rate;
    for (0..3) |i| {
        try w.writeByte('.');
        cpu_rate += try benchCpuIter(params.method.cpu, cpu_rate / (i + 1), 5);
    }
    cpu_rate = (cpu_rate - approx_cpu_rate) / 3; // Mean
    try w.print(
        " {f} locations per second\n",
        .{@as(
            std.fmt.Alt(u128, formatIntGrouped),
            .{ .data = cpu_rate },
        )},
    );
}

fn benchCpuIter(threads: u8, rate: u128, target_secs: u8) !u128 {
    const params = targetParams(rate, target_secs, .{ .cpu = threads });
    var timer: std.time.Timer = try .start();
    try slimy.cpu.search(params, {}, devNull, null);
    return locationRate(timer.read(), params);
}

fn locationRate(time: u128, params: slimy.SearchParams) u128 {
    const width: u128 = @intCast(params.x1 - params.x0);
    const height: u128 = @intCast(params.z1 - params.z0);
    return width * height * std.time.ns_per_s / time;
}

fn formatIntGrouped(
    value: u128,
    writer: *std.Io.Writer,
) !void {
    if (value == 0) {
        try writer.writeByte('0');
        return;
    }

    // Approximation of the number of 3-digit groups in the largest u128
    const n_group = 128 * 4 / 13 / 3;

    var groups: [n_group]u10 = undefined;
    var val = value;
    var i: u8 = 0;
    while (val > 1000) {
        groups[i] = @intCast(val % 1000);
        val /= 1000;
        i += 1;
    }

    try writer.print("{}", .{val});
    while (i > 0) {
        i -= 1;
        try writer.print(" {:0>3}", .{groups[i]});
    }
}

fn devNull(_: void, res: slimy.Result) void {
    std.mem.doNotOptimizeAway(res);
}

const test_seed: i64 = -2152535657050944081;
const warmup_params: slimy.SearchParams = .{
    .world_seed = test_seed,
    .threshold = 39,

    .x0 = -1000,
    .z0 = -1000,
    .x1 = 1000,
    .z1 = 1000,

    .method = undefined,
};
const expected_warmup_results: []const slimy.Result = &.{
    .{ .x = 949, .z = -923, .count = 43 },
    .{ .x = 950, .z = -924, .count = 42 },
    .{ .x = 245, .z = 481, .count = 40 },
    .{ .x = 246, .z = 484, .count = 40 },
    .{ .x = -624, .z = -339, .count = 40 },
    .{ .x = 669, .z = -643, .count = 40 },
    .{ .x = -623, .z = -701, .count = 40 },
    .{ .x = 948, .z = -923, .count = 40 },
    .{ .x = 949, .z = -924, .count = 40 },
    .{ .x = 950, .z = -923, .count = 40 },
    .{ .x = 950, .z = -926, .count = 40 },
    .{ .x = 327, .z = -140, .count = 39 },
    .{ .x = -423, .z = 50, .count = 39 },
    .{ .x = 430, .z = 298, .count = 39 },
    .{ .x = -554, .z = 270, .count = 39 },
    .{ .x = 664, .z = 356, .count = 39 },
    .{ .x = 715, .z = -375, .count = 39 },
    .{ .x = 716, .z = -375, .count = 39 },
    .{ .x = -309, .z = 800, .count = 39 },
    .{ .x = -310, .z = 800, .count = 39 },
    .{ .x = -726, .z = -575, .count = 39 },
    .{ .x = -725, .z = -579, .count = 39 },
    .{ .x = -726, .z = -579, .count = 39 },
    .{ .x = 671, .z = -644, .count = 39 },
    .{ .x = -624, .z = -701, .count = 39 },
    .{ .x = -883, .z = 338, .count = 39 },
    .{ .x = 684, .z = -752, .count = 39 },
    .{ .x = -700, .z = 758, .count = 39 },
    .{ .x = -636, .z = 843, .count = 39 },
    .{ .x = 949, .z = -922, .count = 39 },
    .{ .x = 951, .z = -923, .count = 39 },
    .{ .x = 949, .z = -926, .count = 39 },
    .{ .x = 951, .z = -924, .count = 39 },
    .{ .x = 950, .z = -928, .count = 39 },
};
