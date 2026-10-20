const std = @import("std");
const J = @import("cdp").journey;

test "independent consumer launches and evaluates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const browser = try J.Browser.start(arena.allocator(), std.testing.io);
    defer browser.stop();
    const page = try browser.page(&.{});
    defer page.close();
    try std.testing.expectEqual(@as(i64, 3), J.number(try page.eval("1 + 2")));
}
