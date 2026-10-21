//! Native Chromium Chrome DevTools Protocol (CDP) client and browser launcher.
//! Provides loopback target management, RFC 6455 WebSocket framing,
//! JSON-RPC evaluation, and headless process lifecycle.
const std = @import("std");
pub const journey = @import("cdp_journey.zig");
pub const agent = @import("cdp_agent.zig");

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
    next_id: u32 = 1,
    failed: bool = false,
    pending: std.ArrayList([]const u8) = .empty,
    pending_bytes: usize = 0,
    event_context: ?*anyopaque = null,
    event_handler: ?*const fn (*anyopaque, *WsSession, []const u8) anyerror!void = null,
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
    }

    pub fn close(self: *WsSession) void {
        for (self.pending.items) |message| self.alloc.free(message);
        self.pending.deinit(self.alloc);
        self.stream.close(self.io);
    }

    pub fn sendRaw(self: *WsSession, payload: []const u8) !void {
        var wb: [4096]u8 = undefined;
        var w = self.stream.writer(self.io, &wb);

        // Byte 0: 0x81 (FIN + text frame)
        try w.interface.writeByte(0x81);

        // Byte 1..: mask bit set (0x80)
        if (payload.len < 126) {
            try w.interface.writeByte(0x80 | @as(u8, @intCast(payload.len)));
        } else if (payload.len <= 0xFFFF) {
            try w.interface.writeByte(0x80 | 126);
            var len_bytes: [2]u8 = undefined;
            std.mem.writeInt(u16, &len_bytes, @as(u16, @intCast(payload.len)), .big);
            try w.interface.writeAll(&len_bytes);
        } else {
            try w.interface.writeByte(0x80 | 127);
            var len_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &len_bytes, payload.len, .big);
            try w.interface.writeAll(&len_bytes);
        }

        var mask: [4]u8 = undefined;
        self.io.random(&mask);
        try w.interface.writeAll(&mask);
        var chunk: [4096]u8 = undefined;
        var offset: usize = 0;
        while (offset < payload.len) {
            const n = @min(chunk.len, payload.len - offset);
            for (chunk[0..n], 0..) |*byte, i| byte.* = payload[offset + i] ^ mask[(offset + i) % 4];
            try w.interface.writeAll(chunk[0..n]);
            offset += n;
        }
        try w.interface.flush();
    }

    fn readExact(self: *WsSession, bytes: []u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const remaining = if (self.deadline_ms) |end| end - @as(i64, @intCast(std.Io.Clock.awake.now(self.io).toMilliseconds())) else 30_000;
            if (remaining <= 0) return error.Timeout;
            var buffers = [_][]u8{bytes[offset..]};
            const result = try self.io.operateTimeout(.{ .net_read = .{
                .socket_handle = self.stream.socket.handle,
                .data = &buffers,
            } }, .{ .duration = .{ .raw = .fromMilliseconds(@min(remaining, 30_000)), .clock = .awake } });
            const n = (try result.net_read).data_len;
            if (n == 0) return error.ConnectionClosed;
            offset += n;
        }
    }

    pub fn receiveRaw(self: *WsSession) ![]const u8 {
        var message: std.ArrayList(u8) = .empty;
        errdefer message.deinit(self.alloc);
        var fragmented = false;
        while (true) {
            var head: [2]u8 = undefined;
            try self.readExact(&head);
            const b0 = head[0];
            const opcode = b0 & 0x0F;
            if (b0 & 0x70 != 0) return error.InvalidWebSocketFrame;
            const final = b0 & 0x80 != 0;
            const b1 = head[1];
            const masked = (b1 & 0x80) != 0;
            const len_byte = b1 & 0x7F;

            var payload_len: usize = len_byte;
            if (len_byte == 126) {
                var len_bytes: [2]u8 = undefined;
                try self.readExact(&len_bytes);
                payload_len = std.mem.readInt(u16, &len_bytes, .big);
            } else if (len_byte == 127) {
                var len_bytes: [8]u8 = undefined;
                try self.readExact(&len_bytes);
                payload_len = std.math.cast(usize, std.mem.readInt(u64, &len_bytes, .big)) orelse return error.MessageTooLarge;
            }
            if (payload_len > max_message_bytes - message.items.len) return error.MessageTooLarge;
            if (opcode >= 8 and (!final or payload_len > 125)) return error.InvalidWebSocketFrame;

            var mask_key: [4]u8 = undefined;
            if (masked) {
                try self.readExact(&mask_key);
            }

            const buf = try self.alloc.alloc(u8, payload_len);
            defer self.alloc.free(buf);
            try self.readExact(buf);

            if (masked) {
                for (buf, 0..) |*b, i| {
                    b.* ^= mask_key[i % 4];
                }
            }

            switch (opcode) {
                0, 1 => {
                    if ((opcode == 0) != fragmented) return error.InvalidWebSocketFrame;
                    try message.appendSlice(self.alloc, buf);
                    if (final) return message.toOwnedSlice(self.alloc);
                    fragmented = true;
                },
                8 => return error.ConnectionClosed,
                9 => {
                    var wb: [256]u8 = undefined;
                    var writer = self.stream.writer(self.io, &wb);
                    var mask: [4]u8 = undefined;
                    self.io.random(&mask);
                    try writer.interface.writeAll(&.{ 0x8a, 0x80 | @as(u8, @intCast(buf.len)) });
                    try writer.interface.writeAll(&mask);
                    for (buf, 0..) |byte, i| try writer.interface.writeByte(byte ^ mask[i % 4]);
                    try writer.interface.flush();
                },
                10 => {},
                else => return error.InvalidWebSocketFrame,
            }
        }
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
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidProtocolReply;
        const id = parsed.value.object.get("id") orelse return null;
        if (id != .integer) return error.InvalidProtocolReply;
        return std.math.cast(u32, id.integer) orelse error.InvalidProtocolReply;
    }

    /// Sends a JSON-RPC command and waits for the response with the matching ID.
    pub fn call(self: *WsSession, method: []const u8, params_json: ?[]const u8) ![]const u8 {
        if (self.failed) return error.ConnectionClosed;
        errdefer self.failed = true;
        const id = self.next_id;
        self.next_id += 1;

        const cmd = if (params_json) |p|
            try std.fmt.allocPrint(self.alloc, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, p })
        else
            try std.fmt.allocPrint(self.alloc, "{{\"id\":{d},\"method\":\"{s}\"}}", .{ id, method });
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
                    try handler(self.event_context.?, self, raw);
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

        const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, raw_reply, .{ .allocate = .alloc_always });
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
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, reply, .{}) catch return null;
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

        const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, reply, .{});
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

        const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, reply, .{});
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

        try w.interface.writeAll(req);
        try w.interface.flush();

        var header_buf: [4096]u8 = undefined;
        var header_len: usize = 0;
        while (header_len < header_buf.len) {
            const b = try r.interface.takeByte();
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
        try r.interface.readSliceAll(body);
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
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, body, .{}) catch return error.InvalidProtocolReply;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidProtocolReply;
        const url = parsed.value.object.get("webSocketDebuggerUrl") orelse return error.InvalidProtocolReply;
        if (url != .string) return error.InvalidProtocolReply;
        return self.connectWs(url.string);
    }

    pub fn listTargets(self: CdpClient) ![]Target {
        const body = try self.http("GET", "/json/list");
        defer self.alloc.free(body);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, body, .{});
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

        const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, body, .{});
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
        var path = ws_url_or_path;
        if (std.mem.startsWith(u8, path, "ws://")) {
            const uri = std.Uri.parse(path) catch return error.InvalidEndpoint;
            const host = try (uri.host orelse return error.InvalidEndpoint).toRawMaybeAlloc(self.alloc);
            if ((!std.mem.eql(u8, host, "127.0.0.1") and !std.mem.eql(u8, host, "localhost")) or
                (uri.port orelse 80) != self.port or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidEndpoint;
            path = try uri.path.toRawMaybeAlloc(self.alloc);
        }
        if (!std.mem.startsWith(u8, path, "/") or std.mem.indexOfAny(u8, path, " \r\n") != null) return error.InvalidEndpoint;

        const stream = try (try std.Io.net.IpAddress.parse("127.0.0.1", self.port)).connect(self.io, .{ .mode = .stream });
        errdefer stream.close(self.io);

        var rb: [1]u8 = undefined;
        var wb: [2048]u8 = undefined;
        var r = stream.reader(self.io, &rb);
        var w = stream.writer(self.io, &wb);

        const handshake = try std.fmt.allocPrint(
            self.alloc,
            "GET {s} HTTP/1.1\r\n" ++
                "Host: 127.0.0.1:{d}\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
                "Sec-WebSocket-Version: 13\r\n\r\n",
            .{ path, self.port },
        );
        defer self.alloc.free(handshake);

        try w.interface.writeAll(handshake);
        try w.interface.flush();

        var header_buf: [4096]u8 = undefined;
        var header_len: usize = 0;
        while (header_len < header_buf.len) {
            const b = try r.interface.takeByte();
            header_buf[header_len] = b;
            header_len += 1;
            if (header_len >= 4 and std.mem.eql(u8, header_buf[header_len - 4 .. header_len], "\r\n\r\n")) break;
        }

        const resp = header_buf[0..header_len];
        if (!std.mem.startsWith(u8, resp, "HTTP/1.1 101")) {
            return error.WebSocketUpgradeFailed;
        }
        var valid_accept = false;
        var lines = std.mem.splitSequence(u8, resp, "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], "Sec-WebSocket-Accept"))
                valid_accept = std.mem.eql(u8, std.mem.trim(u8, line[colon + 1 ..], " \t"), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
        }
        if (!valid_accept) return error.WebSocketUpgradeFailed;

        return WsSession{
            .stream = stream,
            .io = self.io,
            .alloc = self.alloc,
        };
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
