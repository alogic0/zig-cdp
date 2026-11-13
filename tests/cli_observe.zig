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
    try exerciseMultiPair(client, origin, name);
}
fn exerciseMultiPair(client: H.Client, origin: []const u8, name: []const u8) !void {
    const c = client.c;
    const path = try c.path(try c.a.print("{s}-multi.jsonl", .{name}));
    const save_url = try c.a.print("{s}/api/save?step=1", .{origin});
    const reject_url = try c.a.print("{s}/api/reject", .{origin});
    const detail_url = try c.a.print("{s}/api/detail?item=7", .{origin});
    const unmatched_detail = try c.a.print("{s}/api/detail?item=8", .{origin});
    var observer = try start(client, try c.a.print("{s}-multi", .{name}), &.{
        "--out",         path,
        "--duration",    "10000",
        "--body-method", "POST",
        "--body-url",    save_url,
        "--body-url",    reject_url,
        "--body-method", "POST",
        "--body-method", "GET",
        "--body-url",    detail_url,
    });
    defer observer.deinit();
    try ready(c, &observer);
    _ = try client.result(&.{ "open", origin });
    _ = try client.result(&.{ "eval", try c.a.print(
        "Promise.all([" ++
            "fetch({s},{{method:'POST',body:'one'}}).then(r=>r.text())," ++
            "fetch({s},{{method:'POST'}}).then(r=>r.text())," ++
            "fetch({s}).then(r=>r.text())," ++
            "fetch({s}).then(r=>r.text())," ++
            "fetch({s}).then(r=>r.text())" ++
            "]).then(()=>true)",
        .{ try c.json(save_url), try c.json(reject_url), try c.json(detail_url), try c.json(save_url), try c.json(unmatched_detail) },
    ) });
    const summary = try finish(c, &observer, true);
    try H.equal(try H.field(summary, "unavailable_bodies"), 0);
    try H.equal(try H.field(summary, "truncated"), 0);
    try H.equal(try H.field(summary, "dropped"), 0);
    const bytes = try c.read(path);
    var it = std.mem.splitScalar(u8, bytes, '\n');
    var save_id: ?[]const u8 = null;
    var reject_id: ?[]const u8 = null;
    var detail_ids: std.ArrayList([]const u8) = .empty;
    var seen_bodies: [3]bool = @splat(false);
    var body_count: usize = 0;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const record = try c.parse(line);
        const kind = try H.str(record, "kind");
        const data = try H.field(record, "data");
        if (H.eql(u8, kind, "request")) {
            const req_id = try H.str(data, "request_id");
            const method = try H.str(data, "method");
            const url = try H.str(data, "url");
            if (H.eql(u8, method, "POST") and H.eql(u8, url, try c.a.print("{s}/api/save", .{origin}))) save_id = req_id;
            if (H.eql(u8, method, "POST") and H.eql(u8, url, reject_url)) reject_id = req_id;
            if (H.eql(u8, method, "GET") and H.eql(u8, url, try c.a.print("{s}/api/detail", .{origin}))) try detail_ids.append(c.a, req_id);
        } else if (H.eql(u8, kind, "body")) {
            body_count += 1;
            const req_id = try H.str(data, "request_id");
            try H.equal(try H.field(data, "availability"), "complete");
            const parsed = try c.parse(try H.str(data, "text"));
            if (save_id != null and H.eql(u8, req_id, save_id.?)) {
                try H.equal(parsed, .{ .saved = true, .id = 42 });
                seen_bodies[0] = true;
            } else if (reject_id != null and H.eql(u8, req_id, reject_id.?)) {
                try H.equal(parsed, .{ .saved = false });
                seen_bodies[1] = true;
            } else {
                var matched_detail = false;
                for (detail_ids.items) |did| if (H.eql(u8, req_id, did)) {
                    matched_detail = true;
                };
                try H.check(matched_detail, "third body matches exact GET detail request");
                try H.equal(parsed, .{ .detail = "ok" });
                seen_bodies[2] = true;
            }
        }
    }
    try H.check(detail_ids.items.len == 2, "both matched and unmatched detail requests observed");
    try H.check(body_count == 3 and seen_bodies[0] and seen_bodies[1] and seen_bodies[2], "all three exact method/URL pairs captured and unmatched skipped");
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
    const partial_path = try c.path("partial-multi.jsonl");
    var partial = try start(page, "partial-multi", &.{ "--out", partial_path, "--duration", "2000", "--body-method", "POST", "--body-url", try c.a.print("{s}/api/save", .{origin}), "--body-method", "GET", "--body-url", "http://127.0.0.1:1/dead" });
    defer partial.deinit();
    try ready(c, &partial);
    _ = try page.result(&.{ "eval", "Promise.all([fetch('/api/save',{method:'POST'}).then(r=>r.text()),fetch('http://127.0.0.1:1/dead').catch(()=>null)]).then(()=>true)" });
    const partial_summary = try finish(c, &partial, false);
    try H.equal(try H.field(partial_summary, "unavailable_bodies"), 1);
    const partial_bytes = try c.read(partial_path);
    try H.check(std.mem.indexOf(u8, partial_bytes, "\"availability\":\"complete\"") != null and std.mem.indexOf(u8, partial_bytes, "\"reason\":\"LoadingFailed\"") != null, "multi-pair partial failure records complete and unavailable bodies");
    const invalid_out = try c.path("never-created.jsonl");
    for ([_]struct { args: []const []const u8, code: []const u8 }{
        .{ .args = &.{ "observe", "--out", invalid_out, "--body-method", "POST" }, .code = "BodyFilterRequired" },
        .{ .args = &.{ "observe", "--out", invalid_out, "--body-url", "https://example.test/a" }, .code = "BodyFilterRequired" },
        .{ .args = &.{ "observe", "--out", invalid_out, "--body-method", "POST", "--body-method", "GET", "--body-url", "https://example.test/a", "--body-url", "https://example.test/b" }, .code = "BodyFilterRequired" },
        .{ .args = &.{ "observe", "--out", invalid_out, "--body-method", "POST", "--body-url", "https://example.test/a", "--body-method", "GET" }, .code = "BodyFilterRequired" },
        .{ .args = &.{ "observe", "--out", invalid_out, "--body-method", "POST", "--body-url", "https://example.test/a", "--body-method", "get", "--body-url", "https://example.test/b" }, .code = "InvalidBodyFilter" },
        .{ .args = &.{ "observe", "--out", invalid_out, "--body-method", "POST", "--body-url", "https://example.test/a", "--body-method", "GET", "--body-url", "https://example.test/b#frag" }, .code = "InvalidBodyFilter" },
        .{ .args = &.{
            "observe",                "--out",                  invalid_out,
            "--body-method",          "GET",                    "--body-url",
            "https://example.test/1", "--body-method",          "GET",
            "--body-url",             "https://example.test/2", "--body-method",
            "GET",                    "--body-url",             "https://example.test/3",
            "--body-method",          "GET",                    "--body-url",
            "https://example.test/4", "--body-method",          "GET",
            "--body-url",             "https://example.test/5", "--body-method",
            "GET",                    "--body-url",             "https://example.test/6",
            "--body-method",          "GET",                    "--body-url",
            "https://example.test/7", "--body-method",          "GET",
            "--body-url",             "https://example.test/8", "--body-method",
            "GET",                    "--body-url",             "https://example.test/9",
        }, .code = "InvalidLimit" },
    }) |bad| {
        _ = try page.failure(bad.args, bad.code);
        try H.check(!try c.exists(invalid_out), "pre-capture validation never creates output file");
    }
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
