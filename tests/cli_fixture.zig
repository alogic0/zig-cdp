const std = @import("std");
const F = @import("http_fixture");
const H = @import("cli_support.zig");
pub const Fixture = struct {
    server: F.Server = undefined,
    background: std.atomic.Value(bool) = .init(false),
    download_closed: std.atomic.Value(bool) = .init(false),
    download_started: std.atomic.Value(bool) = .init(false),
    discovery: std.atomic.Value(Mode) = .init(.normal),
    pub const Mode = enum(u8) { normal, status, json, upgrade, hang };
    pub fn start(self: *Fixture, c: H.Context) !void {
        self.server = try F.Server.init(std.heap.page_allocator, c.io, .{
            .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } },
            .handler = .{ .context = self, .handle = handle },
            .limits = .{ .max_connections = 32, .max_header_bytes = 8192, .max_request_body_bytes = 4096, .max_response_bytes = 2 * 1024 * 1024 },
            .deadlines = .{ .handshake_ms = 1000, .request_head_ms = 5000, .request_total_ms = 10000, .write_ms = 2000 },
            .connection_policy = .close_after_response,
        });
        errdefer self.server.deinit();
        try self.server.start();
    }
    pub fn deinit(self: *Fixture) void {
        self.server.deinit();
    }
    pub fn origin(self: *Fixture, c: H.Context) ![]const u8 {
        return c.a.print("http://127.0.0.1:{d}", .{self.server.address().getPort()});
    }
    fn handle(ctx: *anyopaque, input: F.Input) anyerror!void {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        const mode = self.discovery.load(.acquire);
        if (mode == .hang) {
            try input.io.sleep(.fromSeconds(3), .awake);
            return;
        }
        if (mode == .upgrade and std.mem.startsWith(u8, input.request.target, "/devtools/")) {
            return input.response.sendRaw("HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: invalid\r\n\r\n");
        }
        if (mode != .normal) {
            const body = if (mode == .upgrade) try std.json.Stringify.valueAlloc(input.allocator, .{ .webSocketDebuggerUrl = try input.allocator.print("ws://127.0.0.1:{d}/devtools/browser/test", .{self.server.address().getPort()}) }, .{}) else "[]";
            return input.response.send(.{ .body = body, .status = if (mode == .status) .internal_server_error else .ok });
        }
        const target = input.request.target;
        if (H.eql(u8, target, "/slow-download") or H.eql(u8, target, "/large-download")) {
            const body = try input.allocator.alloc(u8, 1024 * 1024);
            @memset(body, 'x');
            self.download_started.store(true, .release);
            input.response.sendPlan(.{ .response = .{ .body = body, .headers = &.{ .{ .name = "Content-Type", .value = "application/octet-stream" }, .{ .name = "Content-Disposition", .value = "attachment; filename=\"stream.bin\"" } } }, .stream = .{ .size = 4096, .delay_ms = 20 }, .fault = if (H.eql(u8, target, "/large-download")) .{ .length_extra = 20 * 1024 * 1024 } else .none }) catch |err| {
                // A failed writer is the cancellation observation, distinct from
                // explicit EOF. Cancellation of the fixture itself cannot pass.
                if (err == error.WriteFailed) self.download_closed.store(true, .release);
                return err;
            };
            return;
        }
        if (H.eql(u8, target, "/background")) self.background.store(true, .release);
        if (H.eql(u8, target, "/download")) return input.response.send(.{ .body = "agent-download", .headers = &.{ .{ .name = "Content-Type", .value = "application/octet-stream" }, .{ .name = "Content-Disposition", .value = "attachment; filename=\"agent.txt\"" } } });
        try input.response.send(.{ .body = "<!doctype html><title>Fixture</title><p id=\"message\">Local page</p>", .headers = &.{.{ .name = "Content-Type", .value = "text/html" }} });
    }
};
