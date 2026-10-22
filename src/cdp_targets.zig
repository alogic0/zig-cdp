//! Bounded flattened sessions for targets related to one page connection.
//! Owns attachment state only; never closes targets or installs process policy.
const std = @import("std");
const C = @import("cdp.zig");
const J = C.journey;
const A = std.mem.Allocator;
const V = std.json.Value;
const Text = struct {
    bytes: [256]u8 = undefined,
    len: u16 = 0,
    fn set(self: *Text, value: []const u8) !void {
        if (value.len > self.bytes.len) return error.TargetIdentityTooLong;
        @memcpy(self.bytes[0..value.len], value);
        self.len = @intCast(value.len);
    }
    pub fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }
};
pub const Session = struct {
    active: bool = false,
    id: Text = .{},
    target: Text = .{},
    kind: Text = .{},
    parent: Text = .{},
};
pub const Context = struct { active: bool = false, frame: Text = .{}, session: Text = .{}, unique: Text = .{}, id: i64 = 0 };
pub const Tree = struct {
    a: A,
    socket: *C.WsSession,
    sessions: [64]Session = @splat(.{}),
    contexts: [256]Context = @splat(.{}),
    root: Text = .{},
    workers: bool = false,
    include_frames: bool = true,
    explicit_workers: []const []const u8 = &.{},
    pause_new: bool = false,
    max_targets: usize = 64,
    old_handler: ?*const fn (*anyopaque, *C.WsSession, []const u8) anyerror!void = null,
    old_context: ?*anyopaque = null,
    configure: ?*const fn (?*anyopaque, *Tree, ?[]const u8) anyerror!void = null,
    configure_context: ?*anyopaque = null,
    installed: bool = false,
    closing: bool = false,

    pub fn start(self: *Tree) !void {
        self.old_handler = self.socket.event_handler;
        self.old_context = self.socket.event_context;
        self.socket.event_handler = event;
        self.socket.event_context = self;
        self.installed = true;
        errdefer self.deinit();
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const a = arena.allocator();
        const info = J.field(try self.call(a, null, "Target.getTargetInfo", .{}), "targetInfo");
        try self.root.set(J.str(J.field(info, "targetId")));
        // Replay default contexts on this connection, including when a library
        // caller enabled Runtime before installing the context tracker.
        _ = try self.call(a, null, "Runtime.disable", .{});
        _ = try self.call(a, null, "Runtime.enable", .{});
        try self.autoAttach(a, null, true);
    }
    pub fn deinit(self: *Tree) void {
        if (!self.installed) return;
        self.closing = true;
        const protect = self.socket.io.swapCancelProtection(.blocked);
        defer _ = self.socket.io.swapCancelProtection(protect);
        const deadline = self.socket.deadline_ms;
        self.socket.deadline_ms = @intCast(std.Io.Clock.awake.now(self.socket.io).toMilliseconds() + 200);
        defer self.socket.deadline_ms = deadline;
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const a = arena.allocator();
        for (&self.sessions) |*s| if (s.active and !self.socket.failed) {
            _ = self.call(a, s.id.slice(), "Runtime.runIfWaitingForDebugger", .{}) catch {};
        };
        if (!self.socket.failed) self.autoAttach(a, null, false) catch {};
        for (&self.sessions) |*s| if (s.active and !self.socket.failed) {
            _ = self.call(a, if (s.parent.len > 0) s.parent.slice() else null, "Target.detachFromTarget", .{ .sessionId = s.id.slice() }) catch {};
        };
        self.socket.event_handler = self.old_handler;
        self.socket.event_context = self.old_context;
        self.installed = false;
    }
    fn autoAttach(self: *Tree, a: A, sid: ?[]const u8, enabled: bool) !void {
        if (!enabled) {
            _ = try self.call(a, sid, "Target.setAutoAttach", .{ .autoAttach = false, .waitForDebuggerOnStart = false, .flatten = true });
            return;
        }
        _ = try self.call(a, sid, "Target.setAutoAttach", .{ .autoAttach = true, .waitForDebuggerOnStart = self.pause_new, .flatten = true, .filter = .{ .{ .type = "iframe", .exclude = !self.include_frames }, .{ .type = "worker", .exclude = !self.workers and !self.pause_new }, .{ .type = "shared_worker", .exclude = true }, .{ .type = "service_worker", .exclude = true }, .{ .exclude = true } } });
    }
    pub fn attachWorker(self: *Tree, a: A, id: []const u8) !void {
        if (id.len == 0 or id.len > 256) return error.InvalidWorker;
        for (self.sessions) |s| if (s.active and eq(s.target.slice(), id)) return;
        const info = J.field(try self.call(a, null, "Target.getTargetInfo", .{ .targetId = id }), "targetInfo");
        if (!workerKind(J.str(J.field(info, "type")))) return error.NotWorkerTarget;
        _ = try self.call(a, null, "Target.attachToTarget", .{ .targetId = id, .flatten = true });
    }
    pub fn call(self: *Tree, a: A, sid: ?[]const u8, method: []const u8, params: anytype) !V {
        return callSession(a, self.socket, sid, method, params);
    }
    pub fn session(self: *Tree, sid: []const u8) ?*Session {
        for (&self.sessions) |*s| if (s.active and eq(s.id.slice(), sid)) return s;
        return null;
    }
    pub fn context(self: *Tree, frame: []const u8) ?*Context {
        for (&self.contexts) |*c| if (c.active and eq(c.frame.slice(), frame)) return c;
        return null;
    }
    fn event(ctx: *anyopaque, socket: *C.WsSession, raw: []const u8) !void {
        const self: *Tree = @ptrCast(@alignCast(ctx));
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const a = arena.allocator();
        const v = try J.parse(a, raw);
        const method = J.str(J.field(v, "method"));
        const p = J.field(v, "params");
        const route = J.str(J.field(v, "sessionId"));
        if (eq(method, "Target.attachedToTarget")) {
            const sid = J.str(J.field(p, "sessionId"));
            const info = J.field(p, "targetInfo");
            if (self.closing) {
                _ = try self.call(a, sid, "Runtime.runIfWaitingForDebugger", .{});
                return;
            }
            const kind = J.str(J.field(info, "type"));
            const target = J.str(J.field(info, "targetId"));
            var explicit = false;
            for (self.explicit_workers) |id| if (eq(id, target)) {
                explicit = true;
                break;
            };
            // Chrome can pause a new dedicated worker even when its type is
            // excluded from an auto-attach filter. Receive it so every paused
            // worker is resumed, then detach without enabling observation.
            if (eq(kind, "worker") and !self.workers and !explicit) {
                _ = try self.call(a, sid, "Runtime.runIfWaitingForDebugger", .{});
                _ = self.call(a, if (route.len > 0) route else null, "Target.detachFromTarget", .{ .sessionId = sid }) catch |err| {
                    if (err != error.CdpCommandFailed and err != error.SessionDetached) return err;
                    return;
                };
                return;
            }
            const slot = blk: {
                var active: usize = 0;
                for (self.sessions) |s| if (s.active) {
                    active += 1;
                };
                if (active >= self.max_targets) {
                    _ = self.call(a, sid, "Runtime.runIfWaitingForDebugger", .{}) catch {};
                    return error.TargetLimitExceeded;
                }
                for (&self.sessions) |*s| if (!s.active) break :blk s;
                return error.TargetLimitExceeded;
            };
            slot.* = .{ .active = true };
            try slot.id.set(sid);
            try slot.target.set(J.str(J.field(info, "targetId")));
            try slot.kind.set(J.str(J.field(info, "type")));
            try slot.parent.set(route);
            // Resume even when setup fails. A bounded disconnect also releases
            // this observer's debugger attachment, never the target itself.
            errdefer {
                const protection = socket.io.swapCancelProtection(.blocked);
                defer _ = socket.io.swapCancelProtection(protection);
                _ = self.call(a, sid, "Runtime.runIfWaitingForDebugger", .{}) catch {};
            }
            self.prepare(a, sid, kind) catch |err| {
                if (err == error.SessionDetached) return;
                return err;
            };
        } else if (eq(method, "Target.detachedFromTarget")) {
            const sid = J.str(J.field(p, "sessionId"));
            const detached = self.session(sid) orelse return;
            detached.active = false;
            for (&self.contexts) |*c| if (c.active and eq(c.session.slice(), sid)) {
                c.active = false;
            };
        } else if (eq(method, "Runtime.executionContextCreated")) {
            const info = J.field(p, "context");
            const aux = J.field(info, "auxData");
            const frame = J.str(J.field(aux, "frameId"));
            if (J.boolean(J.field(aux, "isDefault")) and frame.len > 0) {
                const slot = self.context(frame) orelse blk: {
                    for (&self.contexts) |*c| if (!c.active) break :blk c;
                    return error.ContextLimitExceeded;
                };
                try slot.frame.set(frame);
                try slot.session.set(route);
                try slot.unique.set(J.str(J.field(info, "uniqueId")));
                slot.id = J.number(J.field(info, "id"));
                slot.active = true;
            }
        } else if (eq(method, "Runtime.executionContextsCleared") or eq(method, "Runtime.executionContextDestroyed")) {
            for (&self.contexts) |*c| if (c.active and eq(c.session.slice(), route) and
                (eq(method, "Runtime.executionContextsCleared") or c.id == J.number(J.field(p, "executionContextId"))))
            {
                c.active = false;
            };
        }
        if (self.old_handler) |handler| try handler(self.old_context.?, socket, raw);
    }
    fn prepare(self: *Tree, a: A, sid: []const u8, kind: []const u8) !void {
        if (eq(kind, "iframe")) _ = try self.call(a, sid, "Page.enable", .{});
        _ = try self.call(a, sid, "Runtime.enable", .{});
        if (self.configure) |configure| try configure(self.configure_context, self, sid);
        try self.autoAttach(a, sid, true);
        _ = try self.call(a, sid, "Runtime.runIfWaitingForDebugger", .{});
    }
    pub fn frames(self: *Tree, a: A) !V {
        var result: std.ArrayList(V) = .empty;
        try self.collect(a, null, &result);
        for (&self.sessions) |*s| if (s.active and eq(s.kind.slice(), "iframe")) try self.collect(a, s.id.slice(), &result);
        return J.val(a, result.items);
    }
    fn collect(self: *Tree, a: A, sid: ?[]const u8, result: *std.ArrayList(V)) !void {
        const tree = J.field(try self.call(a, sid, "Page.getFrameTree", .{}), "frameTree");
        try collectFrames(a, tree, "", sid orelse "", result, 0);
    }
};
fn collectFrames(a: A, tree: V, parent: []const u8, sid: []const u8, result: *std.ArrayList(V), depth: usize) !void {
    if (depth > 16 or result.items.len >= 128) return error.FrameLimitExceeded;
    const f = J.field(tree, "frame");
    const id = J.str(J.field(f, "id"));
    if (id.len == 0) return error.InvalidProtocolReply;
    var found: ?usize = null;
    for (result.items, 0..) |old, i| if (eq(J.str(J.field(old, "id")), id)) {
        found = i;
        break;
    };
    const p = if (parent.len > 0) parent else J.str(J.field(f, "parentId"));
    var record = try J.val(a, .{ .id = id, .parent = p, .url = J.field(f, "url"), .name = J.field(f, "name"), .session = sid });
    if (found) |i| {
        // The child's own tree knows its execution route; preserve the link
        // supplied by its parent if Chrome omits parentId in the child reply.
        if (p.len == 0) try record.object.put(a, "parent", J.field(result.items[i], "parent"));
        result.items[i] = record;
    } else try result.append(a, record);
    const children = J.field(tree, "childFrames");
    if (children == .array) for (children.array.items) |child| try collectFrames(a, child, id, sid, result, depth + 1);
}
pub fn callSession(a: A, socket: *C.WsSession, sid: ?[]const u8, method: []const u8, params: anytype) !V {
    const args = if (@TypeOf(params) == @TypeOf(.{})) try a.dupe(u8, "{}") else try J.json(a, params);
    defer a.free(args);
    const raw = try socket.callSession(sid, method, args);
    defer socket.alloc.free(raw);
    const reply = try J.parse(a, raw);
    if (J.field(reply, "error") != .null) {
        return error.CdpCommandFailed;
    }
    return J.field(reply, "result");
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn workerKind(kind: []const u8) bool {
    return eq(kind, "worker") or eq(kind, "shared_worker") or eq(kind, "service_worker");
}
pub fn workers(a: A, socket: *C.WsSession) !V {
    const targets = J.field(try callSession(a, socket, null, "Target.getTargets", .{}), "targetInfos");
    if (targets != .array) return error.InvalidProtocolReply;
    var result: std.ArrayList(V) = .empty;
    for (targets.array.items) |target| {
        if (!workerKind(J.str(J.field(target, "type")))) continue;
        if (result.items.len == 2048) return error.TargetLimitExceeded;
        try result.append(a, try J.val(a, .{ .id = J.field(target, "targetId"), .type = J.field(target, "type"), .url = J.field(target, "url"), .title = J.field(target, "title"), .context = J.field(target, "browserContextId"), .opener = J.field(target, "openerId") }));
    }
    return J.val(a, result.items);
}
