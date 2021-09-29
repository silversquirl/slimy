const slimy = @import("slimy.zig");

export fn search(world_seed: i64, range: i32, threshold: u32) void {
    slimy.search(world_seed, range, threshold, {}, searchCallbackInternal);
}
fn searchCallbackInternal(_: void, res: slimy.Result) void {
    searchCallback(res.x, res.z, res.count);
}
extern "slimy" fn searchCallback(x: i32, z: i32, count: u32) void;
