const std = @import("std");
const slimy = @import("slimy.zig");

export fn searchInit(
    world_seed: i64,
    threshold: i32,
    x0: i32,
    x1: i32,
    z0: i32,
    z1: i32,
) ?*AsyncSearcher {
    return AsyncSearcher.init(std.heap.page_allocator, .{
        .world_seed = world_seed,
        .threshold = threshold,

        .x0 = x0,
        .x1 = x1,
        .z0 = z0,
        .z1 = z1,

        .method = .{ .cpu = 1 },
    }) catch null;
}

export fn searchStep(searcher: *AsyncSearcher) bool {
    return searcher.step();
}

export fn searchProgress(searcher: *AsyncSearcher) f64 {
    return searcher.progress;
}

export fn searchDeinit(searcher: *AsyncSearcher) void {
    searcher.deinit();
}

const AsyncSearcher = struct {
    allocator: std.mem.Allocator,
    progress: f64 = 0,

    done: bool = false,
    frame: anyframe = undefined,
    frame_storage: @Frame(search) = undefined,

    pub fn init(allocator: std.mem.Allocator, params: slimy.SearchParams) !*AsyncSearcher {
        const self = try allocator.create(AsyncSearcher);
        self.* = .{ .allocator = allocator };
        self.frame_storage = async self.search(params);
        return self;
    }
    pub fn deinit(self: *AsyncSearcher) void {
        self.allocator.destroy(self);
    }

    pub fn step(self: *AsyncSearcher) bool {
        if (!self.done) {
            resume self.frame;
        }
        return !self.done;
    }

    fn yield(self: *AsyncSearcher) void {
        suspend {
            self.frame = @frame();
        }
    }

    fn search(self: *AsyncSearcher, params: slimy.SearchParams) void {
        self.yield();
        slimy.cpu.Searcher(*AsyncSearcher)
            .init(params, self)
            .searchSinglethread();
        self.done = true;
    }

    pub fn reportResult(_: *AsyncSearcher, res: slimy.Result) void {
        resultCallback(res.x, res.z, res.count);
    }
    pub fn reportProgress(self: *AsyncSearcher, completed: u64, total: u64) void {
        const resolution = 10_000;
        const progress = resolution * completed / total;
        const fraction = @as(f64, @floatFromInt(progress)) / resolution;
        self.progress = fraction;
        self.yield();
    }
};

extern "slimy" fn resultCallback(x: i32, z: i32, count: u32) void;

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, fmt, args) catch return;
    consoleLog(str.ptr, str.len);
}
extern "slimy" fn consoleLog(ptr: [*]const u8, len: usize) void;
