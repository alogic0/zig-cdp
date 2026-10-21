const std = @import("std");
const J = @import("cdp").journey;

test "headed tabs share their context window and follow resizing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const browser = try J.Browser.startWithOptions(arena.allocator(), std.testing.io, .{ .headless = false });
    defer browser.stop();
    const normal = try browser.profilePage(&.{});
    defer normal.close();
    const isolated = try browser.page(&.{});
    defer isolated.close();
    for ([_]*J.Page{ normal, isolated }) |page| {
        page.timeout_ms = 3000;
        const window = try browser.command("Browser.getWindowForTarget", .{ .targetId = page.target });
        const window_id = J.number(J.field(window, "windowId"));
        errdefer {
            const geometry = page.eval("({w:innerWidth,h:innerHeight,ow:outerWidth,oh:outerHeight,visibility:document.visibilityState,dpr:devicePixelRatio,screen:{w:screen.width,h:screen.height}})") catch .null;
            const bounds = browser.command("Browser.getWindowBounds", .{ .windowId = window_id }) catch .null;
            std.debug.print("Headed geometry: {s}; native bounds: {s}\n", .{ J.json(arena.allocator(), geometry) catch "unavailable", J.json(arena.allocator(), bounds) catch "unavailable" });
        }
        // Observe the active document's viewport, without background throttling.
        _ = try browser.command("Target.activateTarget", .{ .targetId = page.target });
        try page.wait("document.visibilityState === 'visible'");
        _ = try browser.command("Browser.setWindowBounds", .{ .windowId = window_id, .bounds = .{ .windowState = "normal" } });
        _ = try browser.command("Browser.setWindowBounds", .{ .windowId = window_id, .bounds = .{ .width = 1100, .height = 850 } });
        try page.wait("Math.abs(outerWidth-1100)<=2 && Math.abs(outerHeight-850)<=2 && innerWidth>1000 && innerWidth<=outerWidth && innerHeight>600 && innerHeight<outerHeight");
        const before = try page.eval("({w:innerWidth,h:innerHeight,ow:outerWidth,oh:outerHeight})");
        _ = try browser.command("Browser.setWindowBounds", .{ .windowId = window_id, .bounds = .{ .width = 900, .height = 700 } });
        try page.wait("Math.abs(outerWidth-900)<=2 && Math.abs(outerHeight-700)<=2 && innerWidth>800 && innerWidth<=outerWidth && innerHeight>450 && innerHeight<outerHeight");
        const after = try page.eval("({w:innerWidth,h:innerHeight,ow:outerWidth,oh:outerHeight})");
        try std.testing.expectEqual(J.number(J.field(before, "ow")) - J.number(J.field(after, "ow")), J.number(J.field(before, "w")) - J.number(J.field(after, "w")));
        try std.testing.expectEqual(J.number(J.field(before, "oh")) - J.number(J.field(after, "oh")), J.number(J.field(before, "h")) - J.number(J.field(after, "h")));
        const sibling = try browser.newTab(page.context, &.{});
        defer sibling.detach();
        const sibling_window = try browser.command("Browser.getWindowForTarget", .{ .targetId = sibling.target });
        try std.testing.expectEqual(window_id, J.number(J.field(sibling_window, "windowId")));
        try sibling.wait("innerWidth>800 && innerWidth<=outerWidth && outerWidth<=902");
        _ = try sibling.eval("window.kept = 'same document'; true");
        sibling.close();
        const attached = try browser.attachTab(sibling.target, page.context, &.{});
        defer attached.detach();
        try std.testing.expectEqualStrings("same document", J.str(try attached.eval("window.kept")));
        try browser.closeTab(sibling.target);
        attached.detach();
        try std.testing.expect(J.boolean(try page.eval("true")));
    }
}
