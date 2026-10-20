const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("zig_cdp", .{ .target = b.graph.host, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "cdp", .module = dep.module("cdp") }},
    }) });
    b.step("test", "Check the public package").dependOn(&b.addRunArtifact(tests).step);
}
