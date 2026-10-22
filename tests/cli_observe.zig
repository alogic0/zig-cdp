const std = @import("std");
const H = @import("cli_support.zig");
const Fixture = @import("cli_fixture.zig").Fixture;
pub fn ready(c: H.Context, pending: *H.Pending) !void {
    const end = H.Io.Clock.awake.now(c.io).addDuration(.fromSeconds(5));
    while (H.Io.Clock.awake.now(c.io).nanoseconds < end.nanoseconds) {
        const output = try c.read(pending.out_path);
        if (std.mem.indexOfScalar(u8, output, '\n')) |n| {
            const value = try c.parse(output[0..n]);
            try H.equal(try H.field(value, "ready"), true);
            return;
        }
        if (try pending.child.poll() != null) {
            H.printLog(c, pending.out_path);
            H.printLog(c, pending.err_path);
            return error.ObserverNotReady;
        }
        try c.io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.ObserverReadinessTimeout;
}
pub fn finish(c: H.Context, pending: *H.Pending, ok: bool) !H.V {
    const term = try pending.child.wait(15000);
    errdefer H.printLog(c, pending.out_path);
    try H.check(term == .exited and ((term.exited == 0) == ok), "observer exit matches completeness");
    const bytes = std.mem.trim(u8, try c.read(pending.out_path), "\n");
    const offset = if (std.mem.lastIndexOfScalar(u8, bytes, '\n')) |n| n + 1 else 0;
    const result = try c.parse(bytes[offset..]);
    try H.equal(try H.field(result, "ok"), ok);
    return result;
}
pub fn start(client: H.Client, name: []const u8, options: []const []const u8) !H.Pending {
    return H.Pending.start(client.c, name, try std.mem.concat(client.c.a, []const u8, &.{ &.{ if (client.endpoint) "--endpoint" else "--session", client.target, "observe", "--tab", client.tab.? }, options }));
}
fn exercise(client: H.Client, origin: []const u8, name: []const u8) !void {
    const c = client.c;
    const path = try c.path(try c.a.print("{s}.jsonl", .{name}));
    const url = try c.a.print("{s}/api/save?secret=private", .{origin});
    var observer = try start(client, name, &.{ "--out", path, "--duration", "12000", "--body-url", url, "--body-method", "POST" });
    defer observer.deinit();
    try ready(c, &observer);
    try H.S.files.expectMode(c.io, .{ .path = path, .mode = 0o600 });
    const geometry = try client.result(&.{ "eval", "({w:innerWidth,h:innerHeight,dpr:devicePixelRatio})" });
    _ = try client.result(&.{ "open", origin });
    _ = try client.result(&.{ "eval", "console.log('observed',42); new Promise(resolve=>setTimeout(()=>{resolve(true);throw new Error('fixture exception')},0))" });
    _ = try client.result(&.{ "eval", try c.a.print("Promise.all([fetch({s},{{method:'POST',body:'payload-secret'}}),fetch('/api/save?not-matched=true'),fetch('/api/reject',{{method:'POST'}}),fetch('/redirect'),fetch('http://127.0.0.1:1/').catch(()=>null)]).then(()=>true)", .{try c.json(url)}) });
    _ = try client.result(&.{ "content", try c.a.print("<a id=download href='{s}/download'>Download</a>", .{origin}) });
    const download = try c.path(try c.a.print("{s}.download", .{name}));
    _ = try client.result(&.{ "download", "#download", download });
    try c.bytes(download, "agent-download");
    _ = try client.result(&.{"reload"});
    _ = try client.result(&.{ "eval", "console.error('after reload'); true" });
    const summary = try finish(c, &observer, true);
    try H.equal(try H.field(summary, "reason"), "expired");
    const bytes = try c.read(path);
    try H.check(std.mem.indexOf(u8, bytes, "secret=") == null and std.mem.indexOf(u8, bytes, "payload-secret") == null, "default metadata redacts queries and bodies");
    var it = std.mem.splitScalar(u8, bytes, '\n');
    var index: i64 = 0;
    var post: ?[]const u8 = null;
    var bodies: usize = 0;
    var flags: [6]bool = @splat(false);
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const record = try c.parse(line);
        index += 1;
        try H.equal(try H.field(record, "seq"), index);
        try H.equal(try H.field(record, "tab"), client.tab.?);
        const kind = try H.str(record, "kind");
        const data = try H.field(record, "data");
        if (H.eql(u8, kind, "request") and H.is(try H.field(data, "method"), "POST") and H.is(try H.field(data, "url"), try c.a.print("{s}/api/save", .{origin}))) post = try H.str(data, "request_id");
        if (H.eql(u8, kind, "body")) {
            bodies += 1;
            try H.equal(try H.field(data, "request_id"), post.?);
            try H.equal(try H.field(data, "availability"), "complete");
            try H.equal(try c.parse(try H.str(data, "text")), .{ .saved = true, .id = 42 });
        }
        if (H.eql(u8, kind, "console")) {
            flags[0] = true;
            if (std.mem.indexOf(u8, line, "after reload") != null) flags[1] = true;
        }
        if (H.eql(u8, kind, "exception")) flags[2] = true;
        if (H.eql(u8, kind, "response") and (try H.field(data, "status")).integer == 400) flags[3] = true;
        if (H.eql(u8, kind, "redirect")) flags[4] = true;
        if (H.eql(u8, kind, "failed")) flags[5] = true;
    }
    try H.check(bodies == 1, "only the exact URL/method body is captured");
    for (flags, 0..) |flag, index_flag| {
        if (!flag) std.debug.print("missing observation {d}; capture={s}\n", .{ index_flag, bytes });
        try H.check(flag, "console, reload, exception, rejection, redirect and failure observed");
    }
    try H.equal(try client.result(&.{ "eval", "({w:innerWidth,h:innerHeight,dpr:devicePixelRatio})" }), geometry);
    _ = try client.failure(&.{ "observe", "--out", path, "--duration", "10" }, "PathAlreadyExists");
}
pub fn run(c: H.Context) !void {
    var fixture: Fixture = .{};
    try fixture.start(c);
    defer fixture.deinit();
    const origin = try fixture.origin(c);
    var owner = try H.Session.start(c, "observer-owner", &.{ "--allow", origin });
    defer owner.deinit();
    const own: H.Client = .{ .c = c, .target = owner.path, .tab = try H.str(try c.command(owner.path, &.{"status"}), "tab_id") };
    try exercise(own, origin, "owned-observation");
    var external = try @import("cli_endpoint.zig").External.start(c);
    defer external.deinit();
    const endpoint: H.Client = .{ .c = c, .target = external.endpoint, .endpoint = true };
    const id = try H.str(try endpoint.result(&.{ "new-tab", "--background" }), "id");
    const page: H.Client = .{ .c = c, .target = external.endpoint, .endpoint = true, .tab = id };
    try exercise(page, origin, "external-observation");
    var quiet = try start(page, "quiet", &.{ "--out", try c.path("quiet.jsonl"), "--duration", "100", "--events", "console" });
    defer quiet.deinit();
    try ready(c, &quiet);
    _ = try finish(c, &quiet, true);
    try c.bytes(try c.path("quiet.jsonl"), "");
    var small = try start(page, "small-body", &.{ "--out", try c.path("small-body.jsonl"), "--duration", "1000", "--body-limit", "1", "--body-url", try c.a.print("{s}/api/save", .{origin}), "--body-method", "POST" });
    defer small.deinit();
    try ready(c, &small);
    _ = try page.result(&.{ "eval", "fetch('/api/save',{method:'POST'}).then(r=>r.text())" });
    _ = try finish(c, &small, false);
    const small_bytes = try c.read(try c.path("small-body.jsonl"));
    try H.check(std.mem.indexOf(u8, small_bytes, "oversized") != null, "oversized body is explicit");
    var unicode = try start(page, "unicode-truncation", &.{ "--out", try c.path("unicode.jsonl"), "--duration", "3000", "--events", "exceptions" });
    defer unicode.deinit();
    try ready(c, &unicode);
    _ = try page.result(&.{ "eval", "new Promise(resolve=>setTimeout(()=>{resolve(true);throw new Error('🧭'.repeat(2000))},0))" });
    const unicode_summary = try finish(c, &unicode, false);
    if ((try H.field(unicode_summary, "truncated")).integer == 0) {
        std.debug.print("unicode capture summary: {s}\n", .{try c.json(unicode_summary)});
        H.printLog(c, try c.path("unicode.jsonl"));
    }
    try H.check((try H.field(unicode_summary, "truncated")).integer > 0, "exception truncation is explicit");
    const unicode_line = try c.read(try c.path("unicode.jsonl"));
    try H.check(std.unicode.utf8ValidateSlice(unicode_line), "truncation preserves UTF-8");
    _ = try c.parse(std.mem.trim(u8, unicode_line, "\n"));
    for ([_][]const u8{ "--max-events", "--max-bytes" }, [_][]const u8{ "1", "256" }, 0..) |option, value, n| {
        var overflow = try start(page, try c.a.print("overflow{d}", .{n}), &.{ "--out", try c.path(try c.a.print("overflow{d}.jsonl", .{n})), "--duration", "5000", option, value });
        defer overflow.deinit();
        try ready(c, &overflow);
        _ = try page.result(&.{ "eval", "for(let i=0;i<5;i++) console.log('x'.repeat(400)); true" });
        const result = try finish(c, &overflow, false);
        try H.check((try H.field(result, "dropped")).integer > 0, "overflow is explicit");
    }
    for ([_]std.os.linux.SIG{ .INT, .TERM }, 0..) |sig, n| {
        var pending = try start(page, try c.a.print("signal{d}", .{n}), &.{ "--out", try c.path(try c.a.print("signal{d}.jsonl", .{n})), "--duration", "10000" });
        defer pending.deinit();
        try ready(c, &pending);
        try pending.child.signal(sig);
        try H.equal(try H.field(try finish(c, &pending, false), "reason"), "interrupted");
        try page.expect(&.{ "eval", "42" }, 42);
    }
    // A real write failure: ignore SIGXFSZ so the CLI receives EFBIG and finalizes.
    const wrapper = try c.path("limited-observer");
    try c.write(wrapper, try c.a.print("#!/bin/sh\nulimit -f 1\ntrap '' XFSZ\nexec '{s}' \"$@\"\n", .{c.exe}));
    const executable = try H.Io.Dir.cwd().openFile(c.io, wrapper, .{});
    try executable.setPermissions(c.io, .fromMode(0o700));
    executable.close(c.io);
    var limited_client = page;
    limited_client.c.exe = wrapper;
    var output_failure = try start(limited_client, "write-failure", &.{ "--out", try c.path("write-failure.jsonl"), "--duration", "10000", "--events", "console" });
    defer output_failure.deinit();
    try ready(c, &output_failure);
    _ = try page.result(&.{ "eval", "console.log('y'.repeat(4000)); true" });
    const write_result = try finish(c, &output_failure, false);
    try H.check(!H.is(try H.field(write_result, "reason"), "expired"), "write failure has explicit completion reason");
    var closed = try start(page, "closed", &.{ "--out", try c.path("closed.jsonl"), "--duration", "10000" });
    defer closed.deinit();
    try ready(c, &closed);
    _ = try endpoint.result(&.{ "close-tab", id });
    _ = try finish(c, &closed, false);
    try H.check(try external.child.poll() == null, "observer never closes borrowed browser");
    const final_id = try H.str(try endpoint.result(&.{ "new-tab", "--background" }), "id");
    var final_page = page;
    final_page.tab = final_id;
    var exited = try start(final_page, "browser-exit", &.{ "--out", try c.path("exit.jsonl"), "--duration", "10000" });
    defer exited.deinit();
    try ready(c, &exited);
    _ = try external.child.stop(5000);
    _ = try finish(c, &exited, false);
    try owner.close();
}
