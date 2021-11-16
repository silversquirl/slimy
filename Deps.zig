// This file originates from https://github.com/silversquirl/deps.zig
//
// Copyright (c) 2021 silversquirl
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

// Possible TODOs:
// - Parse source to ensure all dependencies are actually used
// - Allow multiple packages in one repo
// - Fetch packages at build time

const std = @import("std");
const builtin = @import("builtin");

update_step: std.build.Step,

b: *std.build.Builder,
dir: []const u8,
deps: std.StringArrayHashMapUnmanaged(Dep) = .{},
import_set: std.StringArrayHashMapUnmanaged(void) = .{},

const Deps = @This();
pub const Dep = union(enum) {
    managed: struct { // Fully managed dependency - we download these
        url: []const u8, // Git URL for the package
        path: []const u8, // Path to package directory
        main_path: []const u8, // Path to package main file
        deps: []const []const u8, // Dependency names of this package
    },
    tracked: struct { // Partially managed - we add dependencies to these
        main_path: []const u8, // Path to package main file
        deps: []const []const u8, // Dependency names of this package
    },
    unmanaged: struct { // Unmanaged - we just allow these as deps of other deps
        main_path: std.build.FileSource, // Path to package main file
        deps: ?[]const std.build.Pkg, // Dependencies of this package
    },
};

pub fn init(b: *std.build.Builder) *Deps {
    const self = initNoStep(b);
    const step = b.step("update", "Update all dependencies to the latest allowed version");
    step.dependOn(&self.update_step);

    return self;
}
pub fn initNoStep(b: *std.build.Builder) *Deps {
    const dir = std.os.getenv("DEPS_ZIG_CACHE") orelse switch (builtin.os.tag) {
        .windows => b.fmt("{s}\\Temp\\deps-zig", .{std.os.getenv("LOCALAPPDATA").?}),
        .macos => b.fmt("{s}/Library/Caches/deps-zig", .{std.os.getenv("HOME").?}),
        else => if (std.os.getenv("XDG_CACHE_HOME")) |cache|
            b.fmt("{s}/deps-zig", .{cache})
        else
            b.fmt("{s}/.cache/deps-zig", .{std.os.getenv("HOME").?}),
    };

    std.fs.cwd().makeDir(dir) catch {};
    var dirh = std.fs.cwd().openDir(dir, .{}) catch |err| {
        std.debug.print("Could not open packages dir '{}': {s}\n", .{ std.fmt.fmtSliceEscapeLower(dir), @errorName(err) });
        std.os.exit(1);
    };
    defer dirh.close();
    // Purposefully leak the file descriptor - it will be unlocked when the process exits
    _ = dirh.createFile(".lock", .{ .lock = .Exclusive, .lock_nonblocking = true }) catch |err| {
        std.debug.print("Failed to aqcuire package lock: {s}\n", .{@errorName(err)});
        std.os.exit(1);
    };

    const self = b.allocator.create(Deps) catch unreachable;
    self.* = .{
        .update_step = std.build.Step.init(.custom, "update-deps", b.allocator, makeUpdate),
        .b = b,
        .dir = dir,
    };
    return self;
}

pub fn addTo(self: Deps, step: *std.build.LibExeObjStep) void {
    var it = self.deps.iterator();
    while (it.next()) |entry| {
        step.addPackage(self.createPkg(entry.key_ptr.*, entry.value_ptr.*));
    }
}
fn createPkg(self: Deps, name: []const u8, dependency: Dep) std.build.Pkg {
    return switch (dependency) {
        .managed => |dep| .{
            .name = name,
            .path = .{ .path = dep.main_path },
            .dependencies = self.createPkgDeps(dep.deps),
        },
        .tracked => |dep| .{
            .name = name,
            .path = .{ .path = dep.main_path },
            .dependencies = self.createPkgDeps(dep.deps),
        },
        .unmanaged => |dep| .{
            .name = name,
            .path = dep.main_path,
            .dependencies = dep.deps,
        },
    };
}
fn createPkgDeps(self: Deps, dep_names: []const []const u8) ?[]const std.build.Pkg {
    if (dep_names.len == 0) return null;
    const deps = self.b.allocator.alloc(std.build.Pkg, dep_names.len) catch unreachable;
    var i: usize = 0;
    for (dep_names) |dname| {
        if (self.deps.get(dname)) |ddep| {
            deps[i] = self.createPkg(dname, ddep);
            i += 1;
        }
        // If we don't have the dep, ignore it and let the compiler error
    }
    return deps[0..i];
}

pub fn add(self: *Deps, url: []const u8, version: []const u8) void {
    const name = trimEnds(
        std.fs.path.basenamePosix(url),
        &.{"zig-"},
        &.{ ".git", ".zig", "-zig" },
    );
    const path = self.fetchPkg(name, url, version);

    const main_file = blk: {
        var dirh = std.fs.cwd().openDir(path, .{}) catch {
            std.debug.print("Failed to open package dir: {s}\n", .{path});
            std.os.exit(1);
        };
        for ([_][]const u8{
            self.b.fmt("{s}.zig", .{name}),
            "main.zig",
            self.b.fmt("src{c}{s}.zig", .{ std.fs.path.sep, name }),
            "src" ++ [_]u8{std.fs.path.sep} ++ "main.zig",
        }) |p| {
            if (dirh.access(p, .{})) |_| {
                dirh.close();
                break :blk p;
            } else |_| {}
        }
        dirh.close();

        std.debug.print("Could not find package entrypoint, attempted {s}.zig, main.zig, src{c}{[0]s}.zig and src{[1]c}main.zig\n", .{ name, std.fs.path.sep });
        std.os.exit(1);
    };
    const main_path = std.fs.path.join(self.b.allocator, &.{ path, main_file }) catch unreachable;

    const deps = self.parsePackageDeps(main_path) catch |err| switch (err) {
        error.InvalidSyntax => &[_][]const u8{},
        else => {
            std.debug.print("Failed to parse package dependencies for {s}: {s}\n", .{ main_file, @errorName(err) });
            std.os.exit(1);
        },
    };

    const dep = Dep{ .managed = .{
        .url = url,
        .path = path,
        .main_path = main_path,
        .deps = deps,
    } };
    if (self.deps.fetchPut(self.b.allocator, name, dep) catch unreachable) |_| {
        std.debug.print("Duplicate dependency '{s}'\n", .{std.fmt.fmtSliceEscapeLower(name)});
        std.os.exit(1);
    }
}

pub fn addPackagePath(self: *Deps, name: []const u8, main_path: []const u8) void {
    const deps = self.parsePackageDeps(main_path) catch |err| switch (err) {
        error.InvalidSyntax => &[_][]const u8{},
        else => {
            std.debug.print("Failed to parse package dependencies for {s}: {s}\n", .{ name, @errorName(err) });
            std.os.exit(1);
        },
    };

    const dep = Dep{ .tracked = .{
        .main_path = main_path,
        .deps = deps,
    } };
    if (self.deps.fetchPut(self.b.allocator, name, dep) catch unreachable) |_| {
        std.debug.print("Duplicate dependency '{s}'\n", .{std.fmt.fmtSliceEscapeLower(name)});
        std.os.exit(1);
    }
}

pub fn addPackage(self: *Deps, package: std.build.Pkg) void {
    const dep = Dep{ .unmanaged = .{
        .main_path = package.path,
        .deps = package.dependencies,
    } };
    if (self.deps.fetchPut(self.b.allocator, package.name, dep) catch unreachable) |_| {
        std.debug.print("Duplicate dependency '{s}'\n", .{std.fmt.fmtSliceEscapeLower(package.name)});
        std.os.exit(1);
    }
}

fn fetchPkg(self: Deps, name: []const u8, url: []const u8, version: []const u8) []const u8 {
    const path = self.b.allocator.alloc(u8, self.dir.len + 1 + url.len + 1 + version.len) catch unreachable;

    // Base dir
    var i: usize = 0;
    std.mem.copy(u8, path[i..], self.dir);
    i += self.dir.len;

    // Path separator
    path[i] = std.fs.path.sep;
    i += 1;

    // Encoded URL (/ replaced with : so it's a valid path)
    std.mem.copy(u8, path[i..], url);
    std.mem.replaceScalar(u8, path[i .. i + url.len], '/', ':');
    i += url.len;

    // Version separator
    path[i] = '@';
    i += 1;

    // Version
    std.mem.copy(u8, path[i..], version);
    i += version.len;
    std.debug.assert(i == path.len);

    // If we don't have the dep already, clone it
    std.fs.cwd().access(path, .{}) catch self.updateDep(name, path, url, version);

    return path;
}

fn parsePackageDeps(self: *Deps, main_file: []const u8) ![]const []const u8 {
    defer self.import_set.clearRetainingCapacity();

    var npkg = try self.collectImports(std.fs.cwd(), main_file);
    const pkgs = try self.b.allocator.alloc([]const u8, npkg);
    for (self.import_set.keys()) |key| {
        if (isPkg(key)) {
            npkg -= 1;
            pkgs[npkg] = key;
        }
    }

    return pkgs;
}
fn collectImports(self: *Deps, dir: std.fs.Dir, import: []const u8) CollectImportsError!usize {
    const data = dir.readFileAllocOptions(self.b.allocator, import, 4 << 30, null, 1, 0) catch |err| switch (err) {
        error.FileTooBig => {
            // If you have a 4GiB source file, you have a problem
            // However, we probably shouldn't outright error in this situation, so instead we'll warn and skip this file
            std.debug.print("Could not parse exceptionally large source file '{s}', skipping\n", .{std.fmt.fmtSliceEscapeLower(import)});
            return 0;
        },
        else => |e| return e,
    };
    var subdir = try dir.openDir(std.fs.path.dirname(import) orelse ".", .{});
    defer subdir.close();

    var toks = std.zig.Tokenizer.init(data);
    var npkg: usize = 0;
    while (true) {
        const tok = toks.next();
        if (tok.tag == .eof) break;

        if (tok.tag == .builtin and std.mem.eql(u8, data[tok.loc.start..tok.loc.end], "@import")) {
            if (toks.next().tag != .l_paren) return error.InvalidSyntax;
            const name_tok = toks.next();
            if (name_tok.tag != .string_literal) return error.InvalidSyntax;
            if (toks.next().tag != .r_paren) return error.InvalidSyntax;

            const name = std.zig.string_literal.parseAlloc(
                self.b.allocator,
                data[name_tok.loc.start..name_tok.loc.end],
            ) catch |err| switch (err) {
                error.InvalidStringLiteral => return error.InvalidSyntax,
                else => |e| return e,
            };

            if (try self.import_set.fetchPut(self.b.allocator, name, {})) |_| {
                // Do nothing, the entry is already in the set
            } else if (isPkg(name)) {
                npkg += 1;
            } else if (std.mem.endsWith(u8, name, ".zig")) {
                npkg += try self.collectImports(subdir, name);
            }
        }
    }

    return npkg;
}
const CollectImportsError =
    std.fs.Dir.OpenError ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    std.fs.File.SeekError ||
    std.mem.Allocator.Error ||
    error{InvalidSyntax};

fn makeUpdate(step: *std.build.Step) !void {
    const self = @fieldParentPtr(Deps, "update_step", step);
    var it = self.deps.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .managed => |dep| {
                const version_idx = 1 + std.mem.lastIndexOfScalar(u8, dep.path, '@').?;
                const version = dep.path[version_idx..];
                self.updateDep(entry.key_ptr.*, dep.path, dep.url, version);
            },
            else => {},
        }
    }
}
fn updateDep(self: Deps, name: []const u8, path: []const u8, url: []const u8, version: []const u8) void {
    std.fs.cwd().access(path, .{}) catch self.exec(&.{
        "git",
        "clone",
        "--depth=1",
        "--no-single-branch",
        "--shallow-submodules",
        "--",
        url,
        path,
    }, null);

    self.exec(&.{ "git", "fetch", "--all", "-Ppqt" }, path);
    // Check if there are changes - we don't want to clobber them
    if (self.execOk(&.{ "git", "diff", "--quiet", "HEAD" }, path)) {
        // Clean; check if version is a branch
        if (self.execOk(&.{
            "git",
            "show-ref",
            "--verify",
            "--",
            self.b.fmt("refs/remotes/origin/{s}", .{version}),
        }, path)) {
            // It is, so switch to it and pull
            self.exec(&.{ "git", "switch", "-q", "--", version }, path);
            self.exec(&.{ "git", "pull", "-q", "--ff-only" }, path);
        } else {
            // It isn't, check out detached
            self.exec(&.{ "git", "switch", "-dq", "--", version }, path);
        }
    } else {
        // Dirty; print a warning
        std.debug.print("WARNING: package {s} contains uncommitted changes, not attempting to update\n", .{name});
    }
}

fn isPkg(name: []const u8) bool {
    if (std.mem.endsWith(u8, name, ".zig")) return false;
    if (std.mem.eql(u8, name, "std")) return false;
    if (std.mem.eql(u8, name, "root")) return false;
    return true;
}

/// Remove each prefix, then each suffix, in order
fn trimEnds(haystack: []const u8, prefixes: []const []const u8, suffixes: []const []const u8) []const u8 {
    var s = haystack;
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, s, prefix)) {
            s = s[prefix.len..];
        }
    }
    for (suffixes) |suffix| {
        if (std.mem.endsWith(u8, s, suffix)) {
            s = s[0 .. s.len - suffix.len];
        }
    }
    return s;
}

fn exec(self: Deps, argv: []const []const u8, cwd: ?[]const u8) void {
    if (!self.execInternal(argv, cwd, .Inherit)) {
        std.debug.print("Command failed: {s}", .{argv[0]});
        for (argv[1..]) |arg| {
            std.debug.print(" {s}", .{arg});
        }
        std.debug.print("\n", .{});
        std.os.exit(1);
    }
}

fn execOk(self: Deps, argv: []const []const u8, cwd: ?[]const u8) bool {
    return self.execInternal(argv, cwd, .Ignore);
}

fn execInternal(self: Deps, argv: []const []const u8, cwd: ?[]const u8, io: std.ChildProcess.StdIo) bool {
    const child = std.ChildProcess.init(argv, self.b.allocator) catch unreachable;
    defer child.deinit();

    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = io;
    child.stderr_behavior = io;
    child.env_map = self.b.env_map;

    const term = child.spawnAndWait() catch |err| {
        std.debug.print("Unable to spawn {s}: {s}\n", .{ argv[0], @errorName(err) });
        return false;
    };
    switch (term) {
        .Exited => |code| if (code != 0) {
            return false;
        },
        .Signal, .Stopped, .Unknown => {
            return false;
        },
    }
    return true;
}
