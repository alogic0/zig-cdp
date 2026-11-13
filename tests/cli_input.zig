const std = @import("std");
const H = @import("cli_support.zig");
pub fn exercise(page: H.Client) !void {
    const c = page.c;
    _ = try page.result(&.{ "content", @embedFile("fixtures/drag.html") });
    _ = try page.result(&.{ "drag", "--selector", "#card", "--to-selector", "#drop", "--hold", "150", "--steps", "8", "--timeout", "3000" });
    try page.expect(&.{ "eval", "document.querySelector('#drop > #card')!==null && !held && inputEvents.length===2 && inputEvents.every(e=>e.trusted)" }, true);
    _ = try page.result(&.{ "content", @embedFile("fixtures/drag.html") });
    for ([_][]const u8{ ".ambiguous", "#disabled", "#covered" }, [_][]const u8{ "AmbiguousLocator", "ElementDisabled", "ElementCovered" }) |selector, code| {
        const reply = try page.failure(&.{ "drag", "--selector", selector, "--to-selector", "#drop", "--timeout", "200" }, code);
        try H.equal(try H.field(try H.field(reply, "error"), "action"), "not_started");
    }
    _ = try page.result(&.{ "eval", "document.body.insertAdjacentHTML('beforeend', '<style>@keyframes move {from{left:0px} to{left:500px}}</style>'); moving.style.cssText='position:fixed;top:300px;animation:move 1s linear infinite'; true" });
    const moving_failure = try page.run(&.{ "drag", "--selector", "#moving", "--to-selector", "#drop", "--timeout", "300" }, .{ .ok = false });
    if (!H.is(try H.field(moving_failure, "err"), "ElementNotStable")) std.debug.print("moving failure: {s}\n", .{try c.json(moving_failure)});
    try H.equal(try H.field(moving_failure, "err"), "ElementNotStable");
    _ = try page.result(&.{ "eval", "moving.style.animation='none'; true" });
    const path = try c.path(if (page.endpoint) "endpoint-sequence.json" else "owned-sequence.json");
    const malformed = "{\"version\":1,\"steps\":[{\"command\":\"fill\",\"args\":[\"#name\",\"unexpected\"]},{\"command\":\"protocol\",\"args\":[\"Browser.close\"],\"params\":{}}]}";
    try c.write(path, malformed);
    _ = try page.failure(&.{ "sequence", "--file", path }, "UnsupportedProtocolMethod");
    try page.expect(&.{ "eval", "document.querySelector('#name').value" }, "");
    try c.write(path,
        \\{"version":1,"steps":[
        \\{"command":"fill","args":["#name","sequence"]},
        \\{"command":"protocol","args":["Input.dispatchMouseEvent"],"params":{"type":"mousePressed","x":40,"y":40,"button":"left","buttons":1,"clickCount":1}},
        \\{"command":"pause","args":["150"]},
        \\{"command":"protocol","args":["Input.dispatchMouseEvent"],"params":{"type":"mouseMoved","x":120,"y":40,"buttons":1}},
        \\{"command":"protocol","args":["Input.dispatchMouseEvent"],"params":{"type":"mouseMoved","x":180,"y":40,"buttons":1}},
        \\{"command":"protocol","args":["Input.dispatchMouseEvent"],"params":{"type":"mouseMoved","x":240,"y":40,"buttons":1}},
        \\{"command":"protocol","args":["Input.dispatchMouseEvent"],"params":{"type":"mouseReleased","x":240,"y":40,"button":"left","buttons":0,"clickCount":1}},
        \\{"command":"read"}]}
    );
    const result = try page.result(&.{ "sequence", "--file", path });
    try H.check((try H.field(result, "steps")).array.items.len == 8, "sequence returns every step");
    try page.expect(&.{ "text", "#result" }, "moved");
    const failure_sequence =
        \\{"version":1,"steps":[
        \\{"command":"protocol","args":["Input.dispatchMouseEvent"],"params":{"type":"mousePressed","x":40,"y":40,"button":"left","buttons":1}},
        \\{"command":"protocol","args":["Input.dispatchKeyEvent"],"params":{"type":"keyDown","key":"Shift","code":"ShiftLeft","windowsVirtualKeyCode":16}},
        \\{"command":"click","locator":{"selector":"#absent"}},
        \\{"command":"fill","args":["#name","must not run"]}]}
    ;
    try c.write(path, failure_sequence);
    const failed = try page.failure(&.{ "sequence", "--file", path, "--timeout", "500" }, "ElementNotFound");
    const detail = try H.field(failed, "error");
    try H.equal(try H.field(detail, "step"), 2);
    try H.equal(try H.field(detail, "input_release"), "complete");
    try H.equal(try H.field(detail, "exception"), null);
    try H.equal(try H.field((try H.field(detail, "steps")).array.items[3], "action"), "not_started");
    try page.expect(&.{ "eval", "!held && keys.length===0 && document.querySelector('#name').value==='sequence'" }, true);
    try c.write(path,
        \\{"version":1,"steps":[
        \\{"command":"eval","args":["1 + 1"]},
        \\{"command":"eval","args":["const a = 1;\nthrow new TypeError('step boom')"]},
        \\{"command":"fill","args":["#name","must not run"]}]}
    );
    const eval_seq = try page.failure(&.{ "sequence", "--file", path }, "BrowserEvaluationFailed");
    const eval_seq_err = try H.field(eval_seq, "error");
    try H.equal(try H.field(eval_seq_err, "step"), 1);
    const top_exc = try H.field(eval_seq_err, "exception");
    const step_exc = try H.field((try H.field(eval_seq_err, "steps")).array.items[1], "exception");
    try H.check(std.mem.indexOf(u8, try H.str(top_exc, "summary"), "TypeError: step boom") != null, "sequence error includes exception summary");
    try H.equal(try H.field(top_exc, "line"), 1);
    try H.equal(step_exc, top_exc);
    _ = try page.result(&.{ "content", @embedFile("fixtures/drag.html") });
    const timed = try page.run(&.{ "drag", "#card", "#drop", "--hold", "2000", "--timeout", "350" }, .{ .ok = false });
    try H.equal(try H.field(try H.field(timed, "error"), "input_release"), "complete");
    try page.expect(&.{ "eval", "!held" }, true);
    const protocol = try c.path("params.json");
    try c.write(protocol, "{}");
    _ = try page.result(&.{ "protocol", "Page.getLayoutMetrics", "--params", protocol });
    _ = try page.run(&.{ "protocol", "Page.getLayoutMetrics", "--params", "-" }, .{ .stdin = "{}" });
    _ = try page.failure(&.{ "protocol", "Target.closeTarget", "--params", protocol }, "UnsupportedProtocolMethod");
    if (page.endpoint) {
        var pending = try H.Pending.start(c, "held-interrupt", &.{ "--endpoint", page.target, "drag", "#card", "#drop", "--hold", "8000", "--tab", page.tab.? });
        defer pending.deinit();
        _ = try page.result(&.{ "wait", "held", "--timeout", "3000" });
        try pending.child.signal(.INT);
        try pending.failed(3000);
        const reply = try c.parse(try c.read(pending.out_path));
        try H.equal(try H.field(try H.field(reply, "error"), "input_release"), "complete");
        try page.expect(&.{ "eval", "!held" }, true);
    }
    _ = try page.result(&.{ "fill", "#name", "recovered" });
    try page.expect(&.{ "eval", "document.querySelector('#name').value" }, "recovered");
    const before_vp = try page.result(&.{ "eval", "({w:innerWidth,h:innerHeight,dpr:devicePixelRatio})" });
    _ = try page.result(&.{ "content", "<style>body{margin:0}#mobile-btn{display:none}@media(max-width:500px){#mobile-btn{display:block;width:120px;height:40px}}</style><button id=mobile-btn onclick=\"document.querySelector('#mobile-out').textContent='tapped'\">Menu</button><p id=mobile-out>idle</p>" });
    const seq_shot = try c.path(if (page.endpoint) "endpoint-seq-vp.png" else "owned-seq-vp.png");
    const vp_seq = try c.path(if (page.endpoint) "endpoint-vp-seq.json" else "owned-vp-seq.json");
    try c.write(vp_seq, try c.json(.{
        .version = 1,
        .steps = .{
            .{ .command = "eval", .args = .{"({w:innerWidth,h:innerHeight,dpr:devicePixelRatio,mq:matchMedia('(max-width: 500px)').matches})"} },
            .{ .command = "screenshot", .args = .{seq_shot} },
            .{ .command = "click", .locator = .{ .selector = "#mobile-btn" } },
            .{ .command = "text", .locator = .{ .selector = "#mobile-out" } },
        },
    }));
    const vp_res = try page.result(&.{ "sequence", "--file", vp_seq, "--emulate-viewport", "390x844" });
    try H.equal(try H.field(vp_res, "viewport_cleanup"), "complete");
    const vp_items = (try H.field(vp_res, "results")).array.items;
    try H.equal(vp_items[0], .{ .w = 390, .h = 844, .dpr = 1, .mq = true });
    try H.equal(vp_items[3], "tapped");
    const seq_dim = try H.S.png.dimensions(try c.read(seq_shot));
    try H.check(seq_dim.width == 390 and seq_dim.height == 844, "sequence inner screenshot keeps emulated 390x844 viewport");
    try H.equal(try page.result(&.{ "eval", "({w:innerWidth,h:innerHeight,dpr:devicePixelRatio})" }), before_vp);
    try c.write(vp_seq, try c.json(.{
        .version = 1,
        .steps = .{
            .{ .command = "eval", .args = .{"window.sawNarrow=(innerWidth===390);true"} },
            .{ .command = "click", .locator = .{ .selector = "#missing-mobile" } },
        },
    }));
    const vp_fail = try page.failure(&.{ "sequence", "--file", vp_seq, "--emulate-viewport", "390x844", "--timeout", "250" }, "ElementNotFound");
    try H.equal(try H.field(try H.field(vp_fail, "error"), "viewport_cleanup"), "complete");
    try page.expect(&.{ "eval", "window.sawNarrow" }, true);
    try H.equal(try page.result(&.{ "eval", "({w:innerWidth,h:innerHeight,dpr:devicePixelRatio})" }), before_vp);
    try c.write(vp_seq, try c.json(.{
        .version = 1,
        .steps = .{
            .{ .command = "eval", .args = .{"window.sawTimeoutNarrow=(innerWidth===390);true"} },
            .{ .command = "pause", .args = .{"2000"} },
        },
    }));
    const vp_timed = try page.run(&.{ "sequence", "--file", vp_seq, "--emulate-viewport", "390x844", "--timeout", "180" }, .{ .ok = false });
    try H.equal(try H.field(try H.field(vp_timed, "error"), "viewport_cleanup"), "complete");
    try page.expect(&.{ "eval", "window.sawTimeoutNarrow" }, true);
    try H.equal(try page.result(&.{ "eval", "({w:innerWidth,h:innerHeight,dpr:devicePixelRatio})" }), before_vp);
    if (page.endpoint) {
        try c.write(vp_seq, "{\"version\":1,\"steps\":[{\"command\":\"eval\",\"args\":[\"window.inMobileInterrupt=(innerWidth===390);true\"]},{\"command\":\"pause\",\"args\":[\"8000\"]}]}");
        var vp_pending = try H.Pending.start(c, "vp-interrupt", &.{ "--endpoint", page.target, "sequence", "--file", vp_seq, "--emulate-viewport", "390x844", "--tab", page.tab.? });
        defer vp_pending.deinit();
        _ = try page.result(&.{ "wait", "window.inMobileInterrupt===true", "--timeout", "3000" });
        try vp_pending.child.signal(.INT);
        try vp_pending.failed(3000);
        const vp_int_reply = try c.parse(try c.read(vp_pending.out_path));
        try H.equal(try H.field(try H.field(vp_int_reply, "error"), "viewport_cleanup"), "complete");
        try H.equal(try page.result(&.{ "eval", "({w:innerWidth,h:innerHeight,dpr:devicePixelRatio})" }), before_vp);
    }
}
pub fn run(c: H.Context) !void {
    var owner = try H.Session.start(c, "input-owner", &.{});
    defer owner.deinit();
    const own: H.Client = .{ .c = c, .target = owner.path };
    try exercise(own);
    var browser = try @import("cli_endpoint.zig").External.start(c);
    defer browser.deinit();
    const endpoint: H.Client = .{ .c = c, .target = browser.endpoint, .endpoint = true };
    const id = try H.str(try endpoint.result(&.{ "new-tab", "--background" }), "id");
    const page: H.Client = .{ .c = c, .target = browser.endpoint, .endpoint = true, .tab = id };
    try exercise(page);
    try H.check(try browser.child.poll() == null, "input cancellation preserves external Chrome");
    _ = try own.result(&.{ "content", @embedFile("fixtures/drag.html") });
    const own_id = try H.str(try own.result(&.{"status"}), "tab_id");
    const probe: H.Client = .{ .c = c, .target = try owner.browserUrl(""), .endpoint = true, .tab = own_id };
    var disconnected = try H.Pending.start(c, "owner-client-disconnect", &.{ "--session", owner.path, "drag", "#card", "#drop", "--hold", "8000" });
    defer disconnected.deinit();
    _ = try probe.result(&.{ "wait", "held", "--timeout", "3000" });
    try disconnected.child.signal(.TERM);
    try disconnected.failed(3000);
    try own.expect(&.{ "eval", "!held", "--timeout", "1000" }, true);
    _ = try page.result(&.{ "content", @embedFile("fixtures/drag.html") });
    var navigated = try H.Pending.start(c, "held-navigation", &.{ "--endpoint", page.target, "drag", "#card", "#drop", "--hold", "800", "--tab", id });
    defer navigated.deinit();
    _ = try page.result(&.{ "wait", "held", "--timeout", "3000" });
    _ = try page.result(&.{"reload"});
    try navigated.failed(3000);
    const nav_reply = try c.parse(try c.read(navigated.out_path));
    try H.equal(try H.field(nav_reply, "err"), "DocumentChanged");
    try H.equal(try H.field(try H.field(nav_reply, "error"), "input_release"), "complete");
    // Losing the target while pressed must report that release is incomplete.
    _ = try page.result(&.{ "content", @embedFile("fixtures/drag.html") });
    var closed = try H.Pending.start(c, "held-close", &.{ "--endpoint", page.target, "drag", "#card", "#drop", "--hold", "2000", "--tab", id });
    defer closed.deinit();
    _ = try page.result(&.{ "wait", "held", "--timeout", "3000" });
    _ = try endpoint.result(&.{ "close-tab", id });
    try closed.failed(5000);
    const close_reply = try c.parse(try c.read(closed.out_path));
    try H.equal(try H.field(try H.field(close_reply, "error"), "input_release"), "incomplete");
    const vp_close_id = try H.str(try endpoint.result(&.{ "new-tab", "--background" }), "id");
    const vp_close_page: H.Client = .{ .c = c, .target = browser.endpoint, .endpoint = true, .tab = vp_close_id };
    const vp_close_seq = try c.path("vp-close-seq.json");
    try c.write(vp_close_seq, "{\"version\":1,\"steps\":[{\"command\":\"eval\",\"args\":[\"window.vpCloseReady=(innerWidth===390);true\"]},{\"command\":\"pause\",\"args\":[\"4000\"]}]}");
    var vp_closed = try H.Pending.start(c, "vp-close", &.{ "--endpoint", browser.endpoint, "sequence", "--file", vp_close_seq, "--emulate-viewport", "390x844", "--tab", vp_close_id });
    defer vp_closed.deinit();
    _ = try vp_close_page.result(&.{ "wait", "window.vpCloseReady===true", "--timeout", "3000" });
    _ = try endpoint.result(&.{ "close-tab", vp_close_id });
    try vp_closed.failed(5000);
    const vp_close_reply = try c.parse(try c.read(vp_closed.out_path));
    try H.equal(try H.field(try H.field(vp_close_reply, "error"), "viewport_cleanup"), "incomplete");
    var fixture: @import("cli_fixture.zig").Fixture = .{};
    try fixture.start(c);
    defer fixture.deinit();
    const origin = try fixture.origin(c);
    const nav_sequence = try c.path("navigation-sequence.json");
    try c.write(nav_sequence, try c.json(.{ .version = 1, .steps = .{ .{ .command = "fill", .args = .{ "#name", "not allowed" } }, .{ .command = "open", .args = .{origin} } } }));
    _ = try own.failure(&.{ "sequence", "--file", nav_sequence }, "OriginNotAllowed");
    try own.expect(&.{ "eval", "document.querySelector('#name').value" }, "");
    _ = try own.result(&.{ "allow", origin });
    try c.write(nav_sequence, try c.json(.{ .version = 1, .steps = .{ .{ .command = "open", .args = .{origin} }, .{ .command = "reload" }, .{ .command = "read" } } }));
    _ = try own.result(&.{ "sequence", "--file", nav_sequence });
    try own.expect(&.{ "text", "#message" }, "Local page");
    try owner.close();
}
