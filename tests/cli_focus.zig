//! Run only inside the build's private Xvfb/Openbox display.
const std = @import("std");
const H = @import("cli_support.zig");

fn activeWindow(c: H.Context) ![]const u8 {
    const report = try H.S.command.runReport(std.heap.page_allocator, c.io, .{ .run = .{
        .spawn = .{ .argv = &.{ "/usr/bin/xprop", "-root", "_NET_ACTIVE_WINDOW" } },
        .stdout_limit = 4096,
        .stderr_limit = 4096,
        .timeout_ms = 3000,
    } });
    defer report.deinit(std.heap.page_allocator);
    errdefer std.debug.print("xprop: {s}; {s}; {any}; {s}\n", .{ report.stdout, report.stderr, report.term, @tagName(report.outcome) });
    try H.check(report.outcome == .completed and report.term != null and report.term.? == .exited and report.term.?.exited == 0, "native focus observation succeeds");
    try H.check(std.mem.indexOf(u8, report.stdout, "window id # 0x") != null and std.mem.indexOf(u8, report.stdout, "window id # 0x0\n") == null, "window manager publishes an active window");
    return c.a.dupe(u8, report.stdout);
}

fn unchanged(c: H.Context, window: []const u8, sentinel: H.Client, original: H.Client) !void {
    try H.equal(.{ .string = try activeWindow(c) }, window);
    try sentinel.expect(&.{ "eval", "document.hasFocus()" }, true);
    try original.expect(&.{ "eval", "document.visibilityState" }, "visible");
    try original.expect(&.{ "eval", "document.querySelector('input').value" }, "unsaved");
}

pub fn run(c: H.Context) !void {
    const launcher = try c.path("chrome-x11");
    try c.write(launcher, "#!/bin/sh\nexec /usr/bin/google-chrome --ozone-platform=x11 --disable-gpu --window-position=0,0 --window-size=700,700 \"$@\"\n");
    const f = try H.Io.Dir.cwd().openFile(c.io, launcher, .{});
    try f.setPermissions(c.io, .fromMode(0o700));
    f.close(c.io);
    const profile = try c.path("primary-profile");
    const front_launcher = try c.path("chrome-front");
    try c.write(front_launcher, "#!/bin/sh\nexec /usr/bin/google-chrome --ozone-platform=x11 --disable-gpu --window-position=800,0 --window-size=700,700 \"$@\"\n");
    const ff = try H.Io.Dir.cwd().openFile(c.io, front_launcher, .{});
    try ff.setPermissions(c.io, .fromMode(0o700));
    ff.close(c.io);
    const sentinel_profile = try c.path("sentinel-profile");
    try c.dir(profile);
    try c.dir(sentinel_profile);
    var owner = try H.Session.start(c, "primary", &.{ "--headed", "--browser", launcher, "--user-data-dir", profile });
    defer owner.deinit();
    const own: H.Client = .{ .c = c, .target = owner.path };
    const endpoint: H.Client = .{ .c = c, .target = try owner.browserUrl(""), .endpoint = true };
    const original_id = try H.str(try own.result(&.{"status"}), "tab_id");
    const original: H.Client = .{ .c = c, .target = endpoint.target, .endpoint = true, .tab = original_id };
    _ = try original.result(&.{ "content", "<title>Original</title><input value=unsaved>" });
    const geometry = try original.result(&.{ "eval", "({w:innerWidth,h:innerHeight,dpr:devicePixelRatio})" });
    var front = try H.Session.start(c, "foreground", &.{ "--headed", "--browser", front_launcher, "--user-data-dir", sentinel_profile });
    defer front.deinit();
    const sentinel: H.Client = .{ .c = c, .target = front.path };
    _ = try sentinel.result(&.{ "content", "<title>Foreground sentinel</title><p>Keep this window active</p>" });
    _ = try sentinel.result(&.{ "wait", "document.hasFocus()" });
    const window = try activeWindow(c);
    try unchanged(c, window, sentinel, original);
    for ([_]H.Client{ own, endpoint }) |client| {
        const id = try H.str(try client.result(&.{ "new-tab", "--background" }), "id");
        try unchanged(c, window, sentinel, original);
        const page: H.Client = .{ .c = c, .target = client.target, .endpoint = client.endpoint, .tab = id };
        _ = try page.result(&.{ "content", "<input id=name><button onclick=\"document.querySelector('output').textContent=document.querySelector('input').value\">Save</button><output></output>" });
        _ = try page.result(&.{ "fill", "#name", "background" });
        _ = try page.result(&.{ "click", "button" });
        try page.expect(&.{ "text", "output" }, "background");
        _ = try page.result(&.{"snapshot"});
        try unchanged(c, window, sentinel, original);
        for ([_][]const u8{ "--viewport", "--full-page" }) |mode| {
            _ = try page.result(&.{ "screenshot", mode, try c.path("background.png"), "--timeout", "3000" });
            try unchanged(c, window, sentinel, original);
        }
        _ = try page.failure(&.{ "click", "--selector", "#missing", "--timeout", "100" }, "ElementNotFound");
        try unchanged(c, window, sentinel, original);
        try @import("cli_input.zig").exercise(page);
        try unchanged(c, window, sentinel, original);
        if (!client.endpoint) {
            _ = try own.result(&.{ "switch-tab", original_id, "--background" });
            try H.equal(try H.field(try own.result(&.{"status"}), "tab_id"), original_id);
            _ = try own.result(&.{ "switch-tab", id, "--background" });
        } else {
            _ = try endpoint.failure(&.{ "switch-tab", id, "--background" }, "EndpointRequiresExplicitTab");
            // First owned attachment to an externally-created page is passive.
            _ = try own.result(&.{ "eval", "true", "--tab", id });
        }
        _ = try own.result(&.{ "close-tab", id });
        try unchanged(c, window, sentinel, original);
        try H.equal(try original.result(&.{ "eval", "({w:innerWidth,h:innerHeight,dpr:devicePixelRatio})" }), geometry);
    }
    var fixture: @import("cli_fixture.zig").Fixture = .{};
    try fixture.start(c);
    defer fixture.deinit();
    const origin = try fixture.origin(c);
    _ = try own.result(&.{ "allow", origin });
    const cross = try std.mem.replaceOwned(u8, c.a, origin, "127.0.0.1", "localhost");
    _ = try own.result(&.{ "allow", cross });
    for ([_]H.Client{ own, endpoint }) |client| {
        const id = try H.str(try client.result(&.{ "new-tab", "--background" }), "id");
        const page: H.Client = .{ .c = c, .target = client.target, .endpoint = client.endpoint, .tab = id };
        _ = try page.result(&.{ "open", origin });
        _ = try page.result(&.{ "content", try c.a.print("<iframe name=component src='{s}/frame-controls' style='width:500px;height:400px;border:5px solid'></iframe>", .{cross}) });
        var scoped = page;
        scoped.frame = try @import("cli_frames.zig").find(c, try page.result(&.{"frames"}), "component");
        try @import("cli_shadows.zig").exercise(scoped);
        try unchanged(c, window, sentinel, original);
        _ = try page.result(&.{ "screenshot", "--viewport", try c.path("frame-shadow.png") });
        try unchanged(c, window, sentinel, original);
        _ = try own.result(&.{ "close-tab", id });
    }
    for ([_]H.Client{ own, endpoint }, 0..) |client, i| {
        const task = try @import("cli_workflow.zig").exercise(client, origin, try c.a.print("headed-complete-{d}", .{i}));
        try unchanged(c, window, sentinel, original);
        try H.equal(try original.result(&.{ "eval", "({w:innerWidth,h:innerHeight,dpr:devicePixelRatio})" }), geometry);
        _ = try own.result(&.{ "close-tab", task });
    }
    _ = try own.result(&.{ "allow", "http://127.0.0.1:1" });
    _ = try own.failure(&.{ "new-tab", "http://127.0.0.1:1/", "--background" }, "NavigationFailed");
    try unchanged(c, window, sentinel, original);
    const external = try H.str(try endpoint.result(&.{ "new-tab", "--background" }), "id");
    _ = try own.result(&.{ "switch-tab", external, "--background" });
    _ = try endpoint.result(&.{ "close-tab", external });
    _ = try own.result(&.{"status"});
    try unchanged(c, window, sentinel, original);
    _ = try own.result(&.{"close-tab"}); // Last-tab replacement stays behind sentinel.
    try H.equal(.{ .string = try activeWindow(c) }, window);
    try sentinel.expect(&.{ "eval", "document.hasFocus()" }, true);
    try owner.close();
    try front.close();
}
