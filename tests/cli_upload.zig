const std = @import("std");
const H = @import("cli_support.zig");
pub fn exercise(page: H.Client) !void {
    const c = page.c;
    const first = try c.path("first file.txt");
    const second = try c.path("другий файл.txt");
    try c.write(first, "first contents");
    try c.write(second, "second contents ✓");
    _ = try page.result(&.{ "content", "<input id=many type=file multiple hidden><input id=single type=file><input id=disabled type=file multiple disabled><input class=amb type=file multiple><input class=amb type=file multiple><div id=wrong></div><input id=name value=unchanged>" });
    _ = try page.run(&.{ "upload", "--selector", "#many", "--file", "first file.txt", "--file", "другий файл.txt" }, .{ .cwd = c.root });
    try H.equal(try page.result(&.{ "eval", "Promise.all([...document.querySelector('#many').files].map(async f=>({name:f.name,text:await f.text()})))" }), .{ .{ .name = "first file.txt", .text = "first contents" }, .{ .name = "другий файл.txt", .text = "second contents ✓" } });
    _ = try page.failure(&.{ "upload", "--selector", "#many", "--file", first, "--file", try c.path("missing") }, "FileNotFound");
    try page.expect(&.{ "eval", "document.querySelector('#many').files.length" }, 2);
    _ = try page.failure(&.{ "upload", "--selector", "#single", "--file", first, "--file", second }, "MultipleFilesNotAllowed");
    try page.expect(&.{ "eval", "document.querySelector('#single').files.length" }, 0);
    _ = try page.failure(&.{ "upload", "--selector", "#disabled", "--file", first }, "ElementDisabled");
    _ = try page.failure(&.{ "upload", "--selector", ".amb", "--file", first }, "AmbiguousLocator");
    _ = try page.failure(&.{ "upload", "--selector", "#wrong", "--file", first }, "NotFileInput");
    _ = try page.failure(&.{ "upload", "--selector", "#many", "--file", c.root }, "NotRegularFile");
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(c.a, &.{ "upload", "--selector", "#many" });
    for (0..65) |_| try args.appendSlice(c.a, &.{ "--file", first });
    _ = try page.failure(args.items, "FileCountExceeded");
    try page.expect(&.{ "eval", "document.querySelector('#many').files.length" }, 2);
    _ = try page.result(&.{ "upload", "#single", first });
    try page.expect(&.{ "eval", "document.querySelector('#single').files[0].text()" }, "first contents");
    const sequence = try c.path("upload-sequence.json");
    try c.write(sequence, try c.json(.{ .version = 1, .steps = .{ .{ .command = "fill", .args = .{ "#name", "must not run" } }, .{ .command = "upload", .locator = .{ .selector = "#many" }, .files = .{ first, try c.path("missing") } } } }));
    _ = try page.failure(&.{ "sequence", "--file", sequence }, "FileNotFound");
    try page.expect(&.{ "eval", "document.querySelector('#name').value" }, "unchanged");
}
pub fn run(c: H.Context) !void {
    var owner = try H.Session.start(c, "upload-owner", &.{});
    defer owner.deinit();
    try exercise(.{ .c = c, .target = owner.path });
    var browser = try @import("cli_endpoint.zig").External.start(c);
    defer browser.deinit();
    const endpoint: H.Client = .{ .c = c, .target = browser.endpoint, .endpoint = true };
    const id = try H.str(try endpoint.result(&.{ "new-tab", "--background" }), "id");
    try exercise(.{ .c = c, .target = browser.endpoint, .endpoint = true, .tab = id });
    try owner.close();
}
