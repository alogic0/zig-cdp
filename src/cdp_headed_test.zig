const std = @import("std");
const J = @import("cdp").journey;

test "headed tabs share their context window and follow resizing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var random: [12]u8 = undefined;
    io.random(&random);
    const workspace = try a.print("/tmp/cdp-headed-fixture-{s}", .{std.fmt.bytesToHex(random, .lower)});
    try std.Io.Dir.cwd().createDir(io, workspace, .fromMode(0o700));
    defer std.Io.Dir.cwd().deleteTree(io, workspace) catch |err| std.debug.print("Headed fixture cleanup: {s}\n", .{@errorName(err)});
    const launcher = try a.print("{s}/browser", .{workspace});
    const log_path = try a.print("{s}/chrome.stderr", .{workspace});
    const executable = @import("cdp").findBrowserExecutable(io) orelse return error.NoBrowserFound;
    const script = try a.print("#!/bin/sh\nexec '{s}' --disable-gpu \"$@\" 2>'{s}'\n", .{ executable, log_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = launcher, .data = script, .flags = .{ .permissions = .fromMode(0o700) } });
    errdefer {
        if (std.Io.Dir.cwd().openFile(io, log_path, .{})) |file| {
            defer file.close(io);
            var buffer: [1024]u8 = undefined;
            var reader = file.readerStreaming(io, &buffer);
            var excerpt: [8192]u8 = undefined;
            const count = reader.interface.readSliceShort(&excerpt) catch 0;
            std.debug.print("Headed Chrome stderr: {s}\n", .{excerpt[0..count]});
        } else |_| {}
    }
    // Use software rendering for the Xvfb geometry fixture.
    const browser = try J.Browser.startWithOptions(a, io, .{ .headless = false, .executable = launcher });
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
            const geometry = page.eval("({w:innerWidth,h:innerHeight,ow:outerWidth,oh:outerHeight,visibility:document.visibilityState,focus:document.hasFocus(),dpr:devicePixelRatio,screen:{w:screen.width,h:screen.height}})") catch .null;
            const bounds = browser.command("Browser.getWindowBounds", .{ .windowId = window_id }) catch .null;
            std.debug.print("Headed geometry: {s}; native bounds: {s}\n", .{ J.json(arena.allocator(), geometry) catch "unavailable", J.json(arena.allocator(), bounds) catch "unavailable" });
        }
        // Observe the active document's viewport, without background throttling.
        _ = try browser.command("Target.activateTarget", .{ .targetId = page.target });
        _ = try page.command("Page.bringToFront", .{});
        _ = try page.eval("document.body.style.margin='0'; document.body.innerHTML='<main style=\"width:100%;height:100vh\">Viewport fixture</main>'; true");
        try page.wait("document.visibilityState === 'visible' && document.hasFocus()");
        _ = try browser.command("Browser.setWindowBounds", .{ .windowId = window_id, .bounds = .{ .windowState = "normal" } });
        _ = try browser.command("Browser.setWindowBounds", .{ .windowId = window_id, .bounds = .{ .width = 1100, .height = 850 } });
        _ = try page.command("Page.bringToFront", .{});
        try page.wait("Math.abs(outerWidth-1100)<=2 && Math.abs(outerHeight-850)<=2 && innerWidth>1000 && innerWidth<=outerWidth && innerHeight>600 && innerHeight<outerHeight");
        const before = try page.eval("({w:innerWidth,h:innerHeight,ow:outerWidth,oh:outerHeight})");
        _ = try browser.command("Browser.setWindowBounds", .{ .windowId = window_id, .bounds = .{ .width = 900, .height = 700 } });
        _ = try page.command("Page.bringToFront", .{});
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
