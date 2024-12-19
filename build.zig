const std = @import("std");

const slimy_version = std.SemanticVersion.parse("0.1.0-dev") catch @panic("Parse error");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const singlethread = b.option(bool, "singlethread", "Build in single-threaded mode") orelse false;
    const strip = b.option(bool, "strip", "Strip debug info from binaries") orelse false;
    const suffix = b.option(bool, "suffix", "Suffix binary names with version and target") orelse false;
    const timestamp = b.option(bool, "timestamp", "Include build timestamp in version information") orelse false;
    const glslc = b.option([]const u8, "glslc", "Specify the path to the glslc binary") orelse "glslc";

    const shader_compile = b.addSystemCommand(&.{ glslc, "-o" });
    const shader_spv = shader_compile.addOutputFileArg("search.spv");
    shader_compile.addFileArg(b.path("src/shader/search.comp"));

    var version = slimy_version;
    if (version.pre != null) {
        // Find git commit hash
        var code: u8 = undefined;
        if (b.runAllowFail(
            &.{ "git", "rev-parse", "--short", "HEAD" },
            &code,
            .Inherit,
        )) |commit| {
            version.build = std.mem.trimRight(u8, commit, "\n");

            // Add -dirty if we have uncommitted changes
            _ = b.runAllowFail(
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
        b.fmt("slimy-{}-{s}", .{ version, target.query.zigTriple(b.allocator) catch @panic("OOM") })
    else
        "slimy";
    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = singlethread,
        .strip = strip,
        .linkage = .dynamic,
    });
    exe.root_module.addImport("build_consts", consts.createModule());
    exe.root_module.addImport("optz", b.dependency("optz", .{}).module("optz"));
    exe.root_module.addImport("cpuinfo", b.dependency("cpuinfo", .{}).module("cpuinfo"));
    exe.root_module.addImport("zcompute", b.dependency("zcompute", .{}).module("zcompute"));
    exe.root_module.addImport("search_spv", b.createModule(.{ .root_source_file = shader_spv }));

    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = singlethread,
    });
    tests.linkLibC();

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const wasm = b.addSharedLibrary(.{
        .name = "slimy",
        .root_source_file = b.path("src/web.zig"),
        .target = b.resolveTargetQuery(std.Build.parseTargetQuery(.{
            .arch_os_abi = "wasm32-freestanding",
        }) catch unreachable),
        .optimize = optimize,
        .single_threaded = true,
    });

    const web = b.addInstallDirectory(.{
        .source_dir = b.path("web"),
        .install_dir = .prefix,
        .install_subdir = "web",
    });
    web.step.dependOn(&b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
    }).step);

    const web_step = b.step("web", "Build web UI");
    web_step.dependOn(&web.step);
}
