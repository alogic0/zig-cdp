//! Native Chromium Chrome DevTools Protocol (CDP) client and browser launcher.
//! Provides loopback target management, RFC 6455 WebSocket framing,
//! JSON-RPC evaluation, and headless process lifecycle.
const std = @import("std");
const ws = @import("ws");
pub const journey = @import("cdp_journey.zig");
pub const agent = @import("cdp_agent.zig");
pub const target_tree = @import("cdp_targets.zig");

pub const Target = struct {
    id: []const u8,
    target_type: []const u8,
    title: []const u8,
    url: []const u8,
    web_socket_debugger_url: []const u8,

    pub fn deinit(self: Target, alloc: std.mem.Allocator) void {
        if (self.id.len > 0) alloc.free(self.id);
        if (self.target_type.len > 0) alloc.free(self.target_type);
        if (self.title.len > 0) alloc.free(self.title);
        if (self.url.len > 0) alloc.free(self.url);
        if (self.web_socket_debugger_url.len > 0) alloc.free(self.web_socket_debugger_url);
    }
};

pub const WsSession = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    alloc: std.mem.Allocator,
    transport: ?ws.Connection = null,
    next_id: u32 = 1,
    failed: bool = false,
    pending: std.ArrayList([]const u8) = .empty,
    pending_bytes: usize = 0,
    event_context: ?*anyopaque = null,
    event_handler: ?*const fn (*anyopaque, *WsSession, []const u8) anyerror!void = null,
    /// Borrowed only during an event callback; replies inherit its target route.
    event_session_id: ?[]const u8 = null,
    /// Absolute awake-clock budget shared by all frames of one operation.
    deadline_ms: ?i64 = null,
    pub const max_message_bytes = 64 * 1024 * 1024;

    /// Change wire storage while idle, migrating queued messages before the
    /// old allocator is released. No call may be in flight during this move.
    pub fn setAllocator(self: *WsSession, alloc: std.mem.Allocator) !void {
        var pending: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (pending.items) |message| alloc.free(message);
            pending.deinit(alloc);
        }
        for (self.pending.items) |message| {
            const copy = try alloc.dupe(u8, message);
            errdefer alloc.free(copy);
            try pending.append(alloc, copy);
        }
        for (self.pending.items) |message| self.alloc.free(message);
        self.pending.deinit(self.alloc);
        self.pending = pending;
        self.alloc = alloc;
        if (self.transport) |*connection| connection.allocator = alloc;
    }

    pub fn close(self: *WsSession) void {
        for (self.pending.items) |message| self.alloc.free(message);
        self.pending.deinit(self.alloc);
        self.pending = .empty;
        self.pending_bytes = 0;
        self.wire().deinit();
    }

    fn wire(self: *WsSession) *ws.Connection {
        // Directly constructed sessions already own an upgraded stream.
        if (self.transport == null) self.transport = .{
            .stream = self.stream,
            .io = self.io,
            .allocator = self.alloc,
            .max_message_bytes = max_message_bytes,
        };
        return &self.transport.?;
    }

    fn timeout(self: *const WsSession) std.Io.Timeout {
        const end = self.deadline_ms orelse return ws.default_timeout;
        return .{ .deadline = .{ .clock = .awake, .raw = .{ .nanoseconds = @as(i96, end) * std.time.ns_per_ms } } };
    }

    pub fn sendRaw(self: *WsSession, payload: []const u8) !void {
        try self.wire().send(.text, payload, self.timeout());
    }

    pub fn receiveRaw(self: *WsSession) ![]const u8 {
        const connection = self.wire();
        const message = try connection.receive(self.timeout());
        if (message == .text) return message.text;
        message.deinit(self.alloc);
        connection.deinit();
        return if (message == .close) error.ConnectionClosed else error.InvalidWebSocketFrame;
    }

    pub fn takeEvent(self: *WsSession) ?[]const u8 {
        for (self.pending.items, 0..) |raw, index| {
            if ((responseId(self.alloc, raw) catch return null) == null) {
                self.pending_bytes -= raw.len;
                return self.pending.orderedRemove(index);
            }
        }
        return null;
    }

    fn retain(self: *WsSession, raw: []const u8) !void {
        if (self.pending.items.len >= 8192 or raw.len > max_message_bytes - self.pending_bytes) return error.EventLimitExceeded;
        try self.pending.append(self.alloc, raw);
        self.pending_bytes += raw.len;
    }

    pub fn responseId(alloc: std.mem.Allocator, raw: []const u8) !?u32 {
        const parsed = try @import("cdp_json.zig").parsed(alloc, raw);
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidProtocolReply;
        const id = parsed.value.object.get("id") orelse return null;
        if (id != .integer) return error.InvalidProtocolReply;
        return std.math.cast(u32, id.integer) orelse error.InvalidProtocolReply;
    }

    /// Sends a JSON-RPC command and waits for the response with the matching ID.
    pub fn call(self: *WsSession, method: []const u8, params_json: ?[]const u8) ![]const u8 {
        return self.callSession(self.event_session_id, method, params_json);
    }

    /// Serialized flattened-session command. IDs remain unique on the wire.
    pub fn callSession(self: *WsSession, session_id: ?[]const u8, method: []const u8, params_json: ?[]const u8) ![]const u8 {
        if (self.failed) return error.ConnectionClosed;
        var detached = false;
        errdefer if (!detached) {
            self.failed = true;
        };
        const id = self.next_id;
        self.next_id += 1;

        const stable_session = if (session_id) |sid| try self.alloc.dupe(u8, sid) else null;
        defer if (stable_session) |sid| self.alloc.free(sid);
        const route = if (stable_session) |sid| try std.json.Stringify.valueAlloc(self.alloc, sid, .{}) else null;
        defer if (route) |bytes| self.alloc.free(bytes);
        const cmd = if (route) |sid|
            try std.fmt.allocPrint(self.alloc, "{{\"id\":{d},\"sessionId\":{s},\"method\":\"{s}\",\"params\":{s}}}", .{ id, sid, method, params_json orelse "{}" })
        else
            try std.fmt.allocPrint(self.alloc, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params_json orelse "{}" });
        defer self.alloc.free(cmd);

        try self.sendRaw(cmd);

        while (true) {
            for (self.pending.items, 0..) |pending, index| {
                if (try responseId(self.alloc, pending) == id) {
                    self.pending_bytes -= pending.len;
                    return self.pending.orderedRemove(index);
                }
            }
            const raw = try self.receiveRaw();
            errdefer self.alloc.free(raw);
            const received_id = try responseId(self.alloc, raw);
            if (received_id == id) return raw;
            if (received_id == null) {
                if (self.event_handler) |handler| {
                    const envelope = try @import("cdp_json.zig").parsed(self.alloc, raw);
                    defer envelope.deinit();
                    const previous = self.event_session_id;
                    const sid = journey.field(envelope.value, "sessionId");
                    self.event_session_id = if (sid == .string) sid.string else null;
                    defer self.event_session_id = previous;
                    handler(self.event_context.?, self, raw) catch |err| {
                        if (err == error.SessionDetached) detached = true;
                        return err;
                    };
                    if (stable_session) |expected| if (std.mem.eql(u8, journey.str(journey.field(envelope.value, "method")), "Target.detachedFromTarget") and
                        std.mem.eql(u8, journey.str(journey.field(journey.field(envelope.value, "params"), "sessionId")), expected))
                    {
                        detached = true;
                        return error.SessionDetached;
                    };
                    self.alloc.free(raw);
                    continue;
                }
            }
            try self.retain(raw);
        }
    }

    /// Evaluates a JavaScript expression and returns the JSON-RPC response body.
    pub fn evaluate(self: *WsSession, expression: []const u8) ![]const u8 {
        const params = try std.json.Stringify.valueAlloc(self.alloc, .{
            .expression = expression,
            .awaitPromise = true,
            .returnByValue = true,
        }, .{});
        defer self.alloc.free(params);
        return self.call("Runtime.evaluate", params);
    }

    /// Evaluates a JavaScript expression and parses the returned JSON value.
    pub fn evaluateJson(self: *WsSession, expression: []const u8) !std.json.Parsed(std.json.Value) {
        const raw_reply = try self.evaluate(expression);
        defer self.alloc.free(raw_reply);

        const parsed = try @import("cdp_json.zig").parsed(self.alloc, raw_reply);
        return parsed;
    }

    /// Navigates to a URL.
    pub fn navigate(self: *WsSession, url: []const u8) !void {
        const params = try std.fmt.allocPrint(self.alloc, "{{\"url\":\"{s}\"}}", .{url});
        defer self.alloc.free(params);

        const reply = try self.call("Page.navigate", params);
        self.alloc.free(reply);
    }

    /// Polls until selector exists in DOM or timeout expires.
    pub fn waitForSelector(self: *WsSession, selector: []const u8, timeout_ms: u32) !void {
        const check_expr = try std.fmt.allocPrint(self.alloc, "Boolean(document.querySelector('{s}'))", .{selector});
        defer self.alloc.free(check_expr);

        const passes = @max(1, timeout_ms / 50);
        for (0..passes) |_| {
            const reply = try self.evaluate(check_expr);
            defer self.alloc.free(reply);

            if (std.mem.indexOf(u8, reply, "\"value\":true") != null) {
                return;
            }

            try std.Io.sleep(self.io, .fromMilliseconds(50), .awake);
        }
        return error.SelectorTimeout;
    }

    /// Configures viewport metrics for responsive layout and screenshot capture.
    pub fn setDeviceMetrics(self: *WsSession, width: u32, height: u32) !void {
        const params = try std.fmt.allocPrint(self.alloc, "{{\"width\":{d},\"height\":{d},\"deviceScaleFactor\":1,\"mobile\":false}}", .{ width, height });
        defer self.alloc.free(params);
        const reply = try self.call("Emulation.setDeviceMetricsOverride", params);
        self.alloc.free(reply);
    }

    /// Captures a PNG screenshot via CDP and returns the raw decoded PNG bytes.
    pub fn captureScreenshot(self: *WsSession) ![]const u8 {
        const reply = try self.call("Page.captureScreenshot", "{\"format\":\"png\"}");
        defer self.alloc.free(reply);

        const marker = "\"data\":\"";
        const start_idx = (std.mem.indexOf(u8, reply, marker) orelse return error.ScreenshotMissingData) + marker.len;
        const end_idx = std.mem.indexOfPos(u8, reply, start_idx, "\"") orelse return error.ScreenshotMissingData;
        const base64_str = reply[start_idx..end_idx];

        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(base64_str);
        const decoded = try self.alloc.alloc(u8, decoded_len);
        errdefer self.alloc.free(decoded);
        try std.base64.standard.Decoder.decode(decoded, base64_str);
        return decoded;
    }

    /// Adds a script to evaluate on every new document before page scripts run.
    pub fn addScriptToEvaluateOnNewDocument(self: *WsSession, source: []const u8) !void {
        const json_source = try std.json.Stringify.valueAlloc(self.alloc, source, .{});
        defer self.alloc.free(json_source);
        const params = try std.fmt.allocPrint(self.alloc, "{{\"source\":{s}}}", .{json_source});
        defer self.alloc.free(params);
        const reply = try self.call("Page.addScriptToEvaluateOnNewDocument", params);
        self.alloc.free(reply);
    }

    /// Navigates the page to the target URL.
    pub fn goto(self: *WsSession, target_url: []const u8) !void {
        const json_url = try std.json.Stringify.valueAlloc(self.alloc, target_url, .{});
        defer self.alloc.free(json_url);
        const params = try std.fmt.allocPrint(self.alloc, "{{\"url\":{s}}}", .{json_url});
        defer self.alloc.free(params);
        const reply = try self.call("Page.navigate", params);
        self.alloc.free(reply);
    }

    /// Reloads the current page via Page.reload.
    pub fn reload(self: *WsSession) !void {
        const reply = try self.call("Page.reload", "{}");
        self.alloc.free(reply);
    }

    fn extractResultString(alloc: std.mem.Allocator, reply: []const u8) ?[]const u8 {
        const parsed = @import("cdp_json.zig").parsed(alloc, reply) catch return null;
        defer parsed.deinit();

        if (parsed.value != .object) return null;
        const res_obj = parsed.value.object.get("result") orelse return null;
        if (res_obj != .object) return null;
        const inner_res = res_obj.object.get("result") orelse return null;
        if (inner_res != .object) return null;
        const val = inner_res.object.get("value") orelse return null;
        if (val == .string) {
            return alloc.dupe(u8, val.string) catch null;
        }
        return null;
    }

    /// Reads the value of an input or textarea matching selector, or null if absent.
    pub fn getInputValue(self: *WsSession, selector: []const u8) !?[]const u8 {
        const json_sel = try std.json.Stringify.valueAlloc(self.alloc, selector, .{});
        defer self.alloc.free(json_sel);
        const expr = try std.fmt.allocPrint(self.alloc, "document.querySelector({s})?.value", .{json_sel});
        defer self.alloc.free(expr);

        const reply = try self.evaluate(expr);
        defer self.alloc.free(reply);
        return extractResultString(self.alloc, reply);
    }

    /// Sets the HTML content of the document.
    pub fn setContent(self: *WsSession, html: []const u8) !void {
        const json_html = try std.json.Stringify.valueAlloc(self.alloc, html, .{});
        defer self.alloc.free(json_html);
        const expr = try std.fmt.allocPrint(
            self.alloc,
            "document.open(); document.write({s}); document.close();",
            .{json_html},
        );
        defer self.alloc.free(expr);
        const reply = try self.evaluate(expr);
        self.alloc.free(reply);
    }

    /// Clicks the element matching `selector`.
    pub fn click(self: *WsSession, selector: []const u8) !void {
        const json_sel = try std.json.Stringify.valueAlloc(self.alloc, selector, .{});
        defer self.alloc.free(json_sel);
        const expr = try std.fmt.allocPrint(
            self.alloc,
            \\(() => {{
            \\  const el = document.querySelector({s});
            \\  if (!el) throw new Error("Element not found: " + {s});
            \\  el.scrollIntoView({{ block: "center", inline: "center" }});
            \\  el.click();
            \\}})()
        ,
            .{ json_sel, json_sel },
        );
        defer self.alloc.free(expr);
        const reply = try self.evaluate(expr);
        defer self.alloc.free(reply);
        if (std.mem.indexOf(u8, reply, "\"exceptionDetails\":") != null) {
            return error.ElementNotFound;
        }
    }

    /// Fills an input or textarea element matching `selector` with `text`.
    pub fn fill(self: *WsSession, selector: []const u8, text: []const u8) !void {
        const json_sel = try std.json.Stringify.valueAlloc(self.alloc, selector, .{});
        defer self.alloc.free(json_sel);
        const json_val = try std.json.Stringify.valueAlloc(self.alloc, text, .{});
        defer self.alloc.free(json_val);
        const expr = try std.fmt.allocPrint(
            self.alloc,
            \\(() => {{
            \\  const el = document.querySelector({s});
            \\  if (!el) throw new Error("Element not found: " + {s});
            \\  el.focus();
            \\  el.value = {s};
            \\  el.dispatchEvent(new Event("input", {{ bubbles: true }}));
            \\  el.dispatchEvent(new Event("change", {{ bubbles: true }}));
            \\}})()
        ,
            .{ json_sel, json_sel, json_val },
        );
        defer self.alloc.free(expr);
        const reply = try self.evaluate(expr);
        defer self.alloc.free(reply);
        if (std.mem.indexOf(u8, reply, "\"exceptionDetails\":") != null) {
            return error.ElementNotFound;
        }
    }

    /// Polls until predicate JavaScript expression returns truthy or timeout expires.
    pub fn waitForFunction(self: *WsSession, expr: []const u8, timeout_ms: u32) !void {
        const check_expr = try std.fmt.allocPrint(self.alloc, "Boolean(typeof ({s}) === 'function' ? ({s})() : ({s}))", .{ expr, expr, expr });
        defer self.alloc.free(check_expr);

        const passes = @max(1, timeout_ms / 50);
        for (0..passes) |_| {
            const reply = try self.evaluate(check_expr);
            defer self.alloc.free(reply);

            if (std.mem.indexOf(u8, reply, "\"value\":true") != null) {
                return;
            }

            try std.Io.sleep(self.io, .fromMilliseconds(50), .awake);
        }
        return error.FunctionTimeout;
    }

    /// Returns the text content of the element matching `selector`, or null if absent.
    pub fn getText(self: *WsSession, selector: []const u8) !?[]const u8 {
        const json_sel = try std.json.Stringify.valueAlloc(self.alloc, selector, .{});
        defer self.alloc.free(json_sel);
        const expr = try std.fmt.allocPrint(self.alloc, "document.querySelector({s})?.textContent", .{json_sel});
        defer self.alloc.free(expr);

        const reply = try self.evaluate(expr);
        defer self.alloc.free(reply);
        return extractResultString(self.alloc, reply);
    }

    /// Returns the attribute value of the element matching `selector`, or null if absent.
    pub fn getAttribute(self: *WsSession, selector: []const u8, name: []const u8) !?[]const u8 {
        const json_sel = try std.json.Stringify.valueAlloc(self.alloc, selector, .{});
        defer self.alloc.free(json_sel);
        const json_name = try std.json.Stringify.valueAlloc(self.alloc, name, .{});
        defer self.alloc.free(json_name);
        const expr = try std.fmt.allocPrint(self.alloc, "document.querySelector({s})?.getAttribute({s})", .{ json_sel, json_name });
        defer self.alloc.free(expr);

        const reply = try self.evaluate(expr);
        defer self.alloc.free(reply);
        return extractResultString(self.alloc, reply);
    }

    /// Checks if the element matching `selector` is present and visible.
    pub fn isVisible(self: *WsSession, selector: []const u8) !bool {
        const json_sel = try std.json.Stringify.valueAlloc(self.alloc, selector, .{});
        defer self.alloc.free(json_sel);
        const expr = try std.fmt.allocPrint(
            self.alloc,
            \\(() => {{
            \\  const el = document.querySelector({s});
            \\  if (!el) return false;
            \\  const style = window.getComputedStyle(el);
            \\  return style.display !== 'none' && style.visibility !== 'hidden' && style.opacity !== '0' && !el.closest('[hidden]');
            \\}})()
        ,
            .{json_sel},
        );
        defer self.alloc.free(expr);
        const reply = try self.evaluate(expr);
        defer self.alloc.free(reply);
        return std.mem.indexOf(u8, reply, "\"value\":true") != null;
    }

    /// Triggers V8 garbage collection via HeapProfiler.collectGarbage.
    pub const HeapUsage = struct { used_size: u64, total_size: u64 };
    pub const DomCounters = struct { nodes: u64, documents: u64 };

    pub fn collectGarbage(self: *WsSession) !void {
        const reply = try self.call("HeapProfiler.collectGarbage", null);
        self.alloc.free(reply);
    }

    /// Queries heap usage via Runtime.getHeapUsage.
    pub fn getHeapUsage(self: *WsSession) !HeapUsage {
        const reply = try self.call("Runtime.getHeapUsage", null);
        defer self.alloc.free(reply);

        const parsed = try @import("cdp_json.zig").parsed(self.alloc, reply);
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse return error.MissingResult;
        const used = @as(u64, @intCast(result.object.get("usedSize").?.integer));
        const total = @as(u64, @intCast(result.object.get("totalSize").?.integer));
        return .{ .used_size = used, .total_size = total };
    }

    /// Queries DOM counter metrics via Memory.getDOMCounters.
    pub fn getDomCounters(self: *WsSession) !DomCounters {
        const reply = try self.call("Memory.getDOMCounters", null);
        defer self.alloc.free(reply);

        const parsed = try @import("cdp_json.zig").parsed(self.alloc, reply);
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse return error.MissingResult;
        const nodes = @as(u64, @intCast(result.object.get("nodes").?.integer));
        const docs = @as(u64, @intCast(result.object.get("documents").?.integer));
        return .{ .nodes = nodes, .documents = docs };
    }
};

pub const CdpClient = struct {
    port: u16,
    io: std.Io,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, port: u16) CdpClient {
        return .{
            .port = port,
            .io = io,
            .alloc = alloc,
        };
    }

    fn http(self: CdpClient, method: []const u8, path: []const u8) ![]const u8 {
        const stream = try (try std.Io.net.IpAddress.parse("127.0.0.1", self.port)).connect(self.io, .{ .mode = .stream });
        defer stream.close(self.io);

        var rb: [8192]u8 = undefined;
        var wb: [2048]u8 = undefined;
        var r = stream.reader(self.io, &rb);
        var w = stream.writer(self.io, &wb);

        const req = try std.fmt.allocPrint(self.alloc, "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nContent-Length: 0\r\n\r\n", .{ method, path, self.port });
        defer self.alloc.free(req);

        w.interface.writeAll(req) catch |err| return if ((w.err orelse err) == error.Canceled) error.Canceled else err;
        w.interface.flush() catch |err| return if ((w.err orelse err) == error.Canceled) error.Canceled else err;

        var header_buf: [4096]u8 = undefined;
        var header_len: usize = 0;
        while (header_len < header_buf.len) {
            const b = r.interface.takeByte() catch |err| return if ((r.err orelse err) == error.Canceled) error.Canceled else err;
            header_buf[header_len] = b;
            header_len += 1;
            if (header_len >= 4 and std.mem.eql(u8, header_buf[header_len - 4 .. header_len], "\r\n\r\n")) break;
        }
        const headers = header_buf[0..header_len];
        if (!std.mem.endsWith(u8, headers, "\r\n\r\n") or
            (!std.mem.startsWith(u8, headers, "HTTP/1.1 200 ") and !std.mem.startsWith(u8, headers, "HTTP/1.0 200 "))) return error.InvalidDiscoveryResponse;

        var content_length: usize = 0;
        if (std.mem.indexOf(u8, headers, "Content-Length:") orelse std.mem.indexOf(u8, headers, "content-length:")) |idx| {
            const after = headers[idx + "Content-Length:".len ..];
            const line_end = std.mem.indexOf(u8, after, "\r\n") orelse after.len;
            const num_str = std.mem.trim(u8, after[0..line_end], " \t");
            content_length = std.fmt.parseInt(usize, num_str, 10) catch 0;
        }

        if (content_length == 0) {
            return try self.alloc.alloc(u8, 0);
        }
        if (content_length > 16 * 1024 * 1024) return error.DiscoveryTooLarge;

        const body = try self.alloc.alloc(u8, content_length);
        r.interface.readSliceAll(body) catch |err| return if ((r.err orelse err) == error.Canceled) error.Canceled else err;
        return body;
    }

    pub fn isReady(self: CdpClient) bool {
        const body = self.http("GET", "/json/version") catch return false;
        self.alloc.free(body);
        return true;
    }

    pub fn connectBrowser(self: CdpClient) !WsSession {
        const body = try self.http("GET", "/json/version");
        defer self.alloc.free(body);
        const parsed = @import("cdp_json.zig").parsed(self.alloc, body) catch return error.InvalidProtocolReply;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidProtocolReply;
        const url = parsed.value.object.get("webSocketDebuggerUrl") orelse return error.InvalidProtocolReply;
        if (url != .string) return error.InvalidProtocolReply;
        return self.connectWs(url.string);
    }

    pub fn listTargets(self: CdpClient) ![]Target {
        const body = try self.http("GET", "/json/list");
        defer self.alloc.free(body);

        const parsed = try @import("cdp_json.zig").parsed(self.alloc, body);
        defer parsed.deinit();

        var targets: std.ArrayList(Target) = .empty;
        defer targets.deinit(self.alloc);
        for (parsed.value.array.items) |item| {
            const id = if (item.object.get("id")) |v| try self.alloc.dupe(u8, v.string) else "";
            const t = if (item.object.get("type")) |v| try self.alloc.dupe(u8, v.string) else "";
            const title = if (item.object.get("title")) |v| try self.alloc.dupe(u8, v.string) else "";
            const url = if (item.object.get("url")) |v| try self.alloc.dupe(u8, v.string) else "";
            const ws_url = if (item.object.get("webSocketDebuggerUrl")) |v| try self.alloc.dupe(u8, v.string) else "";

            try targets.append(self.alloc, .{
                .id = id,
                .target_type = t,
                .title = title,
                .url = url,
                .web_socket_debugger_url = ws_url,
            });
        }

        return targets.toOwnedSlice(self.alloc);
    }

    pub fn newTarget(self: CdpClient, url: []const u8) !Target {
        const path = try std.fmt.allocPrint(self.alloc, "/json/new?{s}", .{url});
        defer self.alloc.free(path);

        const body = try self.http("PUT", path);
        defer self.alloc.free(body);

        const parsed = try @import("cdp_json.zig").parsed(self.alloc, body);
        defer parsed.deinit();

        const id = if (parsed.value.object.get("id")) |v| try self.alloc.dupe(u8, v.string) else "";
        const t = if (parsed.value.object.get("type")) |v| try self.alloc.dupe(u8, v.string) else "";
        const title = if (parsed.value.object.get("title")) |v| try self.alloc.dupe(u8, v.string) else "";
        const target_url = if (parsed.value.object.get("url")) |v| try self.alloc.dupe(u8, v.string) else "";
        const ws_url = if (parsed.value.object.get("webSocketDebuggerUrl")) |v| try self.alloc.dupe(u8, v.string) else "";

        return .{
            .id = id,
            .target_type = t,
            .title = title,
            .url = target_url,
            .web_socket_debugger_url = ws_url,
        };
    }

    pub fn closeTarget(self: CdpClient, target_id: []const u8) !void {
        const path = try std.fmt.allocPrint(self.alloc, "/json/close/{s}", .{target_id});
        defer self.alloc.free(path);
        const body = try self.http("GET", path);
        self.alloc.free(body);
    }

    pub fn activateTarget(self: CdpClient, target_id: []const u8) !void {
        const path = try std.fmt.allocPrint(self.alloc, "/json/activate/{s}", .{target_id});
        defer self.alloc.free(path);
        const body = try self.http("GET", path);
        self.alloc.free(body);
    }

    pub fn connectWs(self: CdpClient, ws_url_or_path: []const u8) !WsSession {
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const temp = scratch.allocator();
        var path = ws_url_or_path;
        if (std.mem.startsWith(u8, path, "ws://")) {
            const uri = std.Uri.parse(path) catch return error.InvalidEndpoint;
            const host = try (uri.host orelse return error.InvalidEndpoint).toRawMaybeAlloc(temp);
            if ((!std.mem.eql(u8, host, "127.0.0.1") and !std.mem.eql(u8, host, "localhost")) or
                (uri.port orelse 80) != self.port or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidEndpoint;
            const decoded = try uri.path.toRawMaybeAlloc(temp);
            if (std.mem.indexOfAny(u8, decoded, " \r\n") != null) return error.InvalidEndpoint;
            path = uri.path.percent_encoded;
        }
        if (!std.mem.startsWith(u8, path, "/") or std.mem.indexOfAny(u8, path, " \r\n") != null) return error.InvalidEndpoint;

        const url = try temp.print("ws://127.0.0.1:{d}{s}", .{ self.port, path });
        const connection = try ws.Connection.connect(self.alloc, self.io, .{ .tcp = url }, .{ .max_message_bytes = WsSession.max_message_bytes });
        return .{ .io = self.io, .alloc = self.alloc, .stream = connection.stream, .transport = connection };
    }
};

/// Finds an available Chrome or Chromium binary executable path.
pub fn findBrowserExecutable(io: std.Io) ?[]const u8 {
    const candidates = [_][]const u8{
        "/usr/bin/google-chrome",
        "/usr/bin/google-chrome-stable",
        "/usr/bin/chromium",
        "/usr/bin/chromium-browser",
    };

    for (candidates) |path| {
        if (std.Io.Dir.cwd().openFile(io, path, .{})) |file| {
            file.close(io);
            return path;
        } else |_| {}
    }
    return null;
}

test "queued wire messages survive allocator replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var socket: WsSession = .{ .alloc = arena.allocator(), .io = std.testing.io, .stream = undefined };
    try socket.pending.append(arena.allocator(), try arena.allocator().dupe(u8, "queued response"));
    socket.pending_bytes = "queued response".len;
    try socket.setAllocator(std.testing.allocator);
    arena.deinit();
    defer {
        for (socket.pending.items) |message| std.testing.allocator.free(message);
        socket.pending.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("queued response", socket.pending.items[0]);
    try std.testing.expectEqual(@as(usize, "queued response".len), socket.pending_bytes);
    try socket.pending.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "another response"));
}

test "wire reads tolerate early poll expiry without extending the deadline" {
    const Fake = struct {
        time_ms: i64 = 0,
        polls: usize = 0,
        expire: bool = false,
        fn close(_: ?*anyopaque, _: []const std.Io.net.Socket) void {}
        fn now(ctx: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return .{ .nanoseconds = @as(i96, self.time_ms) * std.time.ns_per_ms };
        }
        fn awaitPoll(ctx: ?*anyopaque, batch: *std.Io.Batch, timeout: std.Io.Timeout) std.Io.Batch.AwaitConcurrentError!void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.polls += 1;
            if (self.polls == 1 or self.expire) {
                self.time_ms = @intCast(timeout.deadline.raw.toMilliseconds() - @as(i64, if (self.polls == 1) 1 else 0));
                return error.Timeout;
            }
            const index = batch.submitted.head;
            const slot = &batch.storage[index.toIndex()];
            @memcpy(slot.submission.operation.net_read.data[0][0..3], "\x81\x01x");
            slot.* = .{ .completion = .{ .node = .{ .next = .none }, .result = .{ .net_read = .{ .data_len = 3, .control_len = 0 } } } };
            batch.submitted = .{ .head = .none, .tail = .none };
            batch.completed = .{ .head = index, .tail = index };
        }
    };
    var fake: Fake = .{};
    var vtable = std.testing.io.vtable.*;
    vtable.now = Fake.now;
    vtable.netClose = Fake.close;
    vtable.batchAwaitConcurrent = Fake.awaitPoll;
    var socket: WsSession = .{ .alloc = std.testing.allocator, .io = .{ .userdata = &fake, .vtable = &vtable }, .stream = undefined, .deadline_ms = 10 };
    socket.stream.socket.handle = -1;
    const message = try socket.receiveRaw();
    defer socket.alloc.free(message);
    try std.testing.expectEqualStrings("x", message);
    try std.testing.expectEqual(@as(usize, 2), fake.polls);
    fake = .{ .expire = true };
    try std.testing.expectError(error.Timeout, socket.receiveRaw());
    try std.testing.expectEqual(@as(usize, 2), fake.polls);
    try std.testing.expectEqual(@as(i64, 10), fake.time_ms);
}

test "canceled websocket writes preserve cancellation for their owner" {
    const Fake = struct {
        fn close(_: ?*anyopaque, _: []const std.Io.net.Socket) void {}
        fn awaitPoll(_: ?*anyopaque, _: *std.Io.Batch, _: std.Io.Timeout) std.Io.Batch.AwaitConcurrentError!void {
            return error.Canceled;
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.batchAwaitConcurrent = Fake.awaitPoll;
    vtable.netClose = Fake.close;
    var socket: WsSession = .{ .alloc = std.testing.allocator, .io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable }, .stream = undefined };
    socket.stream.socket.handle = -1;
    try std.testing.expectError(error.Canceled, socket.sendRaw("{}"));
}

test "shared transport preserves reply and queued event ownership across allocator changes" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var server = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer server.deinit(io);
    const client = try server.socket.address.connect(io, .{ .mode = .stream });
    var session: WsSession = .{ .stream = client, .io = io, .alloc = arena.allocator() };
    defer session.close();
    const peer = try server.accept(io);
    defer peer.close(io);
    var buffer: [512]u8 = undefined;
    var writer = peer.writer(io, &buffer);
    const event = "{\"method\":\"Page.loadEventFired\",\"sessionId\":\"tab\"}";
    const first = "{\"id\":1,\"sessionId\":\"tab\",\"result\":{}}";
    const second = "{\"id\":2,\"result\":{}}";
    inline for (.{ event, first, second }) |message| {
        try writer.interface.writeAll(&.{ 0x81, message.len });
        try writer.interface.writeAll(message);
    }
    try writer.interface.flush();
    const reply = try session.callSession("tab", "Page.enable", null);
    try std.testing.expectEqualStrings(first, reply);
    session.alloc.free(reply);
    try session.setAllocator(std.testing.allocator);
    _ = arena.reset(.free_all);
    const queued = session.takeEvent() orelse return error.MissingEvent;
    defer std.testing.allocator.free(queued);
    try std.testing.expectEqualStrings(event, queued);
    const next = try session.call("Browser.getVersion", null);
    defer std.testing.allocator.free(next);
    try std.testing.expectEqualStrings(second, next);
    try std.testing.expect(session.takeEvent() == null);
}
