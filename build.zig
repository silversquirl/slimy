const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("slimy", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
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

    const web = b.addInstallDirectory(.{
        .source_dir = "web",
        .install_dir = .prefix,
        .install_subdir = "web",
    });
    web.step.dependOn(&b.addInstallArtifact(wasm).step);

    const web_step = b.step("web", "Build web UI");
    web_step.dependOn(&web.step);
}
