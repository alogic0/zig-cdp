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
    const cli_tests = b.addSystemCommand(&.{"python3"});
    cli_tests.addFileArg(b.path("tests/cli.py"));
    cli_tests.addArtifactArg(cli);
    b.step("test-cli", "Run CLI session acceptance tests (requires Python 3)").dependOn(&cli_tests.step);
}
