const std = @import("std");
const builtin = @import("builtin");
const optz = @import("optz");
const slimy = @import("slimy.zig");

pub fn main() u8 {
    const stdout = std.io.getStdOut();
    const stderr = std.io.getStdErr();

    const options = parseArgs() catch |err| switch (err) {
        error.Help => {
            usage(stdout);
            return 0;
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
        error.InvalidFormat => {
            std.log.err("Invalid output format. Must be 'csv', 'json' or 'human'", .{});
            return 1;
        },
        error.InvalidCharacter => {
            std.log.err("Invalid number", .{});
            return 1;
        },
        error.Overflow => {
            std.log.err("Number too large", .{});
            return 1;
        },

        error.Unseekable => {
            std.log.err("Cannot use -i with unseekable non-tty output stream", .{});
            return 1;
        },

        error.InvalidCmdLine => {
            std.log.err("Encoding error in command line arguments", .{});
            return 1;
        },

        error.OutOfMemory => @panic("Out of memory"),
    };

    var ctx = OutputContext.init(std.heap.page_allocator, options.output);
    defer ctx.flush();

    slimy.search(options.search, &ctx, OutputContext.result) catch |err| switch (err) {
        error.ThreadQuotaExceeded => @panic("Thread quota exceeded"),
        error.SystemResources => @panic("System resources error"),
        error.OutOfMemory => @panic("Out of memory"),
        error.LockedMemoryLimitExceeded => unreachable,
        error.Unexpected => @panic("Unexpected error"),
    };

    return 0;
}

const OutputContext = struct {
    f: std.fs.File,
    options: OutputOptions,
    buf: std.ArrayList(slimy.Result),
    first: bool = true, // True if no results have been output

    pub fn init(allocator: *std.mem.Allocator, options: OutputOptions) OutputContext {
        return OutputContext{
            .f = std.io.getStdOut(),
            .options = options,
            .buf = std.ArrayList(slimy.Result).init(allocator),
        };
    }

    pub fn result(self: *OutputContext, res: slimy.Result) void {
        if (self.options.sort) {
            self.buf.append(res) catch {
                std.log.warn("Out of memory while attempting to sort items; output may be unsorted", .{});
                self.output(res);
                return;
            };
            std.sort.insertionSort(slimy.Result, self.buf.items, {}, slimy.Result.sortLessThan);
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
        if (self.options.format == .json) {
            if (self.first) {
                self.print("[\n", .{});
            } else {
                self.print(",\n", .{});
            }
        }
        self.first = false;
        switch (self.options.format) {
            .human => self.print("({:>5}, {:>5})   {}\n", .{ res.x, res.z, res.count }),
            .json => self.print(
                \\ {{ "x": {}, "z": {}, "count": {} }}
            , .{ res.x, res.z, res.count }),
            .csv => self.print("{},{},{}\n", .{ res.x, res.z, res.count }),
        }
    }

    pub fn flush(self: *OutputContext) void {
        for (self.buf.items) |res| {
            self.output(res);
        }
        if (self.options.format == .json) {
            self.print("\n]\n", .{});
        }
        self.buf.deinit();
    }
};

pub const OutputOptions = struct {
    format: Format,
    sort: bool,
    in_place: bool,

    const Format = enum {
        csv,
        json,
        human,
    };
};

fn usage(out: std.fs.File) void {
    out.writeAll(
        \\Usage: slimy [OPTIONS] SEED RANGE THRESHOLD
        \\
        \\  -h              Display this help message
        \\  -f FORMAT       Output format (csv, json or human) (NOT YET IMPLEMENTED)
        \\  -u              Disable output sorting
        \\  -i              Enable in-place sorting (default for human output to tty) (NOT YET IMPLEMENTED)
        \\  -j THREADS      Number of threads to use
        \\
        \\
    ) catch return;
}

const Options = struct {
    search: slimy.SearchParams,
    output: OutputOptions,
};

fn parseArgs() !Options {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var args = std.process.args();
    var flags = try optz.parse(&arena.allocator, struct {
        h: bool = false,

        f: []const u8 = "human",
        u: bool = false,
        i: ?bool = null,
        j: u8 = 0,
    }, &args);

    if (flags.h) {
        return error.Help;
    }

    const format = std.meta.stringToEnum(OutputOptions.Format, flags.f) orelse {
        return error.InvalidFormat;
    };

    const out = std.io.getStdOut();
    if (flags.i == null) {
        flags.i = format == .human and out.supportsAnsiEscapeCodes();
    } else if (flags.i.? and !out.supportsAnsiEscapeCodes()) {
        out.seekBy(0) catch return error.Unseekable;
    }

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

    const seed = try args.next(&arena.allocator) orelse return error.NotEnoughArgs;
    const range = try args.next(&arena.allocator) orelse return error.NotEnoughArgs;
    const threshold = try args.next(&arena.allocator) orelse return error.NotEnoughArgs;
    if (args.skip()) {
        return error.TooManyArgs;
    }
    const range_n: i32 = try std.fmt.parseInt(u31, range, 10);

    return Options{
        .search = .{
            .world_seed = try std.fmt.parseInt(i64, seed, 10),
            .threshold = try std.fmt.parseInt(u32, threshold, 10),

            .x0 = -range_n,
            .z0 = -range_n,
            .x1 = range_n,
            .z1 = range_n,

            .method = .{
                .cpu = flags.j,
            },
        },
        .output = .{
            .format = format,
            .sort = !flags.u,
            .in_place = flags.i.?,
        },
    };
}
