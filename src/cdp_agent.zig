//! Request-scoped agent operations on a borrowed page socket.
const std = @import("std");
const cdp = @import("cdp.zig");
const J = @import("cdp_journey.zig");
const A = std.mem.Allocator;
pub const Value = std.json.Value;

pub const Query = struct {
    selector: ?[]const u8 = null,
    role: ?[]const u8 = null,
    name: ?[]const u8 = null,
    text: ?[]const u8 = null,

    pub fn validate(self: Query) !void {
        const count: u8 = @intFromBool(self.selector != null) + @as(u8, @intFromBool(self.role != null)) + @as(u8, @intFromBool(self.text != null));
        if (count != 1 or (self.name != null and self.role == null)) return error.InvalidLocator;
        for ([_]?[]const u8{ self.selector, self.role, self.text, self.name }) |value| if (value) |s| {
            if (s.len == 0 or s.len > 8192) return error.InvalidLocator;
        };
    }
};

pub const Diagnostics = struct {
    phase: enum { validate, connect, resolve, inspect, action, output } = .validate,
    match_count: ?usize = null,
    action: enum { not_started, possibly_dispatched, completed } = .not_started,
};

pub const Page = struct {
    a: A,
    io: std.Io,
    socket: *cdp.WsSession,
    diagnostics: *Diagnostics,
    group: []const u8,
    deadline_ms: i64,
    previous_deadline: ?i64,

    pub fn init(a: A, io: std.Io, socket: *cdp.WsSession, timeout_ms: u32, diagnostics: *Diagnostics) !Page {
        var random: [8]u8 = undefined;
        io.random(&random);
        const end = now(io) + timeout_ms;
        const previous = socket.deadline_ms;
        const group = try a.print("zig-cdp-{s}", .{std.fmt.bytesToHex(random, .lower)});
        // Let the last bounded RPC finish without abandoning a healthy socket
        // when a locator's polling budget expires between send and reply.
        socket.deadline_ms = if (previous) |old| @min(old, end + 100) else end + 100;
        return .{ .a = a, .io = io, .socket = socket, .diagnostics = diagnostics, .group = group, .deadline_ms = end, .previous_deadline = previous };
    }

    pub fn deinit(self: *Page) void {
        // Release remote handles even after the operation budget expires. A
        // failed cleanup seals this socket rather than reusing uncertain state.
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        self.socket.deadline_ms = now(self.io) + 200;
        if (!self.socket.failed) _ = self.command("Runtime.releaseObjectGroup", .{ .objectGroup = self.group }) catch {};
        self.socket.deadline_ms = self.previous_deadline;
    }

    pub fn command(self: *Page, method: []const u8, params: anytype) !Value {
        return call(self.a, self.socket, method, params);
    }

    fn remote(self: *Page, method: []const u8, params: anytype) !Value {
        const result = try self.command(method, params);
        if (J.field(result, "exceptionDetails") != .null) return error.BrowserEvaluationFailed;
        return J.field(result, "result");
    }

    pub fn eval(self: *Page, expression: []const u8) !Value {
        return J.field(try self.remote("Runtime.evaluate", .{ .expression = expression, .awaitPromise = true, .returnByValue = true, .objectGroup = self.group }), "value");
    }

    pub fn goto(self: *Page, url: []const u8) !void {
        const before = try self.eval("performance.timeOrigin");
        self.diagnostics.phase = .action;
        self.diagnostics.action = .possibly_dispatched;
        const navigation = try self.command("Page.navigate", .{ .url = url });
        if (J.str(J.field(navigation, "errorText")).len != 0) return error.NavigationFailed;
        if (J.str(J.field(navigation, "loaderId")).len != 0)
            try self.waitExpression(try self.a.print("performance.timeOrigin !== {s} && document.readyState === 'complete'", .{try J.json(self.a, before)}));
        self.diagnostics.action = .completed;
    }

    pub fn reload(self: *Page) !void {
        const before = try self.eval("performance.timeOrigin");
        self.diagnostics.phase = .action;
        self.diagnostics.action = .possibly_dispatched;
        _ = try self.command("Page.reload", .{});
        try self.waitExpression(try self.a.print("performance.timeOrigin !== {s} && document.readyState === 'complete'", .{try J.json(self.a, before)}));
        self.diagnostics.action = .completed;
    }

    pub fn content(self: *Page, html: []const u8) !void {
        self.diagnostics.phase = .action;
        self.diagnostics.action = .possibly_dispatched;
        _ = try self.eval(try self.a.print("(()=>{{document.open();document.write({s});document.close();return true}})()", .{try J.json(self.a, html)}));
        self.diagnostics.action = .completed;
    }

    fn invoke(self: *Page, id: []const u8, function: []const u8, arg: anytype, by_value: bool) !Value {
        return self.remote("Runtime.callFunctionOn", .{ .objectId = id, .functionDeclaration = function, .arguments = .{.{ .value = arg }}, .awaitPromise = true, .returnByValue = by_value, .objectGroup = self.group });
    }

    fn helper(self: *Page, id: []const u8, method: []const u8, arg: anytype) !Value {
        const function = try self.a.print("function(arg){{return ({s}).{s}.call(this,arg)}}", .{ @embedFile("cdp_agent_helpers.js"), method });
        return J.field(try self.invoke(id, function, arg, true), "value");
    }

    fn release(self: *Page, id: []const u8) void {
        if (self.socket.failed or now(self.io) >= self.deadline_ms) return;
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        _ = self.command("Runtime.releaseObject", .{ .objectId = id }) catch {};
    }

    fn pause(self: *Page) !void {
        if (now(self.io) >= self.deadline_ms) return error.Timeout;
        try self.io.sleep(.fromMilliseconds(@min(@as(i64, 25), self.deadline_ms - now(self.io))), .awake);
    }

    const Found = struct { count: usize, id: []const u8 = "" };

    fn find(self: *Page, query: Query) !Found {
        try query.validate();
        self.diagnostics.phase = .resolve;
        if (query.role) |role| {
            const tree = J.field(try self.command("Accessibility.getFullAXTree", .{}), "nodes");
            if (tree != .array) return error.InvalidProtocolReply;
            var count: usize = 0;
            var backend: Value = .null;
            for (tree.array.items) |node| {
                if (J.boolean(J.field(node, "ignored"))) continue;
                if (!std.mem.eql(u8, role, J.str(J.field(J.field(node, "role"), "value")))) continue;
                if (query.name) |name| if (!std.mem.eql(u8, name, J.str(J.field(J.field(node, "name"), "value")))) continue;
                if (J.field(node, "backendDOMNodeId") == .null) continue;
                count += 1;
                backend = J.field(node, "backendDOMNodeId");
            }
            self.diagnostics.match_count = count;
            if (count != 1) return .{ .count = count };
            const resolved = try self.command("DOM.resolveNode", .{ .backendNodeId = backend, .objectGroup = self.group });
            return .{ .count = 1, .id = J.str(J.field(J.field(resolved, "object"), "objectId")) };
        }
        const expression = try self.a.print("({s}).query({s})", .{ @embedFile("cdp_agent_helpers.js"), try J.json(self.a, query) });
        const array = try self.remote("Runtime.evaluate", .{ .expression = expression, .returnByValue = false, .objectGroup = self.group });
        const array_id = J.str(J.field(array, "objectId"));
        if (array_id.len == 0) return error.InvalidLocator;
        defer self.release(array_id);
        const count_value = J.field(try self.invoke(array_id, "function(){return this.length}", .{}, true), "value");
        const count: usize = @intCast(J.number(count_value));
        self.diagnostics.match_count = count;
        if (count != 1) return .{ .count = count };
        const element = try self.invoke(array_id, "function(){return this[0]}", .{}, false);
        return .{ .count = count, .id = J.str(J.field(element, "objectId")) };
    }

    fn resolve(self: *Page, query: Query) ![]const u8 {
        while (true) {
            if (now(self.io) >= self.deadline_ms) return error.ElementNotFound;
            var scratch = std.heap.ArenaAllocator.init(self.socket.alloc);
            defer scratch.deinit();
            var view = self.*;
            view.a = scratch.allocator();
            const found = try view.find(query);
            if (found.count > 1) return error.AmbiguousLocator;
            if (found.count == 1 and found.id.len > 0) return self.a.dupe(u8, found.id);
            if (now(self.io) >= self.deadline_ms) return error.ElementNotFound;
            self.pause() catch |err| return if (err == error.Canceled) err else error.ElementNotFound;
        }
    }

    pub fn snapshot(self: *Page, limit: usize) !Value {
        self.diagnostics.phase = .inspect;
        const tree = J.field(try self.command("Accessibility.getFullAXTree", .{}), "nodes");
        if (tree != .array) return error.InvalidProtocolReply;
        var nodes: std.ArrayList(Value) = .empty;
        var used: usize = 0;
        var total: usize = 0;
        var truncated = false;
        for (tree.array.items) |node| {
            if (J.boolean(J.field(node, "ignored"))) continue;
            total += 1;
            const value = try J.val(self.a, .{
                .id = J.field(node, "nodeId"),
                .parent = J.field(node, "parentId"),
                .backend_node_id = J.field(node, "backendDOMNodeId"),
                .role = J.field(J.field(node, "role"), "value"),
                .name = J.field(J.field(node, "name"), "value"),
                .value = J.field(J.field(node, "value"), "value"),
                .states = J.field(node, "properties"),
            });
            const size = (try J.json(self.a, value)).len + 1;
            if (size > limit - used or nodes.items.len == 2048) {
                truncated = true;
                continue;
            }
            used += size;
            try nodes.append(self.a, value);
        }
        return J.val(self.a, .{ .nodes = nodes.items, .truncated = truncated, .total_nodes = total, .returned_nodes = nodes.items.len, .returned_bytes = used });
    }

    pub fn read(self: *Page, query: ?Query, limit: usize) !Value {
        const id = try self.resolve(query orelse .{ .selector = "body" });
        defer self.release(id);
        self.diagnostics.phase = .inspect;
        return self.helper(id, "read", limit);
    }

    pub fn text(self: *Page, query: Query) !Value {
        const id = try self.resolve(query);
        defer self.release(id);
        return J.field(try self.invoke(id, "function(){return this.innerText}", .{}, true), "value");
    }

    pub fn click(self: *Page, query: Query) !void {
        var blocked: anyerror = error.ElementNotVisible;
        while (true) {
            if (now(self.io) >= self.deadline_ms) return blocked;
            var scratch = std.heap.ArenaAllocator.init(self.socket.alloc);
            defer scratch.deinit();
            var view = self.*;
            view.a = scratch.allocator();
            const id = try view.resolve(query);
            defer view.release(id);
            const info = try view.helper(id, "point", .{});
            const reason = J.str(J.field(info, "reason"));
            if (reason.len == 0) {
                const x = J.field(info, "x");
                const y = J.field(info, "y");
                _ = try view.command("Input.dispatchMouseEvent", .{ .type = "mouseMoved", .x = x, .y = y });
                self.diagnostics.phase = .action;
                self.diagnostics.action = .possibly_dispatched;
                _ = try view.command("Input.dispatchMouseEvent", .{ .type = "mousePressed", .x = x, .y = y, .button = "left", .buttons = @as(u32, 1), .clickCount = @as(u32, 1) });
                _ = try view.command("Input.dispatchMouseEvent", .{ .type = "mouseReleased", .x = x, .y = y, .button = "left", .buttons = @as(u32, 0), .clickCount = @as(u32, 1) });
                self.diagnostics.action = .completed;
                return;
            }
            blocked = if (std.mem.eql(u8, reason, "disabled")) error.ElementDisabled else if (std.mem.eql(u8, reason, "covered")) error.ElementCovered else error.ElementNotVisible;
            if (now(self.io) >= self.deadline_ms) return blocked;
            self.pause() catch |err| return if (err == error.Canceled) err else blocked;
        }
    }

    pub fn fill(self: *Page, query: Query, value: []const u8) !void {
        const id = try self.resolve(query);
        defer self.release(id);
        const reason = J.str(try self.helper(id, "prepareFill", .{}));
        if (reason.len != 0) return if (std.mem.eql(u8, reason, "disabled")) error.ElementDisabled else if (std.mem.eql(u8, reason, "readonly")) error.ElementReadOnly else error.ElementNotEditable;
        self.diagnostics.phase = .action;
        self.diagnostics.action = .possibly_dispatched;
        if (value.len == 0) {
            try self.press(null, "Backspace");
        } else _ = try self.command("Input.insertText", .{ .text = value });
        self.diagnostics.action = .completed;
    }

    pub fn select(self: *Page, query: Query, value: []const u8) !void {
        const id = try self.resolve(query);
        defer self.release(id);
        self.diagnostics.phase = .action;
        self.diagnostics.action = .possibly_dispatched;
        const valid = try self.helper(id, "select", value);
        if (!J.boolean(valid)) {
            self.diagnostics.action = .not_started;
            return error.InvalidSelectOption;
        }
        self.diagnostics.action = .completed;
    }

    pub fn wait(self: *Page, query: Query, state: []const u8) !void {
        if (!oneOf(state, &.{ "visible", "hidden", "attached", "detached" })) return error.InvalidWaitState;
        while (true) {
            if (now(self.io) >= self.deadline_ms) return error.LocatorTimeout;
            var scratch = std.heap.ArenaAllocator.init(self.socket.alloc);
            defer scratch.deinit();
            var view = self.*;
            view.a = scratch.allocator();
            const found = try view.find(query);
            if (found.count > 1) return error.AmbiguousLocator;
            if (found.count == 0) {
                if (oneOf(state, &.{ "hidden", "detached" })) return;
            } else {
                defer view.release(found.id);
                const info = try view.helper(found.id, "info", .{});
                const visible = J.boolean(J.field(info, "visible"));
                if (std.mem.eql(u8, state, "attached") or (visible and std.mem.eql(u8, state, "visible")) or (!visible and std.mem.eql(u8, state, "hidden"))) return;
            }
            if (now(self.io) >= self.deadline_ms) return error.LocatorTimeout;
            self.pause() catch |err| return if (err == error.Canceled) err else error.LocatorTimeout;
        }
    }

    pub fn waitExpression(self: *Page, expression: []const u8) !void {
        while (true) {
            if (now(self.io) >= self.deadline_ms) return error.BrowserConditionTimeout;
            var scratch = std.heap.ArenaAllocator.init(self.socket.alloc);
            defer scratch.deinit();
            var view = self.*;
            view.a = scratch.allocator();
            if (J.boolean(view.eval(expression) catch |err| blk: {
                if (self.socket.failed) return err;
                if (err == error.CdpCommandFailed) break :blk .null;
                return err;
            })) return;
            if (now(self.io) >= self.deadline_ms) return error.BrowserConditionTimeout;
            self.pause() catch |err| return if (err == error.Canceled) err else error.BrowserConditionTimeout;
        }
    }

    pub fn press(self: *Page, query: ?Query, input: []const u8) !void {
        const key = try Key.parse(input);
        if (query) |q| {
            const id = try self.resolve(q);
            defer self.release(id);
            _ = try self.invoke(id, "function(){this.focus();return true}", .{}, true);
        }
        self.diagnostics.phase = .action;
        self.diagnostics.action = .possibly_dispatched;
        _ = try self.command("Input.dispatchKeyEvent", .{ .type = "keyDown", .key = key.key, .code = key.code, .windowsVirtualKeyCode = key.virtual, .modifiers = key.modifiers, .text = key.text });
        _ = try self.command("Input.dispatchKeyEvent", .{ .type = "keyUp", .key = key.key, .code = key.code, .windowsVirtualKeyCode = key.virtual, .modifiers = key.modifiers });
        self.diagnostics.action = .completed;
    }

    pub fn upload(self: *Page, query: Query, filename: []const u8) !void {
        const id = try self.resolve(query);
        defer self.release(id);
        const info = try self.helper(id, "info", .{});
        if (J.boolean(J.field(info, "disabled"))) return error.ElementDisabled;
        self.diagnostics.phase = .action;
        self.diagnostics.action = .possibly_dispatched;
        _ = try self.command("DOM.setFileInputFiles", .{ .files = .{filename}, .objectId = id });
        self.diagnostics.action = .completed;
    }

    pub fn screenshot(self: *Page, output: []const u8, full_page: bool) !Value {
        self.diagnostics.phase = .inspect;
        const result = if (full_page) blk: {
            const metrics = try self.command("Page.getLayoutMetrics", .{});
            const size = J.field(metrics, "cssContentSize");
            const width = numeric(J.field(size, "width"));
            const height = numeric(J.field(size, "height"));
            if (width <= 0 or height <= 0 or width > 32768 or height > 32768 or width * height > 64 * 1024 * 1024) return error.ScreenshotTooLarge;
            break :blk try self.command("Page.captureScreenshot", .{ .format = "png", .captureBeyondViewport = true, .clip = .{ .x = 0, .y = 0, .width = width, .height = height, .scale = 1 } });
        } else try self.command("Page.captureScreenshot", .{ .format = "png", .captureBeyondViewport = false });
        const data = J.str(J.field(result, "data"));
        const size = try std.base64.standard.Decoder.calcSizeForSlice(data);
        if (size > 24 * 1024 * 1024) return error.ScreenshotTooLarge;
        const bytes = try self.a.alloc(u8, size);
        try std.base64.standard.Decoder.decode(bytes, data);
        self.diagnostics.phase = .output;
        try writeFile(self.io, output, bytes);
        return J.val(self.a, .{ .path = output, .bytes = size, .full_page = full_page });
    }
};

pub fn call(a: A, socket: *cdp.WsSession, method: []const u8, params: anytype) !Value {
    if (socket.deadline_ms) |end| if (now(socket.io) >= end) return error.Timeout;
    const args = if (@TypeOf(params) == @TypeOf(.{})) try a.dupe(u8, "{}") else try J.json(a, params);
    defer a.free(args);
    const raw = try socket.call(method, args);
    defer socket.alloc.free(raw);
    const reply = try J.parse(a, raw);
    if (J.field(reply, "error") != .null) return error.CdpCommandFailed;
    return J.field(reply, "result");
}

pub fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = .fromMode(0o600) });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn numeric(value: Value) f64 {
    return switch (value) {
        .integer => @floatFromInt(value.integer),
        .float => value.float,
        else => 0,
    };
}

fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, value, choice)) return true;
    return false;
}

fn now(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).toMilliseconds());
}

const Key = struct {
    key: []const u8,
    code: []const u8,
    virtual: u32,
    modifiers: u32,
    text: []const u8,

    fn parse(input: []const u8) !Key {
        var parts = std.mem.splitScalar(u8, input, '+');
        var modifiers: u32 = 0;
        var value = parts.next() orelse return error.InvalidKey;
        while (parts.next()) |next| {
            const bit: u32 = if (oneOf(value, &.{ "Control", "Ctrl" })) 2 else if (std.mem.eql(u8, value, "Alt")) 1 else if (std.mem.eql(u8, value, "Meta")) 4 else if (std.mem.eql(u8, value, "Shift")) 8 else return error.InvalidKey;
            if (modifiers & bit != 0) return error.InvalidKey;
            modifiers |= bit;
            value = next;
        }
        const names = [_][]const u8{ "Enter", "Tab", "Escape", "Backspace", "Delete", "ArrowLeft", "ArrowUp", "ArrowRight", "ArrowDown", "Home", "End", "PageUp", "PageDown", "Space" };
        const numbers = [_]u32{ 13, 9, 27, 8, 46, 37, 38, 39, 40, 36, 35, 33, 34, 32 };
        for (names, numbers) |name, number| if (std.mem.eql(u8, value, name)) return .{ .key = if (number == 32) " " else name, .code = name, .virtual = number, .modifiers = modifiers, .text = if (modifiers & 7 != 0) "" else if (number == 13) "\r" else if (number == 32) " " else "" };
        if (value.len == 1 and std.ascii.isPrint(value[0])) return .{ .key = value, .code = "", .virtual = std.ascii.toUpper(value[0]), .modifiers = modifiers, .text = if (modifiers & 7 != 0) "" else value };
        return error.InvalidKey;
    }
};
