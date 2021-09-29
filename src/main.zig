const std = @import("std");
const slimy = @import("slimy.zig");

pub fn main() !void {
    const thread_count = std.math.lossyCast(u8, try std.Thread.getCpuCount());
    try slimy.search(.{
        .world_seed = 1,
        .range = 10000,
        .threshold = 45,
        .method = .{ .cpu = thread_count },
    }, {}, callback);
}

fn callback(_: void, res: slimy.Result) void {
    std.debug.print("({:>5}, {:>5})   {}\n", .{ res.x, res.z, res.count });
}
