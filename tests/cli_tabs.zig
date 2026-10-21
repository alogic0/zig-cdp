const std = @import("std");
const H = @import("cli_support.zig");
const Fixture = @import("cli_fixture.zig").Fixture;
pub fn exercise(server: *H.Session, fixture: *Fixture) !void {
    const c = server.c;
    const client: H.Client = .{ .c = c, .target = server.path };
    const origin = try fixture.origin(c);
    const original = (try client.result(&.{"tabs"})).array.items;
    try H.check(original.len == 1 and (try H.field(original[0], "selected")).bool, "one selected original tab");
    const first = try H.str(original[0], "id");
    try H.equal(try H.field(try client.result(&.{"status"}), "tab_id"), first);
    for ([_][]const []const u8{ &.{ "tabs", "extra" }, &.{ "new-tab", "one", "two" }, &.{"switch-tab"}, &.{ "close-tab", "one", "two" } }) |args| _ = try client.failure(args, "WrongArgumentCount");
    _ = try client.result(&.{ "content", "<title>First tab</title><input id=\"name\"><p id=\"value\">first</p>" });
    _ = try client.result(&.{ "fill", "#name", "kept in first" });
    _ = try client.result(&.{ "eval", "localStorage.setItem('tabs-shared','yes'); document.cookie='tabs_shared=yes; Max-Age=3600; SameSite=Lax'; true" });
    _ = try client.result(&.{ "timeout", "5000" });
    const second = try H.str(try client.result(&.{ "new-tab", try c.a.print("{s}/", .{origin}) }), "id");
    try H.check(!H.eql(u8, first, second), "distinct tab identities");
    try H.equal(try H.field(try client.result(&.{"status"}), "timeout_ms"), 5000);
    try client.expect(&.{ "eval", "localStorage.getItem('tabs-shared')" }, "yes");
    try client.expect(&.{ "eval", "document.cookie.includes('tabs_shared=yes')" }, true);
    _ = try client.result(&.{ "content", "<title>Second tab</title><input id=\"name\"><p id=\"value\">second</p>" });
    _ = try client.result(&.{ "fill", "#name", "kept in second" });
    const listed = (try client.result(&.{"tabs"})).array.items;
    try H.check(listed.len == 2, "two tabs listed");
    var titles: u8 = 0;
    var selected: usize = 0;
    for (listed) |tab| {
        const title = try H.field(tab, "title");
        if (H.is(title, "First tab")) titles |= 1;
        if (H.is(title, "Second tab")) titles |= 2;
        if ((try H.field(tab, "selected")).bool) {
            selected += 1;
            try H.equal(try H.field(tab, "id"), second);
        }
    }
    try H.check(titles == 3 and selected == 1, "exact titles and one selected second tab");
    try H.equal(try H.field(try client.result(&.{ "switch-tab", first }), "id"), first);
    try client.expect(&.{ "text", "#value" }, "first");
    try client.expect(&.{ "eval", "document.querySelector('#name').value" }, "kept in first");
    try H.equal(try H.field(try client.result(&.{"status"}), "timeout_ms"), 5000);
    try H.equal(try H.field(try client.result(&.{ "switch-tab", second }), "id"), second);
    try client.expect(&.{ "text", "#value" }, "second");
    try client.expect(&.{ "eval", "document.querySelector('#name').value" }, "kept in second");
    const other = try c.a.print("http://localhost:{d}", .{fixture.server.address().getPort()});
    _ = try client.result(&.{ "allow", other });
    fixture.background.store(false, .release);
    _ = try client.result(&.{ "eval", try c.a.print("setTimeout(() => fetch({s}), 200); true", .{try c.json(try c.a.print("{s}/background", .{other}))}) });
    _ = try client.result(&.{ "switch-tab", first });
    try H.waitFlag(c.io, &fixture.background, 5000);
    const before = try client.result(&.{"tabs"});
    _ = try client.failure(&.{ "new-tab", "https://example.invalid/" }, "OriginNotAllowed");
    try H.equal(try client.result(&.{"tabs"}), before);
    for ([_][]const u8{ "switch-tab", "close-tab" }) |op| _ = try client.failure(&.{ op, "missing-target" }, "TabNotFound");
    try client.expect(&.{ "eval", "true" }, true);
    const external = try H.str(try c.parse(try c.http(try server.browserUrl("/json/new?about:blank"), .PUT)), "id");
    const persistent = (try H.field(server.ready, "persistent_profile")).bool;
    const tabs = (try client.result(&.{"tabs"})).array.items;
    var found = false;
    for (tabs) |tab| {
        if (H.is(try H.field(tab, "id"), external)) found = true;
    }
    try H.check(found == persistent, "only saved profile adopts external default-context tab");
    if (persistent) {
        try H.equal(try H.field(try client.result(&.{ "switch-tab", external }), "id"), external);
        _ = try client.result(&.{ "content", "<title>External tab</title><p>attached</p>" });
        try client.expect(&.{ "text", "p" }, "attached");
        try H.equal(try H.field(try client.result(&.{"close-tab"}), "closed"), external);
    } else {
        for ([_][]const u8{ "switch-tab", "close-tab" }) |op| _ = try client.failure(&.{ op, external }, "TabNotFound");
        _ = try c.http(try server.browserUrl(try c.a.print("/json/close/{s}", .{external})), .GET);
    }
    _ = try client.result(&.{ "switch-tab", first });
    try client.expect(&.{ "close-tab", second }, .{ .closed = second, .selected = first });
    try client.expect(&.{ "text", "#value" }, "first");
    const blank = try client.result(&.{"new-tab"});
    try H.equal(try H.field(blank, "url"), "about:blank");
    try H.equal(try H.field(blank, "selected"), true);
    try client.expect(&.{"close-tab"}, .{ .closed = try H.str(blank, "id"), .selected = first });
    const doomed = try H.str(try client.result(&.{"new-tab"}), "id");
    _ = try c.http(try server.browserUrl(try c.a.print("/json/close/{s}", .{doomed})), .GET);
    try H.equal(try H.field(try client.result(&.{"status"}), "tab_id"), first);
    try client.expect(&.{ "text", "#value" }, "first");
    const replacement = try client.result(&.{"close-tab"});
    try H.equal(try H.field(replacement, "closed"), first);
    try H.check(!H.is(try H.field(replacement, "selected"), first), "last tab replaced");
    const remaining = (try client.result(&.{"tabs"})).array.items;
    try H.check(remaining.len == 1 and H.is(try H.field(remaining[0], "url"), "about:blank"), "one blank replacement");
    _ = try client.result(&.{ "open", try c.a.print("{s}/", .{origin}) });
    try client.expect(&.{ "eval", "localStorage.getItem('tabs-shared')" }, "yes");
    try client.expect(&.{ "eval", "document.cookie.includes('tabs_shared=yes')" }, true);
    const png = try c.path("tabs.png");
    _ = try client.result(&.{ "screenshot", png });
    _ = try H.S.png.dimensions(try c.read(png));
    _ = try client.result(&.{ "timeout", "30000" });
}
