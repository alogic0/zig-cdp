//! Supported page protocol calls and conservative held-input cleanup.
const std = @import("std");
const J = @import("cdp_journey.zig");
const V = std.json.Value;
pub const methods = [_][]const u8{ "Input.dispatchMouseEvent", "Input.dispatchKeyEvent", "Input.insertText", "DOM.getDocument", "DOM.querySelector", "DOM.querySelectorAll", "DOM.getBoxModel", "Page.getLayoutMetrics", "Accessibility.getFullAXTree" };
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn one(s: []const u8, values: []const []const u8) bool {
    for (values) |v| if (eq(s, v)) return true;
    return false;
}
fn finite(v: V) bool {
    return switch (v) {
        .integer => @abs(v.integer) <= 1000000,
        .float => std.math.isFinite(v.float) and @abs(v.float) <= 1000000,
        else => false,
    };
}
fn fields(params: V, allowed: []const []const u8) !void {
    var it = params.object.iterator();
    while (it.next()) |entry| if (!one(entry.key_ptr.*, allowed)) return error.InvalidProtocolParameters;
}
fn integer(v: V, low: i64, high: i64) bool {
    return v == .integer and v.integer >= low and v.integer <= high;
}
fn optionalNumber(params: V, key: []const u8, low: i64, high: i64) !void {
    if (params.object.get(key)) |v| if (!integer(v, low, high)) return error.InvalidProtocolParameters;
}
fn optionalText(params: V, key: []const u8, limit: usize) !void {
    if (params.object.get(key)) |v| if (v != .string or v.string.len > limit) return error.InvalidProtocolParameters;
}
pub fn validate(method: []const u8, params: V) !void {
    if (!one(method, &methods)) return error.UnsupportedProtocolMethod;
    if (params != .object) return error.InvalidProtocolParameters;
    if (eq(method, "Input.dispatchMouseEvent")) {
        try fields(params, &.{ "type", "x", "y", "button", "buttons", "clickCount", "modifiers", "deltaX", "deltaY" });
        try optionalNumber(params, "buttons", 0, 7);
        try optionalNumber(params, "clickCount", 0, 3);
        try optionalNumber(params, "modifiers", 0, 15);
        if (params.object.get("button")) |button| if (button != .string or !one(button.string, &.{ "none", "left", "right", "middle" })) return error.InvalidProtocolParameters;
        for ([_][]const u8{ "deltaX", "deltaY" }) |key| if (params.object.get(key)) |v| {
            if (!finite(v)) return error.InvalidProtocolParameters;
        };
        const kind = J.str(J.field(params, "type"));
        if (!one(kind, &.{ "mouseMoved", "mousePressed", "mouseReleased", "mouseWheel" }) or !finite(J.field(params, "x")) or !finite(J.field(params, "y"))) return error.InvalidProtocolParameters;
        if (eq(kind, "mousePressed") or eq(kind, "mouseReleased")) {
            if (!one(J.str(J.field(params, "button")), &.{ "left", "right", "middle" })) return error.InvalidProtocolParameters;
        }
        if (eq(kind, "mouseWheel") and (!finite(J.field(params, "deltaX")) or !finite(J.field(params, "deltaY")))) return error.InvalidProtocolParameters;
    } else if (eq(method, "Input.dispatchKeyEvent")) {
        try fields(params, &.{ "type", "key", "code", "text", "unmodifiedText", "windowsVirtualKeyCode", "nativeVirtualKeyCode", "modifiers", "autoRepeat", "isKeypad", "isSystemKey", "location" });
        for ([_][]const u8{ "windowsVirtualKeyCode", "nativeVirtualKeyCode" }) |key| try optionalNumber(params, key, 0, 65535);
        try optionalNumber(params, "modifiers", 0, 15);
        try optionalNumber(params, "location", 0, 3);
        try optionalText(params, "code", 128);
        try optionalText(params, "text", 65536);
        try optionalText(params, "unmodifiedText", 65536);
        for ([_][]const u8{ "autoRepeat", "isKeypad", "isSystemKey" }) |key| if (params.object.get(key)) |v| {
            if (v != .bool) return error.InvalidProtocolParameters;
        };
        if (!one(J.str(J.field(params, "type")), &.{ "keyDown", "rawKeyDown", "keyUp", "char" })) return error.InvalidProtocolParameters;
        const key = J.str(J.field(params, "key"));
        if (key.len == 0 or key.len > 128 or J.str(J.field(params, "code")).len > 128) return error.InvalidProtocolParameters;
    } else if (eq(method, "Input.insertText")) {
        try fields(params, &.{"text"});
        const text = J.field(params, "text");
        if (text != .string or text.string.len > 1024 * 1024) return error.InvalidProtocolParameters;
    } else if (eq(method, "DOM.querySelector") or eq(method, "DOM.querySelectorAll")) {
        try fields(params, &.{ "nodeId", "selector" });
        if (!integer(J.field(params, "nodeId"), 1, std.math.maxInt(i32)) or J.field(params, "selector") != .string or J.str(J.field(params, "selector")).len > 8192) return error.InvalidProtocolParameters;
    } else if (eq(method, "DOM.getBoxModel")) {
        try fields(params, &.{ "nodeId", "backendNodeId", "objectId" });
        if (params.object.count() != 1) return error.InvalidProtocolParameters;
        try optionalNumber(params, "nodeId", 1, std.math.maxInt(i32));
        try optionalNumber(params, "backendNodeId", 1, std.math.maxInt(i32));
        try optionalText(params, "objectId", 256);
    } else if (eq(method, "DOM.getDocument") or eq(method, "Accessibility.getFullAXTree")) {
        try fields(params, if (eq(method, "DOM.getDocument")) &.{"depth"} else &.{ "depth", "frameId" });
        try optionalNumber(params, "depth", 0, 32);
        try optionalText(params, "frameId", 256);
    } else try fields(params, &.{});
}
pub const State = struct {
    frames: bool = false,
    mouse: ?V = null,
    keys: [16]?V = @splat(null),
    pub fn held(self: *const State) bool {
        if (self.mouse != null) return true;
        for (self.keys) |key| if (key != null) return true;
        return false;
    }
    pub fn prepare(self: *State, page: anytype) !void {
        if (!self.frames and eq(J.str(try page.eval("document.visibilityState")), "hidden")) {
            _ = try page.command("Emulation.setFocusEmulationEnabled", .{ .enabled = true });
            self.frames = true;
            _ = try page.command("Page.startScreencast", .{ .format = "png", .everyNthFrame = 1 });
            // Wait for an initial frame before sampling animated geometry.
            _ = try page.command("Page.captureScreenshot", .{ .format = "png", .clip = .{ .x = 0, .y = 0, .width = 1, .height = 1, .scale = 1 } });
        }
    }
    pub fn send(self: *State, page: anytype, method: []const u8, params: V) !V {
        try validate(method, params);
        if (std.mem.startsWith(u8, method, "Input.")) try self.prepare(page);
        const kind = J.str(J.field(params, "type"));
        var release_mouse = false;
        var release_key: ?usize = null;
        if (eq(method, "Input.dispatchMouseEvent")) {
            if (eq(kind, "mousePressed")) {
                if (self.mouse != null) return error.MouseAlreadyHeld;
                self.mouse = try J.val(page.a, params);
            } else if (eq(kind, "mouseReleased")) {
                if (self.mouse) |old| if (!eq(J.str(J.field(old, "button")), J.str(J.field(params, "button")))) return error.InvalidInputRelease;
                release_mouse = true;
            } else if (self.mouse) |*old| {
                try old.object.put(page.a, "x", J.field(params, "x"));
                try old.object.put(page.a, "y", J.field(params, "y"));
            }
        } else if (eq(method, "Input.dispatchKeyEvent")) {
            const key = J.str(J.field(params, "key"));
            var slot: ?usize = null;
            for (self.keys, 0..) |old, i| if (old) |v| {
                if (eq(key, J.str(J.field(v, "key")))) {
                    slot = i;
                    break;
                }
            };
            if (eq(kind, "keyUp")) release_key = slot else if (!eq(kind, "char")) {
                if (slot == null) for (self.keys, 0..) |old, i| {
                    if (old == null) {
                        slot = i;
                        break;
                    }
                };
                self.keys[slot orelse return error.HeldKeyLimitExceeded] = try J.val(page.a, params);
            }
        }
        const writes = std.mem.startsWith(u8, method, "Input.");
        page.diagnostics.phase = if (writes) .action else .inspect;
        if (writes) page.diagnostics.action = .possibly_dispatched;
        const result = try page.command(method, params);
        if (release_mouse) self.mouse = null;
        if (release_key) |i| self.keys[i] = null;
        if (writes) page.diagnostics.action = .completed;
        return result;
    }
    pub fn finish(self: *State, page: anytype) void {
        self.release(page);
        if (!self.frames) return;
        const protection = page.io.swapCancelProtection(.blocked);
        defer _ = page.io.swapCancelProtection(protection);
        const previous = page.socket.deadline_ms;
        page.socket.deadline_ms = @as(i64, @intCast(std.Io.Clock.awake.now(page.io).toMilliseconds())) + 200;
        defer page.socket.deadline_ms = previous;
        if (!page.socket.failed) _ = page.command("Page.stopScreencast", .{}) catch {};
        if (!page.socket.failed) _ = page.command("Emulation.setFocusEmulationEnabled", .{ .enabled = false }) catch {};
        self.frames = false;
    }
    pub fn release(self: *State, page: anytype) void {
        if (!self.held()) return;
        page.diagnostics.input_release = .incomplete;
        const protection = page.io.swapCancelProtection(.blocked);
        defer _ = page.io.swapCancelProtection(protection);
        const previous = page.socket.deadline_ms;
        page.socket.deadline_ms = @as(i64, @intCast(std.Io.Clock.awake.now(page.io).toMilliseconds())) + 200;
        defer page.socket.deadline_ms = previous;
        if (page.socket.failed) return;
        if (self.mouse) |v| {
            _ = page.command("Input.dispatchMouseEvent", .{ .type = "mouseReleased", .button = J.field(v, "button"), .x = J.field(v, "x"), .y = J.field(v, "y"), .buttons = 0, .clickCount = 1 }) catch return;
            self.mouse = null;
        }
        for (&self.keys) |*old| if (old.*) |v| {
            _ = page.command("Input.dispatchKeyEvent", .{ .type = "keyUp", .key = J.field(v, "key"), .code = J.str(J.field(v, "code")), .windowsVirtualKeyCode = J.number(J.field(v, "windowsVirtualKeyCode")), .modifiers = 0 }) catch return;
            old.* = null;
        };
        page.diagnostics.input_release = .complete;
    }
};
