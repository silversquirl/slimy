const slimy = @import("slimy.zig");

export fn search(world_seed: i64, range: i32, threshold: u32) void {
    slimy.cpu.Searcher(.{
        .Context = void,
        .resultCallback = searchCallbackInternal,
        .Thread = undefined,
        .spawn = undefined,
    }).init(.{
        .world_seed = world_seed,
        .range = @intCast(u31, range),
        .threshold = threshold,
        .method = .{ .cpu = 1 },
    }, {}).searchSinglethread();
}
fn searchCallbackInternal(_: void, res: slimy.Result) void {
    searchCallback(res.x, res.z, res.count);
}
extern "slimy" fn searchCallback(x: i32, z: i32, count: u32) void;
