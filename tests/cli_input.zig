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
    try H.equal(try H.field((try H.field(detail, "steps")).array.items[3], "action"), "not_started");
    try page.expect(&.{ "eval", "!held && keys.length===0 && document.querySelector('#name').value==='sequence'" }, true);
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
    try owner.close();
}
