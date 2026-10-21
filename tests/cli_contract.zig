const std = @import("std");
const H = @import("cli_support.zig");
const Fixture = @import("cli_fixture.zig").Fixture;
pub fn run(c: H.Context) !void {
    const report = try H.S.command.runReport(std.heap.page_allocator, c.io, .{ .run = .{ .spawn = .{ .argv = &.{ c.exe, "--help" } }, .stdout_limit = 65536, .stderr_limit = 65536, .timeout_ms = 5000 } });
    defer report.deinit(std.heap.page_allocator);
    try H.S.Diagnostic.expectExit(report, .{ .assertion = "CLI help", .code = 0 });
    try H.check(std.mem.indexOf(u8, report.stdout, "--session") != null, "help describes sessions");
    var server = try H.Session.start(c, "primary", &.{});
    defer server.deinit();
    var peer = try H.Session.start(c, "peer", &.{});
    defer peer.deinit();
    const client: H.Client = .{ .c = c, .target = server.path };
    try H.S.files.expectMode(c.io, .{ .path = server.path, .mode = 0o700 });
    try H.equal(try H.field(try client.result(&.{"status"}), "url"), "about:blank");
    const negatives = [_]struct { args: []const []const u8, code: []const u8 }{
        .{ .args = &.{"serve"}, .code = "PathAlreadyExists" },                                   .{ .args = &.{"unknown"}, .code = "UnknownCommand" },
        .{ .args = &.{ "fill", "#input" }, .code = "WrongArgumentCount" },                       .{ .args = &.{ "allow", "https://example.invalid/path" }, .code = "InvalidOrigin" },
        .{ .args = &.{ "allow", "http://user:pass@example.invalid" }, .code = "InvalidOrigin" }, .{ .args = &.{ "timeout", "0" }, .code = "InvalidTimeout" },
        .{ .args = &.{ "open", "https://example.invalid/" }, .code = "OriginNotAllowed" },
    };
    for (negatives) |n| _ = try client.failure(n.args, n.code);
    try H.equal(try H.field(try c.raw(server.path, "not json\n"), "err"), "InvalidRequest");
    try H.equal(try H.field(try c.raw(server.path, "{\"command\":\"eval\",\"args\":[4]}\n"), "err"), "InvalidRequest");
    const oversized = try c.a.alloc(u8, 1024 * 1024 + 2);
    @memset(oversized, 'x');
    oversized[oversized.len - 1] = '\n';
    try H.equal(try H.field(try c.raw(server.path, oversized), "err"), "MessageTooLarge");
    _ = try client.result(&.{ "content", @embedFile("fixtures/contract.html") });
    const text = "A \"quoted\" value\nwith Unicode 🧭";
    try client.expect(&.{ "eval", try c.json(text) }, text);
    _ = try client.result(&.{ "fill", "#name", "Sample 🧭" });
    _ = try client.result(&.{ "click", "#save" });
    try client.expect(&.{ "text", "#result" }, "Sample 🧭");
    try client.expect(&.{ "eval", "events" }, [_]bool{ true, true });
    _ = try client.result(&.{ "wait", "document.querySelector('#result').textContent === 'Sample 🧭'" });
    try H.equal(try c.command(peer.path, &.{ "eval", "typeof window.events" }), "undefined");
    _ = try client.run(&.{ "screenshot", "shot.png" }, .{ .cwd = c.root });
    _ = try H.S.png.dimensions(try c.read(try c.path("shot.png")));
    try c.write(try c.path("input.csv"), "header\nvalue\n");
    _ = try client.run(&.{ "upload", "#file", "input.csv" }, .{ .cwd = c.root });
    try client.expect(&.{ "eval", "document.querySelector('#file').files[0].text()" }, "header\nvalue\n");
    const download = try H.field(try client.run(&.{ "download", "#export", "out.csv" }, .{ .cwd = c.root }), "result");
    try H.equal(try H.field(download, "filename"), "fixture.csv");
    try H.equal(try H.field(download, "bytes"), 13);
    try c.bytes(try c.path("out.csv"), "exact,bytes\r\n");
    _ = try client.result(&.{ "timeout", "150" });
    _ = try client.failure(&.{ "click", "#disabled" }, "ElementNotActionable");
    _ = try client.failure(&.{ "wait", "false" }, "BrowserConditionTimeout");
    _ = try client.failure(&.{ "eval", "throw new Error('expected')" }, "BrowserEvaluationFailed");
    try client.expect(&.{ "eval", "6*7" }, 42);
    _ = try client.failure(&.{ "eval", "'x'.repeat(17*1024*1024)", "--timeout", "5000" }, "ResponseTooLarge");
    try client.expect(&.{ "eval", "true" }, true);
    _ = try client.result(&.{ "timeout", "30000" });
    var fixture: Fixture = .{};
    try fixture.start(c);
    defer fixture.deinit();
    const origin = try fixture.origin(c);
    const url = try c.a.print("{s}/", .{origin});
    _ = try client.result(&.{ "allow", origin });
    try client.expect(&.{ "open", url }, url);
    try client.expect(&.{ "text", "#message" }, "Local page");
    _ = try client.result(&.{"reload"});
    try client.expect(&.{ "eval", "document.title" }, "Fixture");
    fixture.background.store(false, .release);
    _ = try client.result(&.{ "eval", "setTimeout(() => fetch('/background'), 200); true" });
    try H.waitFlag(c.io, &fixture.background, 5000);
    try @import("cli_tabs.zig").exercise(&server, &fixture);
    try server.close();
    try H.equal(try c.command(peer.path, &.{ "eval", "true" }), true);
    try peer.close();
    fixture.server.stopAndJoin();
    try H.check(fixture.server.snapshot().first_error == null, "ordinary fixture has no hidden errors");
}
