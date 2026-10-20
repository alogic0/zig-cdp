const std = @import("std");
const J = @import("cdp").journey;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const browser = try J.Browser.start(arena.allocator(), init.io);
    defer browser.stop();
    const page = try browser.page(&.{});
    defer page.close();
    _ = try page.eval(
        \\document.body.innerHTML = '<label>Name<input id="name"></label><button>Save</button><p id="result"></p>';
        \\document.querySelector('button').onclick = () => document.querySelector('#result').textContent = document.querySelector('#name').value;
        \\true
    );
    try page.label("Name").fill("Sample");
    try page.role(.{ .role = "button", .name = "Save" }).click();
    try page.wait("document.querySelector('#result').textContent === 'Sample'");
    std.debug.print("{s}: browser input and DOM check passed\n", .{browser.version});
}
