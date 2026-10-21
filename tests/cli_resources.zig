const std = @import("std");
const H = @import("cli_support.zig");
const Fixture = @import("cli_fixture.zig").Fixture;
fn request(c: H.Context, session: []const u8, input: anytype) !H.V {
    const value = try c.request(session, input);
    try H.equal(try H.field(value, "ok"), true);
    return H.field(value, "result");
}
pub fn run(c: H.Context) !void {
    {
        var server = try H.Session.start(c, "resources", &.{});
        defer server.deinit();
        const owner_pid = server.child.pid.?;
        const item = "resource fixture ";
        const repeated = try c.a.alloc(u8, item.len * 2000);
        for (0..2000) |index| @memcpy(repeated[index * item.len ..][0..item.len], item);
        const html = try c.a.print("<button>Save</button><p>{s}</p>", .{repeated});
        _ = try request(c, server.path, .{ .command = "content", .args = .{html} });
        for (0..12) |_| {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            var scope = c;
            scope.a = arena.allocator();
            _ = try request(scope, server.path, .{ .command = "snapshot", .args = .{} });
            _ = try request(scope, server.path, .{ .command = "eval", .args = .{"'x'.repeat(512*1024)"} });
        }
        const before = try H.S.resources.measure(c.a, c.io, owner_pid);
        for (0..3) |_| {
            for (0..80) |_| {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                var scope = c;
                scope.a = arena.allocator();
                _ = try request(scope, server.path, .{ .command = "snapshot", .args = .{} });
                _ = try request(scope, server.path, .{ .command = "read", .args = .{} });
                _ = try request(scope, server.path, .{ .command = "eval", .args = .{"'x'.repeat(512*1024)"} });
            }
            for (0..12) |_| {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                var scope = c;
                scope.a = arena.allocator();
                const tab = try H.str(try request(scope, server.path, .{ .command = "new-tab", .args = .{} }), "id");
                _ = try request(scope, server.path, .{ .command = "content", .args = .{"<input aria-label='Name'>"}, .tab = tab });
                _ = try request(scope, server.path, .{ .command = "close-tab", .args = .{tab} });
            }
        }
        const after = try H.S.resources.measure(c.a, c.io, owner_pid);
        std.debug.print("RESOURCE warmup=24 inspections=720 tab_cycles=36 rss_bytes={d}->{d} descriptors={d}->{d}\n", .{ before.rss_bytes, after.rss_bytes, before.descriptors, after.descriptors });
        try H.check(@as(i128, after.rss_bytes) - @as(i128, before.rss_bytes) < 32 * 1024 * 1024, "owner RSS growth below 32 MiB");
        try H.check(after.descriptors <= before.descriptors + 3, "owner descriptors at most baseline plus three");
        _ = try request(c, server.path, .{ .command = "content", .args = .{"<a id='d' download='a.txt' href='data:text/plain,owned'>Download</a>"} });
        const staging = try c.a.print("{s}/downloads", .{try H.str(server.ready, "profile")});
        for (0..5) |index| {
            const output = try c.path(try c.a.print("resource-{d}.txt", .{index}));
            _ = try request(c, server.path, .{ .command = "download", .args = .{ "#d", output } });
            try c.bytes(output, "owned");
            try c.empty(staging);
        }
        _ = try request(c, server.path, .{ .command = "click", .args = .{"#d"} });
        try c.io.sleep(.fromMilliseconds(100), .awake);
        try c.empty(staging);
        for (0..128) |index| _ = try request(c, server.path, .{ .command = "allow", .args = .{try c.a.print("http://site-{d}.invalid", .{index})} });
        const limit = try c.request(server.path, .{ .command = "allow", .args = .{"http://overflow.invalid"} });
        try H.equal(try H.field(limit, "err"), "OriginLimitExceeded");
        const oversized = try H.field(try c.request(server.path, .{ .command = "eval", .args = .{"'x'.repeat(17*1024*1024)"}, .timeout_ms = 5000 }), "error");
        try H.equal(try H.field(oversized, "phase"), "output");
        try H.equal(try H.field(oversized, "action"), "completed");
        try H.equal(try request(c, server.path, .{ .command = "eval", .args = .{"42"} }), 42);
        const invalid = try c.invoke(&.{ "--session", server.path, "click", "--role", "button", "--text", "Save" }, .{ .ok = false });
        try H.equal(try H.field(try H.field(invalid, "error"), "phase"), "validate");
        try H.equal(try H.field(invalid, "command"), "click");
        _ = try request(c, server.path, .{ .command = "close", .args = .{} });
        try server.done();
    }
    {
        var fixture: Fixture = .{};
        try fixture.start(c);
        defer fixture.deinit();
        const origin = try fixture.origin(c);
        var server = try H.Session.start(c, "download-cancellation", &.{ "--allow", origin });
        defer server.deinit();
        const client: H.Client = .{ .c = c, .target = server.path };
        for ([_]struct { path: []const u8, budget: []const u8, code: []const u8 }{ .{ .path = "slow-download", .budget = "400", .code = "DownloadTimeout" }, .{ .path = "large-download", .budget = "3000", .code = "DownloadTooLarge" } }) |row| {
            fixture.download_closed.store(false, .release);
            fixture.download_started.store(false, .release);
            _ = try client.result(&.{ "content", try c.a.print("<a id='stream' download href='{s}/{s}'>Download</a>", .{ origin, row.path }) });
            _ = try client.failure(&.{ "download", "#stream", try c.path("stream.bin"), "--timeout", row.budget }, row.code);
            try H.check(fixture.download_started.load(.acquire), "download request reached fixture");
            try H.waitFlag(c.io, &fixture.download_closed, 2000);
            try c.empty(try c.a.print("{s}/downloads", .{try H.str(server.ready, "profile")}));
            try client.expect(&.{ "eval", "42" }, 42);
        }
        try server.close();
        fixture.server.stopAndJoin();
        const snapshot = fixture.server.snapshot();
        try H.check(snapshot.active == 0 and snapshot.active_handlers == 0, "stream handlers joined");
        try H.check(snapshot.failures == 2 and snapshot.first_error != null and snapshot.first_error.? == error.WriteFailed, "only the two expected canceled-transfer writes failed");
    }
    {
        var server = try H.Session.start(c, "browser-exit", &.{});
        defer server.deinit();
        var pending = try H.Pending.start(c, "browser-exit-client", &.{ "--session", server.path, "wait", "false", "--timeout", "1000" });
        defer pending.deinit();
        try c.io.sleep(.fromMilliseconds(100), .awake);
        try H.check(try server.child.poll() == null, "session owner retained before browser-exit injection");
        // This PID is the browser advertised by our still-owned serve child.
        // Pin the signal target with a pidfd; never reap this indirect child.
        const linux = std.os.linux;
        const fd = linux.pidfd_open(@intCast((try H.field(server.ready, "pid")).integer), 0);
        if (linux.errno(fd) != .SUCCESS) return error.BrowserPidfdFailed;
        const file: H.Io.File = .{ .handle = @intCast(fd), .flags = .{ .nonblocking = false } };
        defer file.close(c.io);
        if (linux.errno(linux.pidfd_send_signal(file.handle, .KILL, null, 0)) != .SUCCESS) return error.BrowserSignalFailed;
        try pending.failed(3000);
        const failure = try c.parse(try c.read(pending.out_path));
        try H.equal(try H.field(failure, "ok"), false);
        try H.equal(try H.field(try H.field(failure, "error"), "action"), "not_started");
        try server.close();
    }
}
