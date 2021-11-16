const std = @import("std");
const slimy = @import("slimy.zig");

pub fn main() !void {
    const thread_count = if (std.builtin.single_threaded)
        1
    else
        std.math.lossyCast(u8, try std.Thread.getCpuCount());

    try slimy.search(.{
        .world_seed = 1,
        .threshold = 41,

        .x0 = -1000,
        .x1 = 1000,
        .z0 = -1000,
        .z1 = 1000,

        .method = .{ .cpu = thread_count },
    }, {}, callback);
}

fn callback(_: void, res: slimy.Result) void {
    std.debug.print("({:>5}, {:>5})   {}\n", .{ res.x, res.z, res.count });
}
