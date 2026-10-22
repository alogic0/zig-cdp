const std = @import("std");
const H = @import("cli_support.zig");
const O = @import("cli_observe.zig");
const Fixture = @import("cli_fixture.zig").Fixture;
fn waitBody(c: H.Context, path: []const u8, label: []const u8) !void {
    const deadline = H.Io.Clock.awake.now(c.io).addDuration(.fromSeconds(3));
    while (H.Io.Clock.awake.now(c.io).nanoseconds < deadline.nanoseconds) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var scratch = c;
        scratch.a = arena.allocator();
        const bytes = try scratch.read(path);
        var target: []const u8 = "";
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const value = scratch.parse(line) catch continue;
            if (std.mem.indexOf(u8, line, label) != null) target = try H.str(value, "target");
        }
        lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const value = scratch.parse(line) catch continue;
            if (H.is(try H.field(value, "target"), target) and H.is(try H.field(value, "kind"), "body") and H.is(try H.field(try H.field(value, "data"), "availability"), "complete")) return;
        }
        try c.io.sleep(.fromMilliseconds(10), .awake);
    }
    H.printLog(c, path);
    return error.WorkerBodyNotObserved;
}
fn exercise(client: H.Client, origin: []const u8, name: []const u8) !void {
    const c = client.c;
    _ = try client.result(&.{ "open", origin });
    _ = try client.result(&.{ "eval", "window.shared=new SharedWorker('/shared-worker.js');shared.port.start();window.seen=[];shared.port.onmessage=e=>seen.push(e.data);navigator.serviceWorker.onmessage=e=>seen.push(e.data);navigator.serviceWorker.register('/service-worker.js').then(()=>navigator.serviceWorker.ready).then(()=>true)" });
    _ = try client.result(&.{ "wait", "navigator.serviceWorker.controller!==null" });
    var browser = client;
    browser.tab = null;
    const workers = try browser.result(&.{"workers"});
    var ids: [2][]const u8 = .{ "", "" };
    for (workers.array.items) |worker| {
        if (!std.mem.startsWith(u8, try H.str(worker, "url"), origin)) continue;
        if (H.is(try H.field(worker, "type"), "shared_worker")) ids[0] = try H.str(worker, "id");
        if (H.is(try H.field(worker, "type"), "service_worker")) ids[1] = try H.str(worker, "id");
    }
    try H.check(ids[0].len > 0 and ids[1].len > 0, "shared/service worker IDs discovered");
    const unrelated_id = try H.str(try browser.result(&.{ "new-tab", origin, "--background" }), "id");
    var unrelated = client;
    unrelated.tab = unrelated_id;
    _ = try unrelated.result(&.{ "eval", "window.other=new Worker('/worker.js');window.done=false;window.workerError='';other.onerror=e=>workerError=e.message;other.onmessage=()=>done=true;other.postMessage({label:'before observation'});true" });
    _ = try unrelated.result(&.{ "wait", "done", "--timeout", "1500" });
    _ = try unrelated.result(&.{ "eval", "done=false;true" });
    const path = try c.path(try c.a.print("{s}.jsonl", .{name}));
    var observer = try O.start(client, name, &.{ "--out", path, "--duration", "5000", "--targets", "related", "--worker", ids[0], "--worker", ids[1], "--body-url", try c.a.print("{s}/api/save", .{origin}), "--body-method", "POST" });
    defer observer.deinit();
    errdefer {
        H.printLog(c, observer.err_path);
        H.printLog(c, observer.out_path);
        const diagnostic = c.read(path) catch "";
        var lines = std.mem.splitScalar(u8, diagnostic, '\n');
        while (lines.next()) |line| if (std.mem.indexOf(u8, line, "\"kind\":\"body\"") != null or std.mem.indexOf(u8, line, "\"kind\":\"target-") != null or std.mem.indexOf(u8, line, "iframe") != null) std.debug.print("{s}\n", .{line});
    }
    try O.ready(c, &observer);
    _ = try client.result(&.{ "eval", "window.worker=new Worker('/worker.js');worker.onmessage=e=>seen.push(e.data);worker.postMessage({label:'dedicated evidence'});shared.port.postMessage('selected shared');navigator.serviceWorker.controller.postMessage('selected service');true" });
    _ = try unrelated.result(&.{ "eval", "other.postMessage({label:'unrelated secret'});true" });
    _ = try client.result(&.{ "wait", "seen.includes('dedicated evidence')&&seen.includes('selected shared')&&seen.includes('selected service')" });
    _ = try client.result(&.{ "eval", "worker.postMessage({label:'nested',nested:true});true" });
    _ = try client.result(&.{ "wait", "seen.includes('nested complete')" });
    try waitBody(c, path, "nested evidence");
    _ = try client.result(&.{ "eval", "worker.terminate();window.worker=new Worker('/worker.js');worker.onmessage=e=>seen.push(e.data);worker.postMessage({label:'replacement evidence'});true" });
    _ = try client.result(&.{ "wait", "seen.includes('replacement evidence')" });
    const cross = try std.mem.replaceOwned(u8, c.a, origin, "127.0.0.1", "localhost");
    _ = try client.result(&.{ "eval", try c.a.print("new Promise(resolve=>{{const f=document.createElement('iframe');f.name='workerframe';f.onload=()=>resolve(true);f.src={s};document.body.append(f)}})", .{try c.json(try c.a.print("{s}/frame-controls", .{cross}))}) });
    const frame = try @import("cli_frames.zig").find(c, try client.result(&.{"frames"}), "workerframe");
    _ = try client.result(&.{ "eval", "console.log('iframe evidence');window.iframeDone=false;window.w=new Worker('/worker.js');w.onmessage=()=>iframeDone=true;w.postMessage({label:'iframe worker evidence'});true", "--frame", frame });
    _ = try client.result(&.{ "wait", "iframeDone", "--frame", frame, "--timeout", "1500" });
    _ = try O.finish(c, &observer, true);
    const bytes = try c.read(path);
    try H.check(std.mem.indexOf(u8, bytes, "unrelated secret") == null, "unrelated dedicated worker excluded");
    for ([_][]const u8{ "dedicated startup", "dedicated evidence", "nested startup", "nested evidence", "shared evidence", "service evidence", "replacement evidence", "worker exception", "iframe evidence", "iframe worker evidence", "target-ready", "target-lost" }) |evidence| {
        if (std.mem.indexOf(u8, bytes, evidence) == null) std.debug.print("missing {s}\n", .{evidence});
        try H.check(std.mem.indexOf(u8, bytes, evidence) != null, "worker and frame evidence captured");
    }
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var body_targets: std.StringHashMapUnmanaged(void) = .empty;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const record = try c.parse(line);
        try H.check((try H.str(record, "target")).len > 0, "every record identifies target");
        if (H.is(try H.field(record, "kind"), "body")) {
            const data = try H.field(record, "data");
            try H.equal(try H.field(data, "availability"), "complete");
            try H.equal(try c.parse(try H.str(data, "text")), .{ .saved = true, .id = 42 });
            try H.check((try H.str(record, "session")).len > 0, "worker body routed to session");
            try body_targets.put(c.a, try H.str(record, "target"), {});
        }
    }
    if (body_targets.count() < 5) std.debug.print("capture: {s}\n", .{bytes});
    try H.check(body_targets.count() >= 5, "bodies correlate to distinct worker targets");
    try unrelated.expect(&.{ "eval", "done" }, true);
    _ = try browser.result(&.{ "close-tab", unrelated_id });
}
fn faults(page: H.Client, origin: []const u8) !void {
    const c = page.c;
    // New shared workers stay runnable when they were not explicitly selected.
    var live = try O.start(page, "worker-interrupt", &.{ "--out", try c.path("worker-interrupt.jsonl"), "--duration", "10000", "--targets", "related" });
    defer live.deinit();
    try O.ready(c, &live);
    _ = try page.result(&.{ "eval", "window.extraShared=new SharedWorker('/shared-worker.js','unselected');window.extraDone=false;extraShared.port.onmessage=()=>extraDone=true;extraShared.port.start();extraShared.port.postMessage('unselected shared');true" });
    _ = try page.result(&.{ "wait", "extraDone" });
    _ = try page.result(&.{ "eval", "worker.postMessage({label:'after ready'});true" });
    try live.child.signal(.TERM);
    try H.equal(try H.field(try O.finish(c, &live, false), "reason"), "interrupted");
    _ = try page.result(&.{ "eval", "worker.postMessage({label:'after signal'});true" });
    _ = try page.result(&.{ "wait", "seen.includes('after signal')" });
    const interrupted_bytes = try c.read(try c.path("worker-interrupt.jsonl"));
    try H.check(std.mem.indexOf(u8, interrupted_bytes, "unselected shared") == null, "unselected shared worker stays outside observation");
    var limited = try O.start(page, "worker-limit", &.{ "--out", try c.path("worker-limit.jsonl"), "--duration", "10000", "--targets", "related", "--max-targets", "1" });
    defer limited.deinit();
    try H.equal(try H.field(try O.finish(c, &limited, false), "reason"), "TargetLimitExceeded");
    _ = try page.result(&.{ "eval", "worker.postMessage({label:'after limit'});true" });
    _ = try page.result(&.{ "wait", "seen.includes('after limit')" });
    var invalid = try O.start(page, "worker-invalid", &.{ "--out", try c.path("worker-invalid.jsonl"), "--duration", "1000", "--worker", page.tab.? });
    defer invalid.deinit();
    try H.equal(try H.field(try O.finish(c, &invalid, false), "reason"), "NotWorkerTarget");
    // A matched response still in progress at termination must be incomplete.
    var partial = try O.start(page, "worker-partial", &.{ "--out", try c.path("worker-partial.jsonl"), "--duration", "600", "--targets", "related", "--body-url", try c.a.print("{s}/slow-worker-body", .{origin}), "--body-method", "POST" });
    defer partial.deinit();
    try O.ready(c, &partial);
    const worker_script = try c.a.print("fetch({s},{{method:'POST'}}).then(r=>r.text())", .{try c.json(try c.a.print("{s}/slow-worker-body", .{origin}))});
    _ = try page.result(&.{ "eval", try c.a.print("window.slow=new Worker(URL.createObjectURL(new Blob([{s}],{{type:'text/javascript'}})));true", .{try c.json(worker_script)}) });
    const summary = try O.finish(c, &partial, false);
    try H.check((try H.field(summary, "unavailable_bodies")).integer > 0, "in-flight worker body marked incomplete");
    _ = try page.result(&.{ "eval", "slow.terminate();true" });
}
pub fn run(c: H.Context) !void {
    var fixture: Fixture = .{};
    try fixture.start(c);
    defer fixture.deinit();
    const origin = try fixture.origin(c);
    const cross = try std.mem.replaceOwned(u8, c.a, origin, "127.0.0.1", "localhost");
    var owner = try H.Session.start(c, "worker-owner", &.{ "--allow", origin, "--allow", cross });
    defer owner.deinit();
    const own: H.Client = .{ .c = c, .target = owner.path, .tab = try H.str(try c.command(owner.path, &.{"status"}), "tab_id") };
    try exercise(own, origin, "owned-workers");
    var external = try @import("cli_endpoint.zig").External.start(c);
    defer external.deinit();
    const browser: H.Client = .{ .c = c, .target = external.endpoint, .endpoint = true };
    const id = try H.str(try browser.result(&.{ "new-tab", "--background" }), "id");
    const page: H.Client = .{ .c = c, .target = external.endpoint, .endpoint = true, .tab = id };
    try exercise(page, origin, "endpoint-workers");
    try faults(page, origin);
    try owner.close();
}
