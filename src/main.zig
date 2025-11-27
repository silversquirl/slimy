const std = @import("std");
const builtin = @import("builtin");
const optz = @import("optz");
const slimy = @import("slimy.zig");
const root = @import("root");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .log_scope_levels = &.{
        .{ .scope = .thread, .level = .err },
        .{ .scope = .zcompute, .level = .err },
        .{ .scope = .gpu, .level = .err },
    },
};

pub const functions_to_analyze = .{
    @import("cpu/slime_check/scalar.zig").isSlime,
    @import("cpu/slime_check/scalar.zig").isSlimeBiased,
    @import("cpu/slime_check/scalar.zig").getRandomSeed,
    struct {
        pub fn nextInt(random: *@import("cpu/slime_check/scalar.zig").Random) i32 {
            return random.nextIntBasic(10);
        }
    }.nextInt,
};

pub fn main() u8 {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

    var stdout = std.fs.File.stdout().writer(arena.allocator().alloc(u8, 64) catch @panic("Out of memory"));
    var stderr = std.fs.File.stderr().writer(arena.allocator().alloc(u8, 64) catch @panic("Out of memory"));

    const options = parseArgs(arena.allocator()) catch |err| switch (err) {
        error.Help => {
            return usage(&stdout.interface);
        },

        error.Version => {
            return version(&stdout.interface);
        },

        error.Benchmark => {
            return @import("bench.zig").main();
        },

        error.TooManyArgs => {
            _ = usage(&stderr.interface);
            std.log.err("Too many arguments", .{});
            return 1;
        },
        error.NotEnoughArgs => {
            _ = usage(&stderr.interface);
            std.log.err("Not enough arguments", .{});
            return 1;
        },

        error.InvalidFlag => {
            _ = usage(&stderr.interface);
            std.log.err("Invalid option", .{});
            return 1;
        },
        error.MissingParameter => {
            _ = usage(&stderr.interface);
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

    var ctx: OutputContext = .init(std.heap.page_allocator, &stdout.interface, &stderr.interface, options.output);
    defer ctx.flush();

    for (options.searches) |search| {
        slimy.search(search, &ctx, OutputContext.result, OutputContext.progress) catch |err|
            switch (err) {
                error.ThreadQuotaExceeded => @panic("Thread quota exceeded"),
                error.SystemResources => @panic("System resources error"),
                error.OutOfMemory => @panic("Out of memory"),
                error.LockedMemoryLimitExceeded => unreachable,
                error.Unexpected => @panic("Unexpected error"),
                else => |gpu_err| if (@import("build_consts").gpu_support) switch (gpu_err) {
                    error.ShaderInit => @panic("Compute pipeline init failed"),
                    error.BufferInit => @panic("Buffer allocation failed"),
                    error.ShaderExec => @panic("GPU compute execution failed"),
                    error.Timeout => @panic("Shader execution timed out"),
                    error.MemoryMapFailed => @panic("Mapping buffer memory failed"),
                    error.VulkanInit => {
                        std.log.err("Vulkan initialization failed. Your GPU may not support Vulkan; try using the CPU search instead (-mcpu option)", .{});
                        return 1;
                    },
                } else switch (gpu_err) {
                    error.GpuNotSupported => {
                        std.log.err("Slimy was compiled without GPU support; try using the CPU search instead (-mcpu option)", .{});
                        return 1;
                    },
                },
            };
    }

    return 0;
}

const OutputContext = struct {
    lock: std.Thread.Mutex = .{},

    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,

    options: OutputOptions,

    allocator: std.mem.Allocator,
    buf: std.ArrayList(slimy.Result),

    progress_timer: ?std.time.Timer,
    completed: u64 = 0,
    total: u64 = 1,

    const progress_tick = std.time.ns_per_s / 4;
    const progress_spinner = [_]u21{
        '◜',
        '◝',
        '◞',
        '◟',
    };

    pub fn init(allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer, options: OutputOptions) OutputContext {
        return .{
            .stdout = stdout,
            .stderr = stderr,
            .allocator = allocator,
            .options = options,
            .buf = .empty,
            .progress_timer = if (options.progress)
                std.time.Timer.start() catch blk: {
                    std.log.err("Error initializing progress timer", .{});
                    break :blk null;
                }
            else
                null,
        };
    }

    pub fn result(self: *OutputContext, res: slimy.Result) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.options.sort) {
            self.buf.append(self.allocator, res) catch {
                self.clearProgress() catch {};

                std.log.warn("Out of memory while attempting to sort items; output may be unsorted", .{});
                self.printResult(res) catch |err| std.debug.panic("Error writing output: {s}", .{@errorName(err)});

                self.printProgress() catch {};
                return;
            };
            // TODO: directly insert item
            std.sort.insertion(slimy.Result, self.buf.items, {}, slimy.Result.sortLessThan);
        } else {
            self.clearProgress() catch {};

            self.printResult(res) catch |err| std.debug.panic("Error writing output: {s}", .{@errorName(err)});

            self.printProgress() catch {};
        }
    }

    fn printResult(self: *OutputContext, res: slimy.Result) !void {
        switch (self.options.format) {
            .human => try self.stdout.print("({:>5}, {:>5})   {}\n", .{ res.x, res.z, res.count }),
            .csv => try self.stdout.print("{},{},{}\n", .{ res.x, res.z, res.count }),
        }
        try self.stdout.flush();
    }

    pub fn progress(self: *OutputContext, completed: u64, total: u64) void {
        self.lock.lock();
        defer self.lock.unlock();

        self.completed, self.total = .{ completed, total };
        self.clearAndPrintProgress() catch {};
    }

    /// Only flushes once, to prevent visual artifacts
    fn clearAndPrintProgress(self: *OutputContext) !void {
        const timer = &(self.progress_timer orelse return);

        const tick = timer.read() / progress_tick;

        try self.stderr.writeAll("\r\x1b[K");

        try self.stderr.print("[{u}] {d:.2}%", .{
            progress_spinner[tick % progress_spinner.len],
            @as(f64, @floatFromInt(100_00 * self.completed / self.total)) * 0.01,
        });
        try self.stderr.flush();
    }

    fn clearProgress(self: *OutputContext) !void {
        if (self.progress_timer == null) return;

        try self.stderr.writeAll("\r\x1b[K");
        try self.stderr.flush();
    }

    fn printProgress(self: *OutputContext) !void {
        const timer = &(self.progress_timer orelse return);

        const tick = timer.read() / progress_tick;

        try self.stderr.print("[{u}] {d:.2}%", .{
            progress_spinner[tick % progress_spinner.len],
            @as(f64, @floatFromInt(100_00 * self.completed / self.total)) * 0.01,
        });
        try self.stderr.flush();
    }

    pub fn flush(self: *OutputContext) void {
        self.clearProgress() catch {};
        for (self.buf.items) |res| {
            self.printResult(res) catch |err| std.debug.panic("Error writing output: {s}", .{@errorName(err)});
        }
    }

    pub fn deinit(self: *OutputContext) void {
        self.buf.deinit(self.allocator);
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

test OutputContext {
    var stdout = std.fs.File.stdout().writer(&.{});
    var stderr = std.fs.File.stderr().writer(&.{});
    var ctx: OutputContext = .init(std.testing.allocator, &stdout.interface, &stderr.interface, .{
        .format = .csv,
        .sort = true,
        .progress = false,
    });
    ctx.progress(1, 10);
    ctx.flush();
    ctx.deinit();
}

fn usage(out: *std.Io.Writer) u8 {
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
    ) catch return 1;
    out.flush() catch return 1;
    return 0;
}

fn version(out: *std.Io.Writer) u8 {
    out.writeAll(@import("version.zig").full_desc ++ "\n") catch return 1;
    out.flush() catch return 1;
    return 0;
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
        std.log.err("Invalid output format '{f}'. Must be 'human' or 'csv'", .{@as(
            std.fmt.Alt([]const u8, stringEscape),
            .{ .data = flags.f },
        )});
        return error.InvalidFormat;
    };

    const progress = !flags.q and std.fs.File.stderr().supportsAnsiEscapeCodes();

    const method_id = std.meta.stringToEnum(std.meta.Tag(slimy.SearchMethod), flags.m) orelse {
        std.log.err("Invalid search method '{f}'. Must be 'gpu' or 'cpu'", .{@as(
            std.fmt.Alt([]const u8, stringEscape),
            .{ .data = flags.f },
        )});
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
        s[0] = .{
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
        try std.fs.File.stdin().readToEndAlloc(arena, 1 << 20)
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

/// Copied and modified from std.zig of 0.12
/// Print the string as escaped contents of a single quoted string.
pub fn stringEscape(bytes: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (bytes) |byte| switch (byte) {
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeByte('"'),
        '\'' => try w.writeAll("\\'"),
        ' ', '!', '#'...'&', '('...'[', ']'...'~' => try w.writeByte(byte),
        // Use hex escapes for rest any unprintable characters.
        else => {
            try w.writeAll("\\x");
            try w.printInt(byte, 16, .lower, .{ .width = 2, .fill = '0' });
        },
    };
}
