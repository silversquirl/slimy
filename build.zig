const std = @import("std");
const Deps = @import("Deps.zig");

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const singlethread = b.option(bool, "singlethread", "Build in single-threaded mode") orelse false;

    const shaders = b.addSystemCommand(&.{
        "glslc", "-o", "search.spv", "search.comp",
    });
    shaders.cwd = std.fs.path.join(b.allocator, &.{ b.build_root, "src", "shader" }) catch unreachable;

    const deps = Deps.init(b);
    deps.add("https://github.com/silversquirl/optz", "main");
    deps.add("https://github.com/silversquirl/zcompute", "main");

    const exe = b.addExecutable("slimy", "src/main.zig");
    deps.addTo(exe);
    exe.linkLibC();
    exe.step.dependOn(&shaders.step);
    exe.linkage = .dynamic;

    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.single_threaded = singlethread;
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const wasm = b.addSharedLibrary("slimy", "src/web.zig", .unversioned);
    wasm.setTarget(try std.zig.CrossTarget.parse(.{
        .arch_os_abi = "wasm32-freestanding",
    }));
    wasm.setBuildMode(mode);
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
}
