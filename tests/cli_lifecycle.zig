const std = @import("std");
const H = @import("cli_support.zig");
const Fixture = @import("cli_fixture.zig").Fixture;
pub fn run(c: H.Context) !void {
    for ([_]std.os.linux.SIG{ .INT, .TERM }, 0..) |sig, index| {
        var server = try H.Session.start(c, try c.a.print("signal-{d}", .{index}), &.{});
        defer server.deinit();
        var pending = try H.Pending.start(c, "signal-client", &.{ "--session", server.path, "wait", "false" });
        defer pending.deinit();
        try c.io.sleep(.fromMilliseconds(100), .awake);
        try server.child.signal(sig);
        try server.done();
        try pending.failed(5000);
    }
    {
        var idle = try H.Session.start(c, "idle", &.{ "--idle-timeout", "1" });
        defer idle.deinit();
        try idle.done();
    }
    const collision = try c.path("occupied");
    try c.dir(collision);
    const marker = try c.a.print("{s}/keep", .{collision});
    try c.write(marker, "unrelated");
    try c.failure(collision, &.{"serve"}, "PathAlreadyExists");
    try c.bytes(marker, "unrelated");
    const failure = try c.path("failed-launch");
    for ([_]struct { executable: []const u8, code: []const u8 }{ .{ .executable = "/no/such/browser", .code = "FileNotFound" }, .{ .executable = "/bin/false", .code = "BrowserExited" } }) |row| {
        try c.failure(failure, &.{ "serve", "--browser", row.executable }, row.code);
        try H.check(!try c.exists(failure), "failed startup removes only owned session");
    }
    const profile = try c.path("saved-profile");
    try c.dir(profile);
    const keep = try c.a.print("{s}/keep", .{profile});
    try c.write(keep, "caller-owned");
    try c.dir(try c.a.print("{s}/downloads", .{profile}));
    const saved_download = try c.a.print("{s}/downloads/keep", .{profile});
    try c.write(saved_download, "saved download");
    var peer = try H.Session.start(c, "unrelated", &.{});
    defer peer.deinit();
    const stale = try c.read(try c.a.print("{s}/DevToolsActivePort", .{try H.str(peer.ready, "profile")}));
    const active_port = try c.a.print("{s}/DevToolsActivePort", .{profile});
    try c.write(active_port, stale);
    for ([_]struct { executable: []const u8, code: []const u8 }{ .{ .executable = "/no/such/browser", .code = "FileNotFound" }, .{ .executable = "/bin/false", .code = "BrowserExited" } }) |row| {
        try c.failure(failure, &.{ "serve", "--user-data-dir", profile, "--browser", row.executable }, row.code);
        try H.check(!try c.exists(failure), "saved-profile failed startup removes session");
        try c.bytes(keep, "caller-owned");
        try c.bytes(active_port, stale);
        try H.equal(try c.command(peer.path, &.{ "eval", "6*7" }), 42);
    }
    var fixture: Fixture = .{};
    try fixture.start(c);
    defer fixture.deinit();
    const origin = try fixture.origin(c);
    for (0..2) |index| {
        var server = try H.Session.start(c, try c.a.print("saved-{d}", .{index}), &.{ "--user-data-dir", profile, "--allow", origin });
        defer server.deinit();
        const client: H.Client = .{ .c = c, .target = server.path };
        try H.equal(try H.field(server.ready, "profile"), profile);
        try H.equal(try H.field(server.ready, "persistent_profile"), true);
        try H.check((try H.field(server.ready, "port")).integer != (try H.field(peer.ready, "port")).integer, "saved profile uses independent endpoint");
        try H.check((try server.pages()).len == 1, "one saved-profile startup page");
        try c.failure(failure, &.{ "serve", "--user-data-dir", profile }, "ProfileInUse");
        try H.check(!try c.exists(failure), "busy profile creates no session");
        try H.check((try server.pages()).len == 1, "busy-profile rejection preserves page count");
        _ = try client.result(&.{ "open", try c.a.print("{s}/", .{origin}) });
        if (index == 0) {
            try @import("cli_tabs.zig").exercise(&server, &fixture);
            _ = try client.result(&.{ "eval", "localStorage.setItem('saved','fixture'); document.cookie='saved=fixture; Max-Age=3600; SameSite=Lax'; true" });
            _ = try client.result(&.{ "eval", "const a=document.createElement('a'); a.id='export'; a.href='data:text/plain,saved-profile-download'; a.download='saved.txt'; a.textContent='Download'; document.body.append(a); true" });
            const destination = try c.path("saved.txt");
            _ = try client.result(&.{ "download", "#export", destination });
            try c.bytes(destination, "saved-profile-download");
            _ = try client.result(&.{"close"});
        } else {
            try client.expect(&.{ "eval", "localStorage.getItem('saved')" }, "fixture");
            try client.expect(&.{ "eval", "document.cookie.includes('saved=fixture')" }, true);
            try server.child.signal(.TERM);
        }
        try server.done();
        try c.bytes(keep, "caller-owned");
        try c.bytes(saved_download, "saved download");
        try H.check(!try isSymlink(c, try c.a.print("{s}/SingletonLock", .{profile})), "released saved-profile lock");
    }
    try H.equal(try c.command(peer.path, &.{ "eval", "true" }), true);
    try peer.close();
    const lock = try c.a.print("{s}/SingletonLock", .{profile});
    try H.Io.Dir.cwd().symLink(c.io, "stale-host-12345", lock, .{});
    try c.failure(failure, &.{ "serve", "--user-data-dir", profile }, "ProfileInUse");
    try H.S.files.expectSymlink(c.io, .{ .path = lock, .target = "stale-host-12345" });
    try H.check(!try c.exists(failure), "stale lock creates no session");
    try c.failure(failure, &.{ "serve", "--user-data-dir", try c.path("missing-profile") }, "FileNotFound");
    try H.check(!try c.exists(failure), "missing profile creates no session");
    fixture.server.stopAndJoin();
    try H.check(fixture.server.snapshot().first_error == null, "profile fixture clean");
}
fn isSymlink(c: H.Context, path: []const u8) !bool {
    const stat = H.Io.Dir.cwd().statFile(c.io, path, .{ .follow_symlinks = false }) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    return stat.kind == .sym_link;
}
