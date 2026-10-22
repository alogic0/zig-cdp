const std = @import("std");
const H = @import("cli_support.zig");
const Fixture = @import("cli_fixture.zig").Fixture;
pub fn find(c: H.Context, list: H.V, name: []const u8) ![]const u8 {
    for (list.array.items) |f| if (H.is(try H.field(f, "name"), name)) return H.str(f, "id");
    std.debug.print("frames: {s}\n", .{try c.json(list)});
    return error.FixtureFrameNotFound;
}
pub fn exercise(client: H.Client, origin: []const u8, cross: []const u8) !void {
    const c = client.c;
    _ = try client.result(&.{ "open", origin });
    _ = try client.result(&.{ "content", try c.a.print("<input id=sentinel value=unchanged><div style='height:100px'></div><iframe name=same src='{s}/frame-controls' style='margin:25px;border:8px solid;width:500px;height:220px'></iframe><iframe name=cross src='{s}/frame-controls' style='margin:30px;border:6px solid;width:500px;height:220px'></iframe>", .{ origin, cross }) });
    _ = try client.result(&.{ "wait", "document.querySelectorAll('iframe').length===2 && document.readyState==='complete'" });
    const frames = try client.result(&.{"frames"});
    for ([_][]const u8{ "same", "cross" }) |name| {
        const id = try find(c, frames, name);
        if (H.eql(u8, name, "cross")) for (frames.array.items) |frame| {
            if (H.is(try H.field(frame, "id"), id)) try H.check((try H.str(frame, "session")).len > 0, "cross-site frame uses a separate CDP session");
        };
        try client.expect(&.{ "eval", "document.querySelector('#name')!==null", "--frame", id }, true);
        _ = try client.result(&.{ "fill", "#name", name, "--frame", id });
        _ = try client.result(&.{ "click", "--role", "button", "--name", "Save", "--frame", id });
        try client.expect(&.{ "text", "#result", "--frame", id }, name);
        try client.expect(&.{ "eval", "trusted", "--frame", id }, true);
        _ = try client.result(&.{ "snapshot", "--frame", id });
        _ = try client.result(&.{ "select", "#choice", "two", "--frame", id });
        try client.expect(&.{ "eval", "document.querySelector('#choice').value", "--frame", id }, "two");
        const upload = try c.path("frame upload.txt");
        try c.write(upload, "frame bytes");
        _ = try client.result(&.{ "upload", "#file", upload, "--frame", id });
        try client.expect(&.{ "eval", "document.querySelector('#file').files[0].text()", "--frame", id }, "frame bytes");
        const sequence = try c.path("frame-sequence.json");
        try c.write(sequence, "{\"version\":1,\"steps\":[{\"command\":\"fill\",\"args\":[\"#name\",\"sequence\"]},{\"command\":\"click\",\"args\":[\"#save\"]},{\"command\":\"read\"}]}");
        _ = try client.result(&.{ "sequence", "--file", sequence, "--frame", id });
        _ = try client.result(&.{ "wait", "--text", "sequence", "--frame", id });
        try c.write(sequence, try c.json(.{ .version = 1, .steps = .{ .{ .command = "fill", .args = .{ "#name", "must not run" } }, .{ .command = "screenshot", .args = .{try c.path("wrong-scope.png")} } } }));
        _ = try client.failure(&.{ "sequence", "--file", sequence, "--frame", id }, "FrameCommandUnsupported");
        try client.expect(&.{ "eval", "document.querySelector('#name').value", "--frame", id }, "sequence");
        const document = try client.result(&.{ "protocol", "DOM.getDocument", "--frame", id });
        try H.equal(try H.field(try H.field(document, "root"), "nodeName"), "#document");
        _ = try client.result(&.{ "open", try c.a.print("{s}/frame-controls", .{if (H.eql(u8, name, "cross")) origin else cross}), "--frame", id, "--timeout", "5000" });
        try client.expect(&.{ "eval", "document.querySelector('#name')!==null", "--frame", id }, true);
        _ = try client.result(&.{ "reload", "--frame", id });
        try client.expect(&.{ "eval", "document.querySelector('#name').value", "--frame", id }, "");
    }
    const same_id = try find(c, frames, "same");
    _ = try client.result(&.{ "eval", "document.body.insertAdjacentHTML('beforeend','<div id=cover style=\"position:fixed;inset:0;z-index:99999\"></div>');true" });
    _ = try client.failure(&.{ "click", "#save", "--frame", same_id, "--timeout", "1000" }, "ElementCovered");
    _ = try client.result(&.{ "eval", "document.querySelector('#cover').remove();true" });
    try client.expect(&.{ "eval", "document.querySelector('#sentinel').value" }, "unchanged");
    _ = try client.failure(&.{ "click", "#name", "--timeout", "100" }, "ElementNotFound");
    _ = try client.failure(&.{ "eval", "true", "--frame", "not-a-frame" }, "FrameNotFound");
    const outer = try find(c, frames, "cross");
    _ = try client.result(&.{ "content", try c.a.print("<div style='height:60px'></div><iframe name=nested src='{s}/frame-controls' style='width:400px;height:200px;border:4px solid'></iframe>", .{origin}), "--frame", outer });
    const nested = try find(c, try client.result(&.{"frames"}), "nested");
    _ = try client.result(&.{ "fill", "#name", "nested", "--frame", nested });
    _ = try client.result(&.{ "click", "#save", "--frame", nested });
    try client.expect(&.{ "text", "#result", "--frame", nested }, "nested");
    _ = try client.result(&.{ "eval", "document.querySelector('iframe[name=cross]').remove();true" });
    _ = try client.failure(&.{ "fill", "#name", "wrong", "--frame", nested }, "FrameNotFound");
    try client.expect(&.{ "eval", "document.querySelector('#sentinel').value" }, "unchanged");
}
pub fn run(c: H.Context) !void {
    var fixture: Fixture = .{};
    try fixture.start(c);
    defer fixture.deinit();
    const origin = try fixture.origin(c);
    const cross = try std.mem.replaceOwned(u8, c.a, origin, "127.0.0.1", "localhost");
    var owner = try H.Session.start(c, "frames-owner", &.{ "--allow", origin, "--allow", cross });
    defer owner.deinit();
    try exercise(.{ .c = c, .target = owner.path }, origin, cross);
    var external = try @import("cli_endpoint.zig").External.start(c);
    defer external.deinit();
    const endpoint: H.Client = .{ .c = c, .target = external.endpoint, .endpoint = true };
    const id = try H.str(try endpoint.result(&.{ "new-tab", "--background" }), "id");
    try exercise(.{ .c = c, .target = external.endpoint, .endpoint = true, .tab = id }, origin, cross);
    const own: H.Client = .{ .c = c, .target = owner.path };
    const list = try own.result(&.{"frames"});
    const remaining = try find(c, list, "same");
    try own.expect(&.{ "eval", "fetch('https://outside.invalid/forbidden').then(()=>false,()=>true)", "--frame", remaining }, true);
    _ = try own.failure(&.{ "open", "https://outside.invalid/", "--frame", remaining }, "OriginNotAllowed");
    try owner.close();
}
