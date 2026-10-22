const std = @import("std");
const H = @import("cli_support.zig");
const Fixture = @import("cli_fixture.zig").Fixture;
pub fn exercise(client: H.Client) !void {
    const c = client.c;
    _ = try client.result(&.{ "eval", @embedFile("fixtures/shadows.js") });
    const discovery = try H.field(try client.result(&.{"shadow-roots"}), "roots");
    try H.check(discovery.array.items.len == 4, "discover nested open and closed author roots");
    for (discovery.array.items) |root| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(c.a, "read");
        for ((try H.field(root, "hosts")).array.items) |host| try argv.appendSlice(c.a, &.{ "--shadow", host.string });
        _ = try client.result(argv.items);
    }
    const upload = try c.path("shadow.txt");
    try c.write(upload, "shadow bytes");
    for ([_][]const u8{ "#host", "#other" }) |host| {
        _ = try client.result(&.{ "fill", "#name", host, "--shadow", host });
        _ = try client.result(&.{ "click", "--role", "button", "--name", "Save", "--shadow", host });
        try client.expect(&.{ "text", "#result", "--shadow", host }, host);
        try client.expect(&.{ "eval", "trusted" }, true);
        const snapshot = try client.result(&.{ "snapshot", "--shadow", host });
        var saves: usize = 0;
        for ((try H.field(snapshot, "nodes")).array.items) |node| if (H.is(try H.field(node, "name"), "Save") and H.is(try H.field(node, "role"), "button")) {
            saves += 1;
        };
        try H.check(saves == 1, "snapshot respects selected root");
        _ = try client.result(&.{ "select", "#choice", "two", "--shadow", host });
        _ = try client.result(&.{ "upload", "#file", upload, "--shadow", host });
        _ = try client.result(&.{ "wait", "--text", host, "--shadow", host });
        _ = try client.result(&.{ "click", "#deep", "--shadow", host, "--shadow", "#nested" });
        _ = try client.failure(&.{ "click", "#deep", "--shadow", host, "--timeout", "200" }, "ElementNotFound");
        _ = try client.result(&.{ "drag", "#source", "#destination", "--hold", "20", "--steps", "3", "--shadow", host });
        try client.expect(&.{ "eval", "dropped" }, true);
    }
    try client.expect(&.{ "eval", "Promise.all(parts.map(r=>r.querySelector('#file').files[0].text()))" }, .{ "shadow bytes", "shadow bytes" });
    _ = try client.result(&.{ "click", "--text", "Slotted", "--shadow", "#host" });
    try client.expect(&.{ "eval", "slottedTrusted" }, true);
    _ = try client.result(&.{ "click", "--role", "button", "--name", "Slotted", "--shadow", "#host" });
    _ = try client.result(&.{ "eval", "parts[0].querySelector('slot').inert=true;true" });
    _ = try client.failure(&.{ "click", "#slotted", "--shadow", "#host", "--timeout", "500" }, "ElementDisabled");
    _ = try client.result(&.{ "eval", "parts[0].querySelector('slot').inert=false;true" });
    _ = try client.result(&.{ "eval", "document.querySelector('#host').inert=true;true" });
    _ = try client.failure(&.{ "fill", "#name", "blocked", "--shadow", "#host" }, "ElementDisabled");
    _ = try client.result(&.{ "eval", "document.querySelector('#host').inert=false;document.body.insertAdjacentHTML('beforeend','<div id=cover style=\"position:fixed;inset:0;z-index:999\"></div>');true" });
    _ = try client.failure(&.{ "click", "#save", "--shadow", "#host", "--timeout", "500" }, "ElementCovered");
    _ = try client.result(&.{ "eval", "document.querySelector('#cover').remove();window.motion=document.querySelector('#host').animate([{transform:'translateX(0)'},{transform:'translateX(20px)'}],{duration:1000,iterations:Infinity});true" });
    _ = try client.failure(&.{ "click", "#save", "--shadow", "#host", "--timeout", "500" }, "ElementNotStable");
    _ = try client.result(&.{ "eval", "motion.cancel();true" });
    _ = try client.failure(&.{ "read", "--shadow", "section" }, "AmbiguousShadowHost");
    _ = try client.failure(&.{ "read", "--shadow", "#absent" }, "ShadowHostNotFound");
    _ = try client.failure(&.{ "read", "--shadow", "#sentinel" }, "ShadowRootNotFound");
    const sequence = try c.path("shadow-sequence.json");
    try c.write(sequence, "{\"version\":1,\"steps\":[{\"command\":\"fill\",\"args\":[\"#name\",\"sequence\"]},{\"command\":\"press\",\"args\":[\"Tab\"]},{\"command\":\"click\",\"args\":[\"#save\"]},{\"command\":\"read\"}]}");
    _ = try client.result(&.{ "sequence", "--file", sequence, "--shadow", "#host" });
    try client.expect(&.{ "text", "#result", "--shadow", "#host" }, "sequence");
    try c.write(sequence, "{\"version\":1,\"steps\":[{\"command\":\"fill\",\"args\":[\"#name\",\"wrong\"]},{\"command\":\"eval\",\"args\":[\"true\"]}]}");
    _ = try client.failure(&.{ "sequence", "--file", sequence, "--shadow", "#host" }, "ShadowCommandUnsupported");
    try client.expect(&.{ "eval", "parts[0].querySelector('#name').value" }, "sequence");
    _ = try client.result(&.{ "eval", "document.querySelector('#host').remove();true" });
    _ = try client.failure(&.{ "read", "--shadow", "#host" }, "ShadowHostNotFound");
    _ = try client.result(&.{ "eval", "document.body.insertAdjacentHTML('beforeend','<section id=host></section>');document.querySelector('#host').attachShadow({mode:'closed'}).innerHTML='<button>Replacement</button>';true" });
    _ = try client.result(&.{ "click", "--text", "Replacement", "--shadow", "#host" });
    try client.expect(&.{ "eval", "document.querySelector('#sentinel').value" }, "unchanged");
}
pub fn run(c: H.Context) !void {
    var fixture: Fixture = .{};
    try fixture.start(c);
    defer fixture.deinit();
    const origin = try fixture.origin(c);
    const cross = try std.mem.replaceOwned(u8, c.a, origin, "127.0.0.1", "localhost");
    var owner = try H.Session.start(c, "shadow-owner", &.{ "--allow", origin, "--allow", cross });
    defer owner.deinit();
    var external = try @import("cli_endpoint.zig").External.start(c);
    defer external.deinit();
    const endpoint: H.Client = .{ .c = c, .target = external.endpoint, .endpoint = true };
    const id = try H.str(try endpoint.result(&.{ "new-tab", "--background" }), "id");
    for ([_]H.Client{ .{ .c = c, .target = owner.path }, .{ .c = c, .target = external.endpoint, .endpoint = true, .tab = id } }) |client| {
        _ = try client.result(&.{ "open", origin });
        try exercise(client);
        _ = try client.result(&.{ "content", try c.a.print("<iframe name=cross src='{s}/frame-controls' style='width:700px;height:500px'></iframe>", .{cross}) });
        var scoped = client;
        scoped.frame = try @import("cli_frames.zig").find(c, try client.result(&.{"frames"}), "cross");
        try exercise(scoped);
    }
    const own: H.Client = .{ .c = c, .target = owner.path };
    _ = try own.result(&.{ "eval", @embedFile("fixtures/shadows.js") });
    _ = try own.failure(&.{ "shadow-roots", "--limit", "1" }, "ShadowOutputLimitExceeded");
    _ = try own.result(&.{ "eval", "document.body.innerHTML='<main></main>';document.querySelector('main').append(...Array.from({length:10001},()=>document.createElement('div')));true" });
    _ = try own.failure(&.{"shadow-roots"}, "ShadowNodeLimitExceeded");
    _ = try own.result(&.{ "eval", "document.body.innerHTML='<main></main>';for(let n=document.querySelector('main'),i=0;i<130;i++)n=n.appendChild(document.createElement('div'));true" });
    _ = try own.failure(&.{"shadow-roots"}, "ShadowNodeLimitExceeded");
    _ = try own.result(&.{ "eval", "document.body.innerHTML='';for(let i=0;i<65;i++)document.body.appendChild(document.createElement('section')).attachShadow({mode:'closed'});true" });
    _ = try own.failure(&.{ "shadow-roots", "--limit", "1048576" }, "ShadowDepthExceeded");
    try own.expect(&.{ "eval", "42" }, 42);
    try owner.close();
}
