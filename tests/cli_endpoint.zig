const std = @import("std");
const H = @import("cli_support.zig");
const Fixture = @import("cli_fixture.zig").Fixture;
/// Chrome belongs to this fixture. The CLI only borrows its advertised endpoint.
const External = struct {
    c: H.Context,
    profile: []const u8,
    endpoint: []const u8,
    websocket: []const u8,
    child: H.P.Child,
    log: H.Io.File,
    fn start(c: H.Context) !External {
        const profile = try c.path("external-profile");
        const downloads = try c.path("external-downloads");
        try c.dir(try c.a.print("{s}/Default", .{profile}));
        try c.dir(downloads);
        try c.write(try c.a.print("{s}/Default/Preferences", .{profile}), try c.json(.{ .download = .{ .default_directory = downloads, .prompt_for_download = false } }));
        try c.write(try c.a.print("{s}/keep", .{profile}), "external-owner");
        var executable: ?[]const u8 = null;
        for ([_][]const u8{ "/usr/bin/google-chrome", "/usr/bin/google-chrome-stable", "/usr/bin/chromium", "/usr/bin/chromium-browser" }) |candidate| {
            if (try c.exists(candidate)) {
                executable = candidate;
                break;
            }
        }
        const log_path = try c.path("external.stderr");
        const log = try H.Io.Dir.cwd().createFile(c.io, log_path, .{ .read = true });
        errdefer log.close(c.io);
        var child = try H.P.Child.spawn(std.heap.page_allocator, c.io, .{
            .argv = &.{ executable orelse return error.BrowserNotFound, "--headless=new", "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0", try c.a.print("--user-data-dir={s}", .{profile}), "--no-first-run", "--no-default-browser-check", "about:blank" },
            .stdout = .{ .file = log },
            .stderr = .{ .file = log },
        });
        errdefer {
            _ = child.stop(10000) catch {};
            child.deinit();
        }
        errdefer H.printLog(c, log_path);
        const active = try c.a.print("{s}/DevToolsActivePort", .{profile});
        try H.S.readiness.file(c.io, .{ .path = active, .timeout_ms = 10000, .child = &child });
        const data = try H.S.files.read(c.a, c.io, .{ .path = active, .limit = 4096 });
        var lines = std.mem.splitScalar(u8, data, '\n');
        const port = try std.fmt.parseInt(u16, lines.next() orelse return error.InvalidEndpoint, 10);
        const path = lines.next() orelse return error.InvalidEndpoint;
        try H.check(port > 0 and std.mem.startsWith(u8, path, "/devtools/browser/"), "external endpoint advertised by owned Chrome");
        return .{ .c = c, .profile = profile, .endpoint = try c.a.print("http://127.0.0.1:{d}", .{port}), .websocket = try c.a.print("ws://127.0.0.1:{d}{s}", .{ port, path }), .child = child, .log = log };
    }
    fn deinit(self: *External) void {
        _ = self.child.stop(10000) catch |err| std.debug.print("External fixture cleanup: {s}\n", .{@errorName(err)});
        self.child.deinit();
        self.log.close(self.c.io);
    }
};
fn targetMap(c: H.Context, tabs: H.V) !H.V {
    var map: std.json.ObjectMap = .empty;
    for (tabs.array.items) |tab| try map.put(c.a, try H.str(tab, "id"), try H.field(tab, "url"));
    return .{ .object = map };
}
pub fn run(c: H.Context) !void {
    var browser = try External.start(c);
    defer browser.deinit();
    var fixture: Fixture = .{};
    try fixture.start(c);
    defer fixture.deinit();
    const endpoint: H.Client = .{ .c = c, .target = browser.endpoint, .endpoint = true };
    const websocket: H.Client = .{ .c = c, .target = browser.websocket, .endpoint = true };
    const original = try targetMap(c, try endpoint.result(&.{"tabs"}));
    try H.equal(try H.field(try websocket.result(&.{"status"}), "ownership"), "external");
    const invalid: H.Client = .{ .c = c, .target = "http://example.invalid:9239", .endpoint = true };
    _ = try invalid.failure(&.{"tabs"}, "InvalidEndpoint");
    _ = try endpoint.failure(&.{ "eval", "true" }, "MissingTab");
    const origin = try fixture.origin(c);
    const new = try H.str(try endpoint.result(&.{ "new-tab", origin }), "id");
    const page: H.Client = .{ .c = c, .target = browser.endpoint, .endpoint = true, .tab = new };
    const url = try c.a.print("{s}/", .{origin});
    try page.expect(&.{ "open", url }, url);
    _ = try page.run(&.{"reload"}, .{});
    try page.expect(&.{ "eval", "document.title" }, "Fixture");
    const geometry = try page.result(&.{ "eval", "({w:innerWidth,h:innerHeight,dpr:devicePixelRatio})" });
    try @import("cli_agent.zig").exercise(page, try c.a.print("{s}/download", .{origin}));
    try H.equal(try page.result(&.{ "eval", "({w:innerWidth,h:innerHeight,dpr:devicePixelRatio})" }), geometry);
    try page.expect(&.{ "eval", "typeof window.__cdp" }, "undefined");
    _ = try page.result(&.{ "content", "<a id=\"blob\" download=\"blob.txt\">Blob</a>" });
    _ = try page.result(&.{ "eval", "document.querySelector('#blob').href=URL.createObjectURL(new Blob(['blob-bytes'])); true" });
    const blob = try c.path("blob-copy.txt");
    _ = try page.result(&.{ "download", "--selector", "#blob", blob, "--timeout", "3000" });
    try c.bytes(blob, "blob-bytes");
    for ([_]std.os.linux.SIG{ .INT, .TERM }) |sig| {
        var pending = try H.Pending.start(c, "endpoint-client", &.{ "--endpoint", browser.endpoint, "wait", "false", "--tab", new });
        defer pending.deinit();
        try c.io.sleep(.fromMilliseconds(100), .awake);
        try pending.child.signal(sig);
        try pending.failed(5000);
        try H.check(try browser.child.poll() == null, "interrupted borrower preserves external Chrome");
        try page.expect(&.{ "eval", "6*7" }, 42);
    }
    const started = H.Io.Clock.awake.now(c.io).toMilliseconds();
    const timed = try page.run(&.{ "eval", "new Promise(()=>{})", "--timeout", "100" }, .{ .ok = false, .timeout_ms = 10000 });
    const code = try H.field(timed, "err");
    try H.check(H.is(code, "Timeout") or H.is(code, "CommandTimeout"), "external command timeout code");
    try H.equal(try H.field(try H.field(timed, "error"), "action"), "possibly_dispatched");
    try H.check(H.Io.Clock.awake.now(c.io).toMilliseconds() - started < 2000, "external command bounded deadline");
    try page.expect(&.{ "eval", "6*7" }, 42);
    _ = try endpoint.run(&.{"close"}, .{});
    try H.check(try browser.child.poll() == null, "close borrower preserves external Chrome");
    _ = try endpoint.run(&.{ "close-tab", "--tab", new }, .{});
    try H.equal(try targetMap(c, try endpoint.result(&.{"tabs"})), original);
    try c.bytes(try c.a.print("{s}/keep", .{browser.profile}), "external-owner");
    fixture.server.stopAndJoin();
    try H.check(fixture.server.snapshot().first_error == null, "external HTTP fixture clean");
}
