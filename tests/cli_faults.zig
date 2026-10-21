const H = @import("cli_support.zig");
const Fixture = @import("cli_fixture.zig").Fixture;
pub fn run(c: H.Context) !void {
    var fixture: Fixture = .{};
    try fixture.start(c);
    defer fixture.deinit();
    const client: H.Client = .{ .c = c, .target = try fixture.origin(c), .endpoint = true };
    for ([_]struct { mode: Fixture.Mode, code: []const u8 }{
        .{ .mode = .status, .code = "InvalidDiscoveryResponse" }, .{ .mode = .json, .code = "InvalidProtocolReply" },
        .{ .mode = .upgrade, .code = "WebSocketUpgradeFailed" },  .{ .mode = .hang, .code = "CommandTimeout" },
    }) |row| {
        fixture.discovery.store(row.mode, .release);
        const start = H.Io.Clock.awake.now(c.io).toMilliseconds();
        const reply = try client.run(&.{ "tabs", "--timeout", "100" }, .{ .ok = false, .timeout_ms = 3000 });
        try H.equal(try H.field(reply, "err"), row.code);
        try H.equal(try H.field(try H.field(reply, "error"), "phase"), "connect");
        try H.check(H.Io.Clock.awake.now(c.io).toMilliseconds() - start < 1500, "discovery has one bounded command deadline");
    }
    fixture.server.stopAndJoin();
    try H.check(fixture.server.snapshot().active == 0 and fixture.server.snapshot().active_handlers == 0, "discovery handlers joined");
}
