const std = @import("std");
const H = @import("cli_support.zig");
const Observe = @import("cli_observe.zig");
const Fixture = @import("cli_fixture.zig").Fixture;
pub fn exercise(client: H.Client, origin: []const u8, name: []const u8) ![]const u8 {
    const c = client.c;
    const id = try H.str(try client.result(&.{ "new-tab", "--background" }), "id");
    var page = client;
    page.tab = id;
    const capture = try c.path(try c.a.print("{s}-workflow.jsonl", .{name}));
    var observer = try Observe.start(page, name, &.{ "--out", capture, "--duration", "12000", "--body-method", "POST", "--body-url", try c.a.print("{s}/api/save", .{origin}) });
    defer observer.deinit();
    try Observe.ready(c, &observer);
    _ = try page.result(&.{ "open", try c.a.print("{s}/workflow", .{origin}) });
    const snapshot = try page.result(&.{"snapshot"});
    try H.check((try H.field(snapshot, "returned_nodes")).integer > 0, "workflow controls inspected");
    _ = try page.result(&.{ "fill", "--role", "textbox", "--name", "Name", "--value", "Ada" });
    _ = try page.result(&.{ "click", "--role", "button", "--name", "Save" });
    _ = try page.result(&.{ "wait", "--text", "Saved Ada", "--timeout", "3000" });
    _ = try page.result(&.{ "drag", "#card", "#drop", "--hold", "150", "--steps", "8" });
    try page.expect(&.{ "text", "#sorted" }, "Moved");
    try page.expect(&.{ "eval", "trusted" }, true);
    const first = try c.path("workflow first.txt");
    const second = try c.path("workflow другий.txt");
    try c.write(first, "one");
    try c.write(second, "two");
    _ = try page.result(&.{ "upload", "--selector", "#files", "--file", first, "--file", second });
    _ = try page.result(&.{ "wait", "--text", "one|two", "--timeout", "3000" });
    const download = try c.path(try c.a.print("{s}-artifact.txt", .{name}));
    _ = try page.result(&.{ "download", "#download", download, "--timeout", "5000" });
    try c.bytes(download, "agent-download");
    _ = try page.result(&.{"reload"});
    _ = try page.result(&.{ "screenshot", try c.path(try c.a.print("{s}-workflow.png", .{name})), "--full-page", "--timeout", "3000" });
    _ = try Observe.finish(c, &observer, true);
    const log = try c.read(capture);
    var lines = std.mem.splitScalar(u8, log, '\n');
    var request_id: ?[]const u8 = null;
    var saved = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const record = try c.parse(line);
        const data = try H.field(record, "data");
        if (H.is(try H.field(record, "kind"), "request") and H.is(try H.field(data, "method"), "POST")) request_id = try H.str(data, "request_id");
        if (H.is(try H.field(record, "kind"), "body")) {
            try H.equal(try H.field(data, "request_id"), request_id.?);
            try H.equal(try H.field(data, "availability"), "complete");
            try H.equal(try H.field(try c.parse(try H.str(data, "text")), "saved"), true);
            saved = true;
        }
    }
    try H.check(saved, "actual save response verified by request ID");
    if (client.endpoint) _ = try client.result(&.{"close"});
    return id;
}
pub fn run(c: H.Context) !void {
    var fixture: Fixture = .{};
    try fixture.start(c);
    defer fixture.deinit();
    const origin = try fixture.origin(c);
    var owner = try H.Session.start(c, "workflow-owner", &.{ "--allow", origin });
    defer owner.deinit();
    const owned: H.Client = .{ .c = c, .target = owner.path };
    const original = try H.str(try owned.result(&.{"status"}), "tab_id");
    _ = try owned.result(&.{ "content", "<input value=unsaved>" });
    _ = try exercise(owned, origin, "owned-complete");
    try owned.expect(&.{ "eval", "document.querySelector('input').value", "--tab", original }, "unsaved");
    var external = try @import("cli_endpoint.zig").External.start(c);
    defer external.deinit();
    const endpoint: H.Client = .{ .c = c, .target = external.endpoint, .endpoint = true };
    const tabs = try endpoint.result(&.{"tabs"});
    const sentinel_id = try H.str(tabs.array.items[0], "id");
    const sentinel: H.Client = .{ .c = c, .target = external.endpoint, .endpoint = true, .tab = sentinel_id };
    _ = try sentinel.result(&.{ "content", "<input value=unsaved>" });
    const geometry = try sentinel.result(&.{ "eval", "({w:innerWidth,h:innerHeight,dpr:devicePixelRatio})" });
    _ = try exercise(endpoint, origin, "external-complete");
    try sentinel.expect(&.{ "eval", "document.querySelector('input').value" }, "unsaved");
    try H.equal(try sentinel.result(&.{ "eval", "({w:innerWidth,h:innerHeight,dpr:devicePixelRatio})" }), geometry);
    try H.check(try external.child.poll() == null, "complete workflow leaves borrowed browser alive");
    try c.bytes(try c.a.print("{s}/keep", .{external.profile}), "external-owner");
    try owner.close();
}
