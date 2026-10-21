const std = @import("std");
const J = @import("cdp").journey;
const Agent = @import("cdp").agent;

test "independent consumer launches and evaluates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const browser = try J.Browser.start(arena.allocator(), std.testing.io);
    defer browser.stop();
    const page = try browser.page(&.{});
    defer page.close();
    try std.testing.expectEqual(@as(i64, 3), J.number(try page.eval("1 + 2")));
    _ = try page.eval("document.body.innerHTML='<button>Package action</button>'; true");
    var diagnostics: Agent.Diagnostics = .{};
    var command = try Agent.Page.init(arena.allocator(), std.testing.io, &page.socket, 5000, &diagnostics);
    defer command.deinit();
    const snapshot = try command.snapshot(20_000);
    try std.testing.expect(J.number(J.field(snapshot, "returned_nodes")) > 0);
    try command.click(.{ .role = "button", .name = "Package action" });
    try std.testing.expectEqual(.completed, diagnostics.action);
    var connection = try Agent.Connection.connect(arena.allocator(), std.testing.io, try arena.allocator().print("http://127.0.0.1:{d}", .{browser.client.port}));
    defer connection.disconnect();
    try std.testing.expect((try connection.tabs()).array.items.len > 0);
    var borrowed = try connection.page(page.target);
    borrowed.close();
    connection.disconnect();
    try std.testing.expectEqual(@as(i64, 42), J.number(try page.eval("42")));
}
