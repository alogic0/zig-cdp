//! CLI policy for one operation on an externally owned browser.
const std = @import("std");
const cdp = @import("cdp");
const Agent = cdp.agent;
const J = cdp.journey;
const session = @import("cli_session.zig");
const A = std.mem.Allocator;
const V = std.json.Value;

pub fn run(a: A, io: std.Io, endpoint: []const u8, input: session.Request) ![]const u8 {
    var diagnostics: Agent.Diagnostics = .{ .phase = .connect };
    _ = session.operation(input) catch |err| return session.failure(a, input, err, .{});
    const Result = union(enum) { value: anyerror!V, budget: std.Io.Cancelable!void };
    var results: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &results);
    var joined = false;
    defer if (!joined) select.cancelDiscard();
    const budget = input.timeout_ms orelse 30_000;
    select.async(.value, execute, .{ a, io, endpoint, input, &diagnostics, now(io) + budget });
    select.async(.budget, std.Io.sleep, .{ io, .fromMilliseconds(@as(i64, budget) + 300), .awake });
    const result = try select.await();
    select.cancelDiscard();
    joined = true;
    const value = switch (result) {
        .value => |value| value catch |err| return session.failure(a, input, err, diagnostics),
        .budget => return session.failure(a, input, error.CommandTimeout, diagnostics),
    };
    const reply = try J.json(a, .{ .ok = true, .result = value, .command = input.command, .tab = input.tab });
    if (reply.len > 16 * 1024 * 1024) return session.failure(a, input, error.ResponseTooLarge, diagnostics);
    return reply;
}

fn execute(a: A, io: std.Io, endpoint: []const u8, input: session.Request, diagnostics: *Agent.Diagnostics, deadline: i64) !V {
    const op = try session.operation(input);
    if (op == .allow or op == .timeout) return error.InvalidEndpointCommand;
    var connection = try Agent.Connection.connect(a, io, endpoint);
    defer connection.disconnect();
    connection.socket.deadline_ms = deadline + 100;
    switch (op) {
        .close => return .{ .string = "disconnected" },
        .tabs => return connection.tabs(),
        .status => if (input.tab == null) {
            const version = try Agent.call(a, &connection.socket, "Browser.getVersion", .{});
            return J.val(a, .{ .ownership = "external", .browser = J.field(version, "product"), .port = connection.client.port });
        },
        .@"new-tab" => {
            const url = if (input.args.len == 0) "about:blank" else input.args[0];
            _ = std.Uri.parse(url) catch return error.InvalidUrl;
            diagnostics.phase = .action;
            diagnostics.action = .possibly_dispatched;
            const created = try Agent.call(a, &connection.socket, "Target.createTarget", .{ .url = "about:blank", .newWindow = false });
            const id = J.str(J.field(created, "targetId"));
            if (!std.mem.eql(u8, url, "about:blank")) {
                var socket = try connection.page(id);
                defer socket.close();
                const remaining = deadline - now(io);
                if (remaining <= 0) return error.CommandTimeout;
                var page = try Agent.Page.init(a, io, &socket, @intCast(remaining), diagnostics);
                defer page.deinit();
                try page.goto(url);
            }
            diagnostics.action = .completed;
            const info = J.field(try Agent.call(a, &connection.socket, "Target.getTargetInfo", .{ .targetId = id }), "targetInfo");
            return J.val(a, .{ .id = id, .title = J.field(info, "title"), .url = J.field(info, "url") });
        },
        .@"close-tab", .@"switch-tab" => {
            const id = input.tab orelse if (input.args.len > 0) input.args[0] else return error.MissingTab;
            var socket = try connection.page(id);
            socket.close();
            diagnostics.phase = .action;
            diagnostics.action = .possibly_dispatched;
            const result = try Agent.call(a, &connection.socket, if (op == .@"close-tab") "Target.closeTarget" else "Target.activateTarget", .{ .targetId = id });
            if (op == .@"close-tab" and !J.boolean(J.field(result, "success"))) return error.TabNotFound;
            diagnostics.action = .completed;
            return J.val(a, .{ .id = id });
        },
        else => {},
    }
    const id = input.tab orelse return error.MissingTab;
    var socket = try connection.page(id);
    defer socket.close();
    socket.deadline_ms = deadline + 100;
    const remaining = deadline - now(io);
    if (remaining <= 0) return error.CommandTimeout;
    var page = try Agent.Page.init(a, io, &socket, @intCast(remaining), diagnostics);
    defer page.deinit();
    if (op == .status) return J.val(a, .{ .ownership = "external", .tab_id = id, .url = try page.eval("location.href"), .port = connection.client.port });
    if (op == .download) {
        const query = input.locator orelse Agent.Query{ .selector = input.args[0] };
        return page.download(query, input.args[if (input.locator == null) 1 else 0]);
    }
    return session.executePage(&page, input);
}

fn now(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).toMilliseconds());
}
