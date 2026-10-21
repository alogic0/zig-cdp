const std = @import("std");

pub fn build(b: *std.Build) void {
    const version = std.mem.trim(u8, @embedFile(".zigversion"), " \t\r\n");
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, version))
        @panic("use the Zig compiler pinned in .zigversion");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    if (target.result.os.tag != .linux) @panic("zig-cdp currently supports Linux only");
    const process = b.dependency("process", .{ .target = target, .optimize = optimize });
    const cdp = b.addModule("cdp", .{
        .root_source_file = b.path("src/cdp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "process", .module = process.module("process") }},
    });
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/cdp_journey_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "process", .module = process.module("process") }},
    }) });
    b.step("test", "Run native CDP and owned-browser tests").dependOn(&b.addRunArtifact(tests).step);
    const example = b.addExecutable(.{
        .name = "cdp-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "cdp", .module = cdp }},
        }),
    });
    b.step("example", "Run an in-memory browser fixture").dependOn(&b.addRunArtifact(example).step);
    const check = b.step("check", "Compile library tests and example");
    check.dependOn(&tests.step);
    check.dependOn(&example.step);
    const cli = b.addExecutable(.{
        .name = "zig-cdp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "cdp", .module = cdp }},
        }),
    });
    b.installArtifact(cli);
    check.dependOn(&cli.step);
    const native_cli_tests = b.addExecutable(.{
        .name = "cli-acceptance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "test_support", .module = b.dependency("test_support", .{ .target = target, .optimize = optimize }).module("test_support") },
                .{ .name = "http_fixture", .module = b.dependency("http_fixture", .{ .target = target, .optimize = optimize }).module("http_fixture") },
            },
        }),
    });
    const native_run = b.addRunArtifact(native_cli_tests);
    native_run.addArtifactArg(cli);
    native_run.addPassthruArgs();
    native_run.has_side_effects = true;
    b.step("test-cli", "Run native CLI subprocess acceptance").dependOn(&native_run.step);
    const headed_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/cdp_headed_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "cdp", .module = cdp }},
    }) });
    // Keep graphical checks off the user's desktop, even in a Wayland session.
    const headed_run = b.addSystemCommand(&.{ "env", "-u", "WAYLAND_DISPLAY", "-u", "WAYLAND_SOCKET", "XDG_SESSION_TYPE=x11", "GDK_BACKEND=x11", "xvfb-run", "-a", "-s", "-screen 0 1600x1000x24" });
    if (b.option(bool, "headed-window-manager", "Run headed checks with Openbox inside Xvfb") orelse false) {
        headed_run.addArgs(&.{ "sh", "-c", "openbox --sm-disable >/dev/null 2>&1 & wm_pid=$!; trap 'kill \"$wm_pid\"; wait \"$wm_pid\"' EXIT; \"$@\"", "headed-test" });
    }
    headed_run.addArtifactArg(headed_tests);
    b.step("test-headed", "Check native viewport resizing (requires xvfb-run)").dependOn(&headed_run.step);
}
