//! Finite, independently connected observer. No browser or interception ownership.
const std = @import("std");
const C = @import("cdp");
const J = C.journey;
const Agent = C.agent;
const Session = @import("cli_session.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
const Io = std.Io;

pub const Options = struct {
    tab: []const u8 = "",
    out: []const u8 = "",
    events: []const u8 = "console,exceptions,network",
    duration: u32 = 30000,
    max_events: usize = 4096,
    max_bytes: usize = 8 * 1024 * 1024,
    body_limit: usize = 1024 * 1024,
    body_url: ?[]const u8 = null,
    body_method: ?[]const u8 = null,
    related: bool = false,
    workers: []const []const u8 = &.{},
    max_targets: usize = 64,
};
var interrupted = std.atomic.Value(bool).init(false);
fn signal(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}
fn waitSignal(io: Io) !void {
    while (!interrupted.load(.acquire)) try io.sleep(.fromMilliseconds(25), .awake);
}
fn now(io: Io) i64 {
    return @intCast(Io.Clock.awake.now(io).toMilliseconds());
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn selected(events: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, events, ',');
    while (it.next()) |event| if (eq(event, name)) return true;
    return false;
}
pub fn validate(o: Options) !void {
    if (o.tab.len == 0) return error.MissingTab;
    if (o.out.len == 0) return error.MissingOutput;
    if (o.duration == 0 or o.duration > 120000 or o.max_events == 0 or o.max_events > 4096 or o.max_bytes < 256 or o.max_bytes > 8 * 1024 * 1024 or o.body_limit == 0 or o.body_limit > 1024 * 1024) return error.InvalidLimit;
    if (o.max_targets == 0 or o.max_targets > 64 or o.workers.len > o.max_targets) return error.InvalidLimit;
    for (o.workers, 0..) |id, i| {
        if (id.len == 0 or id.len > 256) return error.InvalidWorker;
        for (o.workers[0..i]) |prior| if (eq(id, prior)) return error.InvalidWorker;
    }
    var it = std.mem.splitScalar(u8, o.events, ',');
    while (it.next()) |event| if (!eq(event, "console") and !eq(event, "exceptions") and !eq(event, "network")) return error.InvalidEvents;
    if ((o.body_url == null) != (o.body_method == null)) return error.BodyFilterRequired;
    if (o.body_url) |url| {
        if (!selected(o.events, "network") or url.len > 8192) return error.InvalidBodyFilter;
        const uri = std.Uri.parse(url) catch return error.InvalidBodyFilter;
        if ((!eq(uri.scheme, "http") and !eq(uri.scheme, "https")) or uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidBodyFilter;
        if (o.body_method.?.len == 0 or o.body_method.?.len > 32) return error.InvalidBodyFilter;
        for (o.body_method.?) |ch| if (ch < 'A' or ch > 'Z') return error.InvalidBodyFilter;
    }
}
pub fn run(a: A, backing: A, io: Io, target: []const u8, borrowed: bool, o: Options) !u8 {
    try validate(o);
    const endpoint = if (borrowed) target else blk: {
        const reply = try J.parse(a, try Session.request(a, io, target, .{ .command = "status", .tab = o.tab, .timeout_ms = 5000 }));
        if (!J.boolean(J.field(reply, "ok"))) return error.ObserverTargetUnavailable;
        break :blk try a.print("http://127.0.0.1:{d}", .{J.field(J.field(reply, "result"), "port").integer});
    };
    const file = try Io.Dir.cwd().createFile(io, o.out, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    var capture: Capture = .{ .a = backing, .io = io, .file = file, .options = o };
    defer capture.deinit();
    interrupted.store(false, .release);
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = signal }, .mask = std.posix.sigemptyset(), .flags = 0 };
    var old_int: std.posix.Sigaction = undefined;
    var old_term: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, &action, &old_int);
    defer std.posix.sigaction(.INT, &old_int, null);
    std.posix.sigaction(.TERM, &action, &old_term);
    defer std.posix.sigaction(.TERM, &old_term, null);
    const Result = union(enum) { capture: anyerror!void, signal: anyerror!void, deadline: Io.Cancelable!void };
    var storage: [3]Result = undefined;
    var race = Io.Select(Result).init(io, &storage);
    defer race.cancelDiscard();
    try race.concurrent(.capture, Capture.loop, .{ &capture, endpoint });
    try race.concurrent(.signal, waitSignal, .{io});
    // Includes a bounded startup allowance; actual duration starts at readiness.
    try race.concurrent(.deadline, Io.sleep, .{ io, .fromMilliseconds(@as(i64, o.duration) + 6000), .awake });
    const result = try race.await();
    race.cancelDiscard();
    const reason: []const u8 = switch (result) {
        .signal => "interrupted",
        .deadline => "deadline",
        .capture => |value| blk: {
            value catch |err| break :blk @errorName(err);
            break :blk "expired";
        },
    };
    capture.finishPending() catch {};
    const ok = eq(reason, "expired") and capture.dropped == 0 and capture.truncated == 0 and capture.unavailable == 0;
    try stdout(io, a, .{ .version = 1, .ok = ok, .ready = false, .reason = reason, .tab = o.tab, .events = capture.count, .bytes = capture.bytes, .dropped = capture.dropped, .truncated = capture.truncated, .unavailable_bodies = capture.unavailable });
    return if (ok) 0 else 1;
}
fn stdout(io: Io, a: A, value: anytype) !void {
    const line = try J.json(a, value);
    defer a.free(line);
    try Io.File.stdout().writeStreamingAll(io, line);
    try Io.File.stdout().writeStreamingAll(io, "\n");
}
const Origin = struct { target: []const u8 = "", kind: []const u8 = "page", session: []const u8 = "" };
const Request = struct { key: []const u8, origin: Origin, id: []const u8, method: []const u8, url: []const u8, frame: []const u8, loader: []const u8, hop: usize, body: bool, decoded_bytes: usize = 0, mime: []const u8 = "" };
const Capture = struct {
    a: A,
    io: Io,
    file: Io.File,
    options: Options,
    requests: std.StringHashMapUnmanaged(Request) = .empty,
    bodies: std.ArrayList([]const u8) = .empty,
    count: usize = 0,
    bytes: usize = 0,
    dropped: usize = 0,
    truncated: usize = 0,
    unavailable: usize = 0,
    ready: bool = false,
    tree: ?*C.target_tree.Tree = null,
    origin: Origin = .{},
    fn freeRequest(self: *Capture, r: Request) void {
        for ([_][]const u8{ r.key, r.origin.target, r.origin.kind, r.origin.session, r.id, r.method, r.url, r.frame, r.loader, r.mime }) |s| self.a.free(s);
    }
    fn deinit(self: *Capture) void {
        var it = self.requests.valueIterator();
        while (it.next()) |r| self.freeRequest(r.*);
        self.requests.deinit(self.a);
        for (self.bodies.items) |id| self.a.free(id);
        self.bodies.deinit(self.a);
    }
    fn remove(self: *Capture, id: []const u8) void {
        if (self.requests.fetchRemove(id)) |kv| self.freeRequest(kv.value);
    }
    fn write(self: *Capture, a: A, kind: []const u8, data: anytype) !void {
        if (!self.ready) return;
        if (self.count >= self.options.max_events) {
            self.dropped += 1;
            return error.EventLimitExceeded;
        }
        const line = try J.json(a, .{ .version = 1, .tab = self.options.tab, .target = self.origin.target, .target_type = self.origin.kind, .session = self.origin.session, .seq = self.count + 1, .observed_ms = Io.Clock.real.now(self.io).toMilliseconds(), .kind = kind, .data = data });
        if ((!eq(kind, "body") and line.len > 64 * 1024) or line.len + 1 > self.options.max_bytes - self.bytes) {
            self.dropped += 1;
            return error.OutputLimitExceeded;
        }
        try self.file.writeStreamingAll(self.io, line);
        try self.file.writeStreamingAll(self.io, "\n");
        self.count += 1;
        self.bytes += line.len + 1;
    }
    fn finishPending(self: *Capture) !void {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        var it = self.requests.valueIterator();
        while (it.next()) |r| if (r.body) {
            self.unavailable += 1;
            self.origin = r.origin;
            try self.write(arena.allocator(), "body", .{ .request_id = r.id, .hop = r.hop, .availability = "unavailable", .reason = "CaptureEnded" });
        };
    }
    fn loop(self: *Capture, endpoint: []const u8) !void {
        var init_arena = std.heap.ArenaAllocator.init(self.a);
        defer init_arena.deinit();
        var connection = try Agent.Connection.connect(init_arena.allocator(), self.io, endpoint);
        defer connection.disconnect();
        var socket = try connection.page(self.options.tab);
        defer socket.close();
        try socket.setAllocator(self.a);
        socket.event_handler = event;
        socket.event_context = self;
        socket.deadline_ms = now(self.io) + 5000;
        if (selected(self.options.events, "console") or selected(self.options.events, "exceptions")) _ = try Agent.call(init_arena.allocator(), &socket, "Runtime.enable", .{});
        if (selected(self.options.events, "network")) _ = try Agent.call(init_arena.allocator(), &socket, "Network.enable", .{ .maxTotalBufferSize = 8 * 1024 * 1024, .maxResourceBufferSize = self.options.body_limit });
        self.origin = .{ .target = self.options.tab };
        var tree: C.target_tree.Tree = .{ .a = self.a, .socket = &socket, .workers = self.options.related, .include_frames = self.options.related, .explicit_workers = self.options.workers, .pause_new = true, .max_targets = self.options.max_targets, .configure = configure, .configure_context = self };
        defer {
            self.ready = false;
            tree.deinit();
            self.ready = true;
        }
        if (self.options.related or self.options.workers.len > 0) {
            self.tree = &tree;
            try tree.start();
            for (self.options.workers) |id| try tree.attachWorker(init_arena.allocator(), id);
            _ = try Agent.call(init_arena.allocator(), &socket, "Runtime.evaluate", .{ .expression = "0" });
        }
        var initial: std.ArrayList(V) = .empty;
        try initial.append(init_arena.allocator(), try J.val(init_arena.allocator(), .{ .target = self.options.tab, .type = "page", .session = "" }));
        if (self.tree) |active| for (&active.sessions) |*s| if (s.active) {
            try initial.append(init_arena.allocator(), try J.val(init_arena.allocator(), .{ .target = s.target.slice(), .type = s.kind.slice(), .session = s.id.slice() }));
        };
        self.ready = true;
        try stdout(self.io, self.a, .{ .version = 1, .ok = true, .ready = true, .tab = self.options.tab, .out = self.options.out, .targets = initial.items, .duration_ms = self.options.duration });
        const end = now(self.io) + self.options.duration;
        socket.deadline_ms = end;
        while (now(self.io) < end) {
            var arena = std.heap.ArenaAllocator.init(self.a);
            defer arena.deinit();
            // A cheap round trip services events without an unbounded idle read.
            _ = Agent.call(arena.allocator(), &socket, "Runtime.evaluate", .{ .expression = "0", .returnByValue = true }) catch |err| {
                if (err == error.Timeout and now(self.io) >= end) return;
                return err;
            };
            while (self.bodies.items.len > 0) {
                const id = self.bodies.orderedRemove(0);
                defer self.a.free(id);
                try self.body(arena.allocator(), &socket, id);
                self.remove(id);
            }
            if (now(self.io) < end) try self.io.sleep(.fromMilliseconds(@min(@as(i64, 20), end - now(self.io))), .awake);
        }
    }
    fn originFor(self: *Capture, sid: []const u8) Origin {
        if (sid.len > 0) if (self.tree) |tree| for (&tree.sessions) |*s| {
            if (eq(s.id.slice(), sid)) return .{ .target = s.target.slice(), .kind = s.kind.slice(), .session = s.id.slice() };
        };
        return .{ .target = self.options.tab };
    }
    fn copyOrigin(a: A, origin: Origin) !Origin {
        return .{ .target = try a.dupe(u8, origin.target), .kind = try a.dupe(u8, origin.kind), .session = try a.dupe(u8, origin.session) };
    }
    fn configure(ctx: ?*anyopaque, tree: *C.target_tree.Tree, sid: ?[]const u8) !void {
        const self: *Capture = @ptrCast(@alignCast(ctx.?));
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const a = arena.allocator();
        if (selected(self.options.events, "network")) _ = try tree.call(a, sid, "Network.enable", .{ .maxTotalBufferSize = 8 * 1024 * 1024, .maxResourceBufferSize = self.options.body_limit });
        const previous = self.origin;
        self.origin = self.originFor(sid orelse "");
        defer self.origin = previous;
        try self.write(a, "target-ready", .{ .initial = !self.ready });
    }
    fn lost(self: *Capture, a: A, sid: []const u8) !void {
        const previous = self.origin;
        self.origin = self.originFor(sid);
        defer self.origin = previous;
        var keys: std.ArrayList([]const u8) = .empty;
        var it = self.requests.iterator();
        while (it.next()) |entry| if (eq(entry.value_ptr.origin.session, sid)) try keys.append(a, try a.dupe(u8, entry.key_ptr.*));
        for (keys.items) |key| {
            const r = self.requests.get(key).?;
            if (r.body) {
                self.unavailable += 1;
                try self.write(a, "body", .{ .request_id = r.id, .hop = r.hop, .availability = "unavailable", .reason = "TargetDetached" });
            }
            self.remove(key);
        }
        try self.write(a, "target-lost", .{ .reason = "detached" });
    }
    fn safeUrl(a: A, url: []const u8) ![]const u8 {
        const uri = std.Uri.parse(url) catch return "";
        if (!eq(uri.scheme, "http") and !eq(uri.scheme, "https")) return uri.scheme;
        const host = try (uri.host orelse return "").toRawMaybeAlloc(a);
        const path = try uri.path.toRawMaybeAlloc(a);
        return if (uri.port) |port| a.print("{s}://{s}:{d}{s}", .{ uri.scheme, host, port, path }) else a.print("{s}://{s}{s}", .{ uri.scheme, host, path });
    }
    fn event(ctx: *anyopaque, _: *C.WsSession, raw: []const u8) !void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        if (!self.ready) return;
        if (raw.len > 2 * 1024 * 1024) {
            self.dropped += 1;
            return error.EventTooLarge;
        }
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const a = arena.allocator();
        const value = try J.parse(a, raw);
        const method = J.str(J.field(value, "method"));
        const p = J.field(value, "params");
        const previous = self.origin;
        self.origin = self.originFor(J.str(J.field(value, "sessionId")));
        defer self.origin = previous;
        if (eq(method, "Target.detachedFromTarget")) return self.lost(a, J.str(J.field(p, "sessionId")));
        if (eq(method, "Runtime.consoleAPICalled") and selected(self.options.events, "console")) {
            var texts: std.ArrayList([]const u8) = .empty;
            const args = J.field(p, "args");
            var size: usize = 0;
            if (args == .array) for (args.array.items) |arg| {
                const v = J.field(arg, "value");
                const text = if (v == .string) v.string else if (v != .null) try J.json(a, v) else J.str(J.field(arg, "description"));
                var n = @min(text.len, 4096 - size);
                while (n > 0 and !std.unicode.utf8ValidateSlice(text[0..n])) n -= 1;
                if (n < text.len) self.truncated += 1;
                try texts.append(a, text[0..n]);
                size += n;
                if (size == 4096 or texts.items.len == 32) break;
            };
            if (args == .array and args.array.items.len > texts.items.len) self.truncated += 1;
            try self.write(a, "console", .{ .type = J.field(p, "type"), .text = texts.items, .timestamp = J.field(p, "timestamp"), .context = J.field(p, "executionContextId"), .source = try source(a, J.field(p, "stackTrace")) });
        } else if (eq(method, "Runtime.exceptionThrown") and selected(self.options.events, "exceptions")) {
            const d = J.field(p, "exceptionDetails");
            const text = J.str(J.field(J.field(d, "exception"), "description"));
            var length = @min(text.len, 4096);
            while (length > 0 and !std.unicode.utf8ValidateSlice(text[0..length])) length -= 1;
            if (length < text.len) self.truncated += 1;
            try self.write(a, "exception", .{ .text = text[0..length], .truncated = length < text.len, .message = J.field(d, "text"), .url = try safeUrl(a, J.str(J.field(d, "url"))), .line = J.field(d, "lineNumber"), .column = J.field(d, "columnNumber"), .timestamp = J.field(p, "timestamp"), .context = J.field(d, "executionContextId") });
        } else if (std.mem.startsWith(u8, method, "Network.") and selected(self.options.events, "network")) {
            const id = J.str(J.field(p, "requestId"));
            if (id.len == 0 or id.len > 256) return;
            const key = try a.print("{s}:{s}", .{ self.origin.session, id });
            if (eq(method, "Network.requestWillBeSent")) {
                const req = J.field(p, "request");
                const url = J.str(J.field(req, "url"));
                const verb = J.str(J.field(req, "method"));
                var hop: usize = 0;
                if (self.requests.get(key)) |old| {
                    hop = old.hop + 1;
                    try self.write(a, "redirect", .{ .request_id = id, .hop = old.hop, .url = try safeUrl(a, old.url), .status = J.field(J.field(p, "redirectResponse"), "status") });
                    self.remove(key);
                }
                if (self.requests.count() >= 4096 or url.len > 8192 or verb.len > 32 or J.str(J.field(p, "frameId")).len > 256 or J.str(J.field(p, "loaderId")).len > 256) {
                    self.dropped += 1;
                    return error.RequestLimitExceeded;
                }
                const r: Request = .{ .key = try self.a.dupe(u8, key), .origin = try copyOrigin(self.a, self.origin), .id = try self.a.dupe(u8, id), .method = try self.a.dupe(u8, verb), .url = try self.a.dupe(u8, url), .frame = try self.a.dupe(u8, J.str(J.field(p, "frameId"))), .loader = try self.a.dupe(u8, J.str(J.field(p, "loaderId"))), .hop = hop, .body = if (self.options.body_url) |filter| eq(filter, url) and eq(self.options.body_method.?, verb) else false, .mime = try self.a.dupe(u8, "") };
                try self.requests.put(self.a, r.key, r);
                try self.write(a, "request", .{ .request_id = id, .hop = hop, .method = verb, .url = try safeUrl(a, url), .frame = r.frame, .loader = r.loader, .timestamp = J.field(p, "timestamp"), .type = J.field(p, "type") });
            } else if (self.requests.getPtr(key)) |r| {
                if (eq(method, "Network.responseReceived")) {
                    const response = J.field(p, "response");
                    const mime = J.str(J.field(response, "mimeType"));
                    if (mime.len > 256) return error.EventTooLarge;
                    const copy = try self.a.dupe(u8, mime);
                    self.a.free(r.mime);
                    r.mime = copy;
                    try self.write(a, "response", .{ .request_id = id, .hop = r.hop, .status = J.field(response, "status"), .type = J.field(p, "type"), .mime = r.mime, .timestamp = J.field(p, "timestamp"), .frame = r.frame, .loader = r.loader });
                } else if (eq(method, "Network.dataReceived")) {
                    const length = J.number(J.field(p, "dataLength"));
                    if (length > 0) r.decoded_bytes = @min(self.options.body_limit + 1, r.decoded_bytes + @as(usize, @intCast(@min(length, 1024 * 1024 + 1))));
                } else if (eq(method, "Network.loadingFinished") or eq(method, "Network.loadingFailed")) {
                    try self.write(a, if (eq(method, "Network.loadingFinished")) "finished" else "failed", .{ .request_id = id, .hop = r.hop, .timestamp = J.field(p, "timestamp"), .bytes = J.field(p, "encodedDataLength"), .failure = J.field(p, "errorText") });
                    if (r.body and eq(method, "Network.loadingFinished")) {
                        if (r.decoded_bytes > self.options.body_limit) {
                            self.truncated += 1;
                            try self.write(a, "body", .{ .request_id = id, .hop = r.hop, .availability = "oversized" });
                            self.remove(key);
                        } else try self.bodies.append(self.a, try self.a.dupe(u8, key));
                    } else {
                        if (r.body) {
                            self.unavailable += 1;
                            try self.write(a, "body", .{ .request_id = id, .hop = r.hop, .availability = "unavailable", .reason = "LoadingFailed" });
                        }
                        self.remove(key);
                    }
                }
            }
        }
    }
    fn source(a: A, stack: V) !V {
        const frames = J.field(stack, "callFrames");
        if (frames != .array or frames.array.items.len == 0) return .null;
        const frame = frames.array.items[0];
        return J.val(a, .{ .url = try safeUrl(a, J.str(J.field(frame, "url"))), .line = J.field(frame, "lineNumber"), .column = J.field(frame, "columnNumber") });
    }
    fn body(self: *Capture, a: A, socket: *C.WsSession, key: []const u8) !void {
        const r = self.requests.get(key) orelse return;
        const id = try a.dupe(u8, r.id);
        const previous = self.origin;
        self.origin = try copyOrigin(a, r.origin);
        defer self.origin = previous;
        // Copy correlation before a round trip can dispatch more events.
        const hop = r.hop;
        const textual = std.mem.startsWith(u8, r.mime, "text/") or std.mem.indexOf(u8, r.mime, "json") != null or std.mem.indexOf(u8, r.mime, "javascript") != null or std.mem.indexOf(u8, r.mime, "xml") != null;
        if (!textual) return self.write(a, "body", .{ .request_id = id, .hop = hop, .availability = "binary", .text = @as(?[]const u8, null) });
        const result = C.target_tree.callSession(a, socket, if (self.origin.session.len > 0) self.origin.session else null, "Network.getResponseBody", .{ .requestId = id }) catch |err| {
            if (!self.requests.contains(key)) return;
            self.unavailable += 1;
            try self.write(a, "body", .{ .request_id = id, .hop = hop, .availability = "unavailable", .reason = @errorName(err) });
            if (socket.failed) return err;
            return;
        };
        const raw = J.str(J.field(result, "body"));
        const base64 = J.boolean(J.field(result, "base64Encoded"));
        const size = if (base64) try std.base64.standard.Decoder.calcSizeForSlice(raw) else raw.len;
        if (size > self.options.body_limit) {
            self.truncated += 1;
            return self.write(a, "body", .{ .request_id = id, .hop = hop, .availability = "oversized", .bytes = size });
        }
        const bytes = if (base64) blk: {
            const b = try a.alloc(u8, size);
            try std.base64.standard.Decoder.decode(b, raw);
            break :blk b;
        } else raw;
        if (!std.unicode.utf8ValidateSlice(bytes)) return self.write(a, "body", .{ .request_id = id, .hop = hop, .availability = "binary" });
        try self.write(a, "body", .{ .request_id = id, .hop = hop, .availability = "complete", .text = bytes });
    }
};

test "request identity and detach cleanup are scoped by CDP session" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile(io, "events.jsonl", .{});
    defer file.close(io);
    var socket: C.WsSession = undefined; // Events below perform no socket I/O.
    var tree: C.target_tree.Tree = .{ .a = a, .socket = &socket };
    for ([_][]const u8{ "a", "b" }, 0..) |sid, i| {
        const s = &tree.sessions[i];
        s.active = true;
        @memcpy(s.id.bytes[0..sid.len], sid);
        s.id.len = @intCast(sid.len);
        @memcpy(s.target.bytes[0..sid.len], sid);
        s.target.len = @intCast(sid.len);
        @memcpy(s.kind.bytes[0..6], "worker");
        s.kind.len = 6;
    }
    var capture: Capture = .{ .a = a, .io = io, .file = file, .options = .{ .tab = "root", .body_url = "http://fixture/body", .body_method = "POST" }, .ready = true, .tree = &tree };
    defer capture.deinit();
    for ([_][]const u8{ "a", "b" }) |sid| {
        const raw = try J.json(a, .{ .method = "Network.requestWillBeSent", .sessionId = sid, .params = .{ .requestId = "same-id", .request = .{ .method = "POST", .url = "http://fixture/body" } } });
        defer a.free(raw);
        try Capture.event(&capture, &socket, raw);
    }
    try std.testing.expectEqual(@as(usize, 2), capture.requests.count());
    try Capture.event(&capture, &socket, "{\"method\":\"Network.loadingFinished\",\"sessionId\":\"b\",\"params\":{\"requestId\":\"same-id\"}}");
    try std.testing.expectEqualStrings("b:same-id", capture.bodies.items[0]);
    try Capture.event(&capture, &socket, "{\"method\":\"Target.detachedFromTarget\",\"params\":{\"sessionId\":\"a\"}}");
    try std.testing.expectEqual(@as(usize, 1), capture.requests.count());
    try std.testing.expect(capture.requests.contains("b:same-id"));
    try std.testing.expectEqual(@as(usize, 1), capture.unavailable);
    const bytes = try temp.dir.readFileAlloc(io, "events.jsonl", a, .limited(10000));
    defer a.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "TargetDetached") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"target\":\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"target\":\"b\"") != null);
}
