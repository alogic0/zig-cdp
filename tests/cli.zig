const std = @import("std");
const H = @import("cli_support.zig");
const S = H.S;
const F = @import("http_fixture");
comptime {
    if (S.compiled_mode != @import("builtin").mode or F.compiled_mode != @import("builtin").mode) @compileError("CLI fixture/support profile mismatch");
}
fn foundation(c: H.Context) !void {
    const report = try S.command.runReport(std.heap.page_allocator, c.io, .{ .run = .{ .spawn = .{ .argv = &.{ c.exe, "--help" } }, .stdout_limit = 65536, .stderr_limit = 65536, .timeout_ms = 5000 } });
    defer report.deinit(std.heap.page_allocator);
    try S.Diagnostic.expectExit(report, .{ .assertion = "CLI help", .code = 0 });
    try H.check(std.mem.indexOf(u8, report.stdout, "--session") != null, "help describes sessions");
    var server = try H.Session.start(c, "primary", &.{});
    defer server.deinit();
    var peer = try H.Session.start(c, "peer", &.{});
    defer peer.deinit();
    try S.files.expectMode(c.io, .{ .path = server.path, .mode = 0o700 });
    try H.equal(try H.field(try c.command(server.path, &.{"status"}), "url"), "about:blank");
    try c.failure(server.path, &.{"serve"}, "PathAlreadyExists");
    try c.failure(server.path, &.{"unknown"}, "UnknownCommand");
    try c.failure(server.path, &.{ "fill", "#input" }, "WrongArgumentCount");
    _ = try c.command(server.path, &.{ "content", "<p id='x'>shared</p>" });
    try H.equal(try c.command(server.path, &.{ "text", "#x" }), "shared");
    try H.equal(try c.command(peer.path, &.{ "eval", "document.querySelector('#x') === null" }), true);
    try H.equal(try H.field(try c.raw(server.path, "not json\n"), "err"), "InvalidRequest");
    try server.close();
    try H.equal(try c.command(peer.path, &.{ "eval", "6*7" }), 42);
    try peer.close();
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args.next() orelse return error.MissingCli, init.arena.allocator());
    var workspace = try S.Workspace.init(init.gpa, init.io, .{ .prefix = "cdp-native-cli-" });
    defer workspace.close(.failure) catch |err| std.debug.print("Workspace cleanup: {s}\n", .{@errorName(err)});
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const c: H.Context = .{ .a = arena.allocator(), .io = init.io, .exe = exe, .root = workspace.path, .scenario = "foundation" };
    std.debug.print("CLI acceptance native={s} support={s} http={s} compiler={s}\n", .{ @tagName(@import("builtin").mode), @tagName(S.compiled_mode), @tagName(F.compiled_mode), @import("builtin").zig_version_string });
    try foundation(c);
    try workspace.close(.success);
    std.debug.print("PASS foundation: real subprocesses, readiness, shared state, independent sessions and cleanup\n", .{});
}
