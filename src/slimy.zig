pub const cpu = @import("cpu.zig");
pub const gpu = @import("gpu.zig");

pub fn search(
    params: SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), Result) void,
    comptime progressCallback: ?fn (@TypeOf(context), completed: u64, total: u64) void,
) !void {
    switch (params.method) {
        .cpu => try cpu.search(params, context, resultCallback, progressCallback),
        .gpu => try gpu.search(params, context, resultCallback, progressCallback),
    }
}

pub const SearchParams = struct {
    world_seed: i64,
    threshold: u8,

    x0: i32,
    z0: i32,
    x1: i32,
    z1: i32,

    method: SearchMethod,
};

pub const SearchMethod = union(enum) {
    cpu: u8, // Thread count
    gpu: void,
};

pub const Result = struct {
    x: i32,
    z: i32,
    count: u32,

    /// "Less-than" operation for sorting purposes
    pub fn sortLessThan(_: void, a: Result, b: Result) bool {
        if (a.count != b.count) {
            return a.count > b.count;
        }

        const a_d2 = (@as(i64, a.x) * a.x) + (@as(i64, a.z) * a.z);
        const b_d2 = (@as(i64, b.x) * b.x) + (@as(i64, b.z) * b.z);
        if (a_d2 != b_d2) {
            return a_d2 < b_d2;
        }

        if (a.x != b.x) {
            return a.x < b.x;
        }
        if (a.z != b.z) {
            return a.z < b.z;
        }
        return false;
    }
};

test {
    _ = cpu;
    _ = gpu;
}
