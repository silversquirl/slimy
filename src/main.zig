const std = @import("std");
const builtin = @import("builtin");
const optz = @import("optz");
const slimy = @import("slimy.zig");
const version = @import("version.zig");

pub fn main() u8 {
    const stdout = std.io.getStdOut();
    const stderr = std.io.getStdErr();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const options = parseArgs(arena.allocator()) catch |err| switch (err) {
        error.Help => {
            usage(stdout);
            return 0;
        },

        error.Version => {
            stdout.writeAll(version.full_desc ++ "\n") catch return 1;
            return 0;
        },

        error.Benchmark => {
            return @import("bench.zig").main();
        },

        error.TooManyArgs => {
            usage(stderr);
            std.log.err("Too many arguments", .{});
            return 1;
        },
        error.NotEnoughArgs => {
            usage(stderr);
            std.log.err("Not enough arguments", .{});
            return 1;
        },

        error.InvalidFlag => {
            usage(stderr);
            std.log.err("Invalid option", .{});
            return 1;
        },
        error.MissingParameter => {
            usage(stderr);
            std.log.err("Missing option parameter", .{});
            return 1;
        },
        error.InvalidFormat => return 1,
        error.InvalidMethod => return 1,
        error.InvalidCharacter => {
            std.log.err("Invalid number", .{});
            return 1;
        },
        error.Overflow => {
            std.log.err("Number too large", .{});
            return 1;
        },

        error.JsonError => return 1, // Handled in parseArgs

        error.OutOfMemory => @panic("Out of memory"),
        error.InvalidCmdLine => {
            std.log.err("Encoding error in command line arguments", .{});
            return 1;
        },
    };

    var ctx = OutputContext.init(std.heap.page_allocator, options.output);
    defer ctx.flush();

    for (options.searches) |search| {
        slimy.search(search, &ctx, OutputContext.result, OutputContext.progress) catch |err| switch (err) {
            error.ThreadQuotaExceeded => @panic("Thread quota exceeded"),
            error.SystemResources => @panic("System resources error"),
            error.OutOfMemory => @panic("Out of memory"),
            error.LockedMemoryLimitExceeded => unreachable,
            error.Unexpected => @panic("Unexpected error"),

            error.VulkanInit => {
                std.log.err("Vulkan initialization failed. Your GPU may not support Vulkan; try using the CPU search instead (-mcpu option)", .{});
                return 1;
            },
            error.ShaderInit => @panic("Compute pipeline init failed"),
            error.BufferInit => @panic("Buffer allocation failed"),
            error.ShaderExec => @panic("GPU compute execution failed"),
            error.Timeout => @panic("Shader execution timed out"),
            error.MemoryMapFailed => @panic("Mapping buffer memory failed"),
        };
    }

    return 0;
}

const OutputContext = struct {
    lock: std.Thread.Mutex = .{},

    f: std.fs.File,
    options: OutputOptions,
    buf: std.ArrayList(slimy.Result),

    progress_timer: ?std.time.Timer,

    const progress_tick = std.time.ns_per_s / 4;
    const progress_spinner = [_]u21{
        '◜',
        '◝',
        '◞',
        '◟',
    };

    pub fn init(allocator: std.mem.Allocator, options: OutputOptions) OutputContext {
        return OutputContext{
            .f = std.io.getStdOut(),
            .options = options,
            .buf = std.ArrayList(slimy.Result).init(allocator),

            .progress_timer = if (options.progress)
                std.time.Timer.start() catch null
            else
                null,
        };
    }

    pub fn result(self: *OutputContext, res: slimy.Result) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.options.sort) {
            self.buf.append(res) catch {
                std.log.warn("Out of memory while attempting to sort items; output may be unsorted", .{});
                self.output(res);
                return;
            };
            std.sort.insertion(slimy.Result, self.buf.items, {}, slimy.Result.sortLessThan);
        } else {
            self.output(res);
        }
    }

    fn print(self: OutputContext, comptime fmt: []const u8, args: anytype) void {
        self.f.writer().print(fmt, args) catch |err| {
            std.debug.panic("Error writing output: {s}", .{@errorName(err)});
        };
    }
    fn output(self: *OutputContext, res: slimy.Result) void {
        self.progressLineClear();
        switch (self.options.format) {
            .human => self.print("({:>5}, {:>5})   {}\n", .{ res.x, res.z, res.count }),
            .csv => self.print("{},{},{}\n", .{ res.x, res.z, res.count }),
        }
    }

    fn progressLineClear(self: *OutputContext) void {
        if (self.progress_timer != null) {
            std.debug.print("\r\x1b[K", .{});
        }
    }
    pub fn progress(self: *OutputContext, completed: u64, total: u64) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.progress_timer) |*timer| {
            const tick = timer.read() / progress_tick;
            const stdErr = std.io.getStdErr();
            var buffered_writer: std.io.BufferedWriter(64, std.fs.File.Writer) = .{ .unbuffered_writer = stdErr.writer() };

            _ = buffered_writer.write("\r\x1b[K") catch unreachable;
            buffered_writer.writer().print("[{u}] {d:.2}%", .{
                progress_spinner[tick % progress_spinner.len],
                @as(f64, @floatFromInt(100_00 * completed / total)) * 0.01,
            }) catch unreachable;
            buffered_writer.flush() catch {};
        }
    }

    pub fn flush(self: *OutputContext) void {
        for (self.buf.items) |res| {
            self.output(res);
        }
        self.progressLineClear();
        self.buf.deinit();
    }
};

pub const OutputOptions = struct {
    format: Format,
    sort: bool,
    progress: bool,

    const Format = enum {
        csv,
        human,
    };
};

test {
    _ = @import("cpu/SearchBlock.zig");
    _ = @import("cpu/slime_check/scalar.zig");
    _ = @import("cpu/slime_check/simd.zig");
}

test "output context" {
    var ctx = OutputContext.init(std.testing.allocator, .{
        .format = .csv,
        .sort = true,
        .progress = false,
    });

    if (@import("builtin").os.tag != .windows) {
        const pipe = try std.posix.pipe();
        var readf = std.fs.File{ .handle = pipe[0] };
        defer readf.close();
        var writef = std.fs.File{ .handle = pipe[1] };
        defer writef.close();

        ctx.f = std.io.getStdOut();
        ctx.progress(1, 10);
        ctx.flush();
    } else {
        ctx.progress(1, 10);
        ctx.flush();
    }
}

fn usage(out: std.fs.File) void {
    out.writeAll(
        \\Usage:
        \\    slimy [OPTIONS] SEED RANGE THRESHOLD
        \\    slimy [OPTIONS] -s SEED
        \\
        \\  -h              Display this help message
        \\  -v              Display version information
        \\  -f FORMAT       Output format (human [default] or csv)
        \\  -u              Disable output sorting
        \\  -q              Disable progress reporting
        \\  -m METHOD       Search method (gpu [default] or cpu)
        \\  -j THREADS      Number of threads to use (for cpu method only)
        \\  -s FILENAME     Read search parameters from a JSON file (or - for stdin)
        \\  -b              Benchmark mode
        \\
        \\
    ) catch return;
}

const Options = struct {
    searches: []const slimy.SearchParams,
    output: OutputOptions,
};

const ArgsError = error{
    Help,
    Version,
    Benchmark,
    TooManyArgs,
    NotEnoughArgs,
    InvalidFlag,
    MissingParameter,
    InvalidFormat,
    InvalidMethod,
    InvalidCharacter,
    Overflow,
    JsonError,
    OutOfMemory,
    InvalidCmdLine,
};

fn parseArgs(arena: std.mem.Allocator) ArgsError!Options {
    var args = try std.process.argsWithAllocator(arena);
    var flags = try optz.parse(arena, struct {
        h: bool = false,
        v: bool = false,

        f: []const u8 = "human",
        u: bool = false,
        q: bool = false,

        m: []const u8 = "gpu",
        j: u8 = 0,

        s: ?[]const u8 = null,

        b: bool = false,
    }, &args);

    if (flags.h) return error.Help;
    if (flags.v) return error.Version;
    if (flags.b) return error.Benchmark;

    const format = std.meta.stringToEnum(OutputOptions.Format, flags.f) orelse {
        std.log.err("Invalid output format '{'}'. Must be 'human' or 'csv'", .{
            std.zig.fmtEscapes(flags.f),
        });
        return error.InvalidFormat;
    };

    const progress = !flags.q and std.io.getStdErr().supportsAnsiEscapeCodes();

    const method_id = std.meta.stringToEnum(std.meta.Tag(slimy.SearchMethod), flags.m) orelse {
        std.log.err("Invalid search method '{'}'. Must be 'gpu' or 'cpu'", .{
            std.zig.fmtEscapes(flags.m),
        });
        return error.InvalidMethod;
    };

    if (method_id == .cpu) {
        if (builtin.single_threaded) {
            if (flags.j == 0) {
                flags.j = 1;
            } else if (flags.j != 1) {
                return error.SingleThreaded;
            }
        } else {
            if (flags.j == 0) {
                flags.j = std.math.lossyCast(u8, std.Thread.getCpuCount() catch 1);
            }
        }
    }

    const seed_s = args.next() orelse return error.NotEnoughArgs;
    const seed = try std.fmt.parseInt(i64, seed_s, 10);
    const method: slimy.SearchMethod = switch (method_id) {
        .gpu => .gpu,
        .cpu => .{ .cpu = flags.j },
    };

    var searches: []const slimy.SearchParams = undefined;
    if (flags.s) |path| {
        // TODO: require all same world seed, or specify world seed on command line or something
        const json_params = readJsonParams(arena, path) catch |err| {
            std.log.err("Error reading JSON file '{s}': {s}", .{ path, @errorName(err) });
            return error.JsonError;
        };

        var s = try arena.alloc(slimy.SearchParams, json_params.len);
        for (json_params, 0..) |param, i| {
            var p = param;
            if (p.x0 > p.x1) {
                std.mem.swap(i32, &p.x0, &p.x1);
            }
            if (p.z0 > p.z1) {
                std.mem.swap(i32, &p.z0, &p.z1);
            }

            s[i] = .{
                .world_seed = seed,
                .threshold = p.threshold,

                .x0 = p.x0,
                .z0 = p.z0,
                .x1 = p.x1,
                .z1 = p.z1,

                .method = method,
            };
        }
        searches = s;
    } else {
        const range = args.next() orelse return error.NotEnoughArgs;
        const threshold = args.next() orelse return error.NotEnoughArgs;
        if (args.skip()) {
            return error.TooManyArgs;
        }
        const range_n: i32 = try std.fmt.parseInt(u31, range, 10);

        var s = try arena.alloc(slimy.SearchParams, 1);
        s[0] =
            .{
            .world_seed = seed,
            .threshold = try std.fmt.parseInt(u8, threshold, 10),

            .x0 = -range_n,
            .z0 = -range_n,
            .x1 = range_n,
            .z1 = range_n,

            .method = method,
        };
        searches = s;
    }

    return Options{
        .searches = searches,
        .output = .{
            .format = format,
            .sort = !flags.u,
            .progress = progress,
        },
    };
}

fn readJsonParams(arena: std.mem.Allocator, path: []const u8) ![]const JsonParams {
    const data = if (std.mem.eql(u8, path, "-"))
        try std.io.getStdIn().readToEndAlloc(arena, 1 << 20)
    else
        try std.fs.cwd().readFileAlloc(arena, path, 1 << 20);

    return std.json.parseFromSliceLeaky([]const JsonParams, arena, data, .{});
}
const JsonParams = struct {
    threshold: u8,

    x0: i32,
    z0: i32,
    x1: i32,
    z1: i32,
};
