const std = @import("std");

const slimy_version = std.SemanticVersion.parse("0.1.0-dev") catch @panic("Parse error");

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const singlethread = b.option(bool, "singlethread", "Build in single-threaded mode") orelse false;
    const strip = b.option(bool, "strip", "Strip debug info from binaries") orelse false;
    const suffix = b.option(bool, "suffix", "Suffix binary names with version and target") orelse false;
    const timestamp = b.option(bool, "timestamp", "Include build timestamp in version information") orelse false;
    const glslc = b.option([]const u8, "glslc", "Specify the path to the glslc binary") orelse "glslc";

    const shaders = b.addSystemCommand(&.{
        glslc, "-o", "search.spv", "search.comp",
    });
    shaders.cwd = b.build_root.join(b.allocator, &.{ "src", "shader" }) catch @panic("OOM");

    var version = slimy_version;
    if (version.pre != null) {
        // Find git commit hash
        var code: u8 = undefined;
        if (b.execAllowFail(
            &.{ "git", "rev-parse", "--short", "HEAD" },
            &code,
            .Inherit,
        )) |commit| {
            version.build = std.mem.trimRight(u8, commit, "\n");

            // Add -dirty if we have uncommitted changes
            _ = b.execAllowFail(
                &.{ "git", "diff-index", "--quiet", "HEAD" },
                &code,
                .Inherit,
            ) catch |err| switch (err) {
                error.ExitCodeFailure => version.build = b.fmt("{s}-dirty", .{version.build.?}),
                else => |e| return e,
            };
        } else |err| switch (err) {
            error.FileNotFound => {}, // No git
            else => |e| return e,
        }
    }

    const consts = b.addOptions();
    consts.addOption(std.SemanticVersion, "version", version);
    consts.addOption(?i64, "timestamp", if (timestamp) std.time.timestamp() else null);

    const exe_name = if (suffix)
        b.fmt("slimy-{}-{s}", .{ version, target.zigTriple(b.allocator) catch @panic("OOM") })
    else
        "slimy";
    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.addModule("build_consts", consts.createModule());
    exe.addModule("optz", b.dependency("optz", .{}).module("optz"));
    exe.addModule("cpuinfo", b.dependency("cpuinfo", .{}).module("cpuinfo"));
    exe.addModule("zcompute", b.dependency("zcompute", .{}).module("zcompute"));

    exe.linkLibC();
    exe.step.dependOn(&shaders.step);
    exe.linkage = .dynamic;

    exe.single_threaded = singlethread;
    exe.strip = strip;
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const wasm = b.addSharedLibrary(.{
        .name = "slimy",
        .root_source_file = .{ .path = "src/web.zig" },
        .target = try std.zig.CrossTarget.parse(.{
            .arch_os_abi = "wasm32-freestanding",
        }),
        .optimize = optimize,
    });
    wasm.override_dest_dir = .{ .custom = "web" };
    wasm.single_threaded = true;

    const web = b.addInstallDirectory(.{
        .source_dir = "web",
        .install_dir = .prefix,
        .install_subdir = "web",
    });
    web.step.dependOn(&b.addInstallArtifact(wasm).step);

    const web_step = b.step("web", "Build web UI");
    web_step.dependOn(&web.step);

    const test_step = b.addTest(.{
        .root_source_file = .{ .path = "src/slimy.zig" },
    });
    b.step("test", "Run tests").dependOn(&test_step.step);
}
