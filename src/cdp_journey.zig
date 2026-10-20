//! Owned browser sessions and observable input for native acceptance runners.
const std = @import("std");
const cdp = @import("cdp.zig");
const process = @import("process");
pub const V = std.json.Value;
const A = std.mem.Allocator;

pub fn field(v: V, key: []const u8) V {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
pub fn str(v: V) []const u8 {
    return if (v == .string) v.string else "";
}
pub fn boolean(v: V) bool {
    return v == .bool and v.bool;
}
pub fn number(v: V) i64 {
    return switch (v) {
        .integer => v.integer,
        .float => @intFromFloat(v.float),
        else => 0,
    };
}
pub fn json(a: A, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, value, .{});
}
pub fn parse(a: A, bytes: []const u8) !V {
    return std.json.parseFromSliceLeaky(V, a, bytes, .{ .allocate = .alloc_always });
}
pub fn val(a: A, value: anytype) !V {
    const bytes = try json(a, value);
    defer a.free(bytes);
    return parse(a, bytes);
}
pub fn path(url: []const u8) []const u8 {
    const start = if (std.mem.indexOf(u8, url, "://")) |n| n + 3 else 0;
    const slash = std.mem.indexOfScalarPos(u8, url, start, '/') orelse return "/";
    const end = std.mem.indexOfScalarPos(u8, url, slash, '?') orelse url.len;
    return url[slash..end];
}
pub fn pathQuery(url: []const u8) []const u8 {
    const start = if (std.mem.indexOf(u8, url, "://")) |n| n + 3 else 0;
    return url[std.mem.indexOfScalarPos(u8, url, start, '/') orelse return "/" ..];
}
fn now(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).toMilliseconds());
}

pub const Browser = struct {
    a: A,
    io: std.Io,
    child: process.Child,
    stopped: bool = false,
    client: cdp.CdpClient,
    socket: cdp.WsSession,
    profile: []const u8,
    downloads_dir: []const u8,
    downloads: std.ArrayList(V) = .empty,
    version: []const u8,

    pub const Options = struct {
        executable: ?[]const u8 = null,
        headless: bool = true,
    };

    pub fn start(a: A, io: std.Io) !*Browser {
        return startWithOptions(a, io, .{});
    }

    pub fn startWithOptions(a: A, io: std.Io, options: Options) !*Browser {
        var random: [12]u8 = undefined;
        io.random(&random);
        const profile = try a.print("/tmp/owned-cdp-{s}", .{std.fmt.bytesToHex(random, .lower)});
        try std.Io.Dir.cwd().createDir(io, profile, .fromMode(0o700));
        errdefer std.Io.Dir.cwd().deleteTree(io, profile) catch {};
        const arg = try a.print("--user-data-dir={s}", .{profile});
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(a);
        try argv.append(a, options.executable orelse cdp.findBrowserExecutable(io) orelse return error.NoBrowserFound);
        if (options.headless) try argv.append(a, "--headless=new");
        try argv.appendSlice(a, &.{ "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0", arg, "--no-first-run", "--no-default-browser-check", "--disable-sync", "--disable-background-networking", "--disable-search-engine-choice-screen", "--force-color-profile=srgb", "about:blank" });
        var child = try process.Child.spawn(a, io, .{ .argv = argv.items });
        errdefer child.deinit();
        const active = try a.print("{s}/DevToolsActivePort", .{profile});
        var port: u16 = 0;
        const deadline = now(io) + 10000;
        while (now(io) < deadline) {
            if (try child.poll() != null) return error.BrowserExited;
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, active, a, .limited(4096)) catch {
                try std.Io.sleep(io, .fromMilliseconds(50), .awake);
                continue;
            };
            defer a.free(bytes);
            port = try std.fmt.parseInt(u16, bytes[0 .. std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len], 10);
            break;
        }
        if (port == 0) return error.BrowserLaunchTimeout;
        const client = cdp.CdpClient.init(a, io, port);
        var socket = try client.connectBrowser();
        errdefer socket.close();
        const self = try a.create(Browser);
        self.* = .{ .a = a, .io = io, .child = child, .client = client, .socket = socket, .profile = profile, .downloads_dir = try a.print("{s}/downloads", .{profile}), .version = "" };
        try std.Io.Dir.cwd().createDir(io, self.downloads_dir, .default_dir);
        self.socket.event_context = self;
        self.socket.event_handler = onEvent;
        const info = try self.command("Browser.getVersion", .{});
        self.version = str(field(info, "product"));
        return self;
    }
    pub fn stop(self: *Browser) void {
        if (self.stopped) return;
        self.stopped = true;
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        // Bound graceful CDP closure as well as process exit.
        const Closed = union(enum) { protocol: anyerror!void, deadline: std.Io.Cancelable!void };
        var results: [2]Closed = undefined;
        var closing = std.Io.Select(Closed).init(self.io, &results);
        closing.async(.protocol, closeProtocol, .{self});
        closing.async(.deadline, std.Io.sleep, .{ self.io, .fromSeconds(2), .awake });
        _ = closing.await() catch {};
        closing.cancelDiscard();
        self.socket.close();
        _ = self.child.wait(2000) catch {
            _ = self.child.stop(0) catch {};
        };
        self.child.deinit();
        std.Io.Dir.cwd().deleteTree(self.io, self.profile) catch |err| {
            std.debug.print("Owned browser profile cleanup failed: {s}: {s}\n", .{ self.profile, @errorName(err) });
        };
    }
    fn closeProtocol(self: *Browser) !void {
        _ = try self.command("Browser.close", .{});
    }
    pub fn command(self: *Browser, method: []const u8, params: anytype) !V {
        return commandValue(self.a, &self.socket, method, params);
    }
    fn onEvent(ctx: *anyopaque, _: *cdp.WsSession, raw: []const u8) anyerror!void {
        const self: *Browser = @ptrCast(@alignCast(ctx));
        const v = try parse(self.a, raw);
        const method = str(field(v, "method"));
        if (std.mem.startsWith(u8, method, "Browser.download")) try self.downloads.append(self.a, v);
    }
    pub fn page(self: *Browser, origins: []const []const u8) !*Page {
        const context = str(field(try self.command("Target.createBrowserContext", .{}), "browserContextId"));
        errdefer _ = self.command("Target.disposeBrowserContext", .{ .browserContextId = context }) catch {};
        const id = str(field(try self.command("Target.createTarget", .{ .url = "about:blank", .browserContextId = context }), "targetId"));
        const ws = try self.a.print("/devtools/page/{s}", .{id});
        var socket = try self.client.connectWs(ws);
        errdefer socket.close();
        const p = try self.a.create(Page);
        p.* = .{ .browser = self, .a = self.a, .io = self.io, .socket = socket, .context = context, .target = id, .origins = origins };
        p.socket.event_context = p;
        p.socket.event_handler = Page.onEvent;
        _ = try p.command("Page.enable", .{});
        _ = try p.command("Runtime.enable", .{});
        _ = try p.command("Network.enable", .{ .maxTotalBufferSize = 64 * 1024 * 1024, .maxResourceBufferSize = 20 * 1024 * 1024, .maxPostDataSize = 1024 * 1024, .enableDurableMessages = true });
        _ = try p.command("Fetch.enable", .{ .patterns = .{.{ .urlPattern = "*", .requestStage = "Request" }} });
        _ = try p.command("Emulation.setDeviceMetricsOverride", .{ .width = 1280, .height = 720, .deviceScaleFactor = 1, .mobile = false });
        _ = try self.command("Browser.setDownloadBehavior", .{ .behavior = "allowAndName", .browserContextId = context, .downloadPath = self.downloads_dir, .eventsEnabled = true });
        try p.initScript(@embedFile("cdp_locators.js"));
        _ = try p.eval(@embedFile("cdp_locators.js"));
        return p;
    }
};

fn commandValue(a: A, socket: *cdp.WsSession, method: []const u8, params: anytype) !V {
    const args = if (@TypeOf(params) == @TypeOf(.{})) try a.dupe(u8, "{}") else try json(a, params);
    defer a.free(args);
    const raw = try socket.call(method, args);
    defer a.free(raw);
    const value = try parse(a, raw);
    if (field(value, "error") != .null) {
        if (!std.mem.eql(u8, method, "Network.getResponseBody"))
            std.debug.print("CDP command failed: {s}: {s}\n", .{ method, str(field(field(value, "error"), "message")) });
        return error.CdpCommandFailed;
    }
    return field(value, "result");
}

fn interceptionResult(value: V) !void {
    const failure = field(value, "error");
    if (failure != .null) {
        const code = field(failure, "code");
        const message = field(failure, "message");
        // A navigation may cancel the request before its queued event is read.
        if (code == .integer and code.integer == -32602 and message == .string and
            std.mem.eql(u8, message.string, "Invalid InterceptionId.")) return;
        return error.CdpCommandFailed;
    }
    if (field(value, "result") != .object) return error.InvalidProtocolReply;
}

fn resolveInterception(a: A, socket: *cdp.WsSession, method: []const u8, params: anytype) !void {
    const args = try json(a, params);
    defer a.free(args);
    const raw = try socket.call(method, args);
    defer a.free(raw);
    try interceptionResult(try parse(a, raw));
}

test "only the exact stale interception error is a completed cancellation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try interceptionResult(try parse(a, "{\"result\":{}}"));
    try interceptionResult(try parse(a, "{\"error\":{\"code\":-32602,\"message\":\"Invalid InterceptionId.\"}}"));
    for ([_][]const u8{
        "{\"error\":{\"code\":-1,\"message\":\"Invalid InterceptionId.\"}}",
        "{\"error\":{\"code\":\"-32602\",\"message\":\"Invalid InterceptionId.\"}}",
        "{\"error\":{\"code\":-32602,\"message\":\"Other failure\"}}",
        "{\"error\":{}}",
    }) |raw| try std.testing.expectError(error.CdpCommandFailed, interceptionResult(try parse(a, raw)));
    try std.testing.expectError(error.InvalidProtocolReply, interceptionResult(try parse(a, "{}")));
}

pub const Request = struct {
    id: []const u8,
    url: []const u8,
    method: []const u8,
    post_data: []const u8,
    status: i64 = 0,
    headers: V = .null,
    body: ?[]const u8 = null,
    finished: bool = false,
    failed: bool = false,
    body_unavailable: bool = false,
    pub fn header(self: *const Request, name: []const u8) V {
        if (self.headers != .object) return .null;
        var it = self.headers.object.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return entry.value_ptr.*;
        }
        return .null;
    }
    pub fn response(self: *Request, a: A) !V {
        return val(a, .{ .path = path(self.url), .status = self.status, .body = try parse(a, self.body orelse return error.ResponseBodyUnavailable) });
    }
    pub fn requestJson(self: *Request, a: A) !V {
        return parse(a, self.post_data);
    }
};

pub const Page = struct {
    browser: *Browser,
    a: A,
    io: std.Io,
    socket: cdp.WsSession,
    context: []const u8,
    target: []const u8,
    origins: []const []const u8,
    requests: std.ArrayList(*Request) = .empty,
    errors: std.ArrayList([]const u8) = .empty,
    timeout_ms: i64 = 30000,
    next_handle: usize = 0,
    closed: bool = false,
    allow_unload: bool = false,

    pub fn close(self: *Page) void {
        if (self.closed) return;
        self.closed = true;
        self.socket.close();
        _ = self.browser.command("Target.disposeBrowserContext", .{ .browserContextId = self.context }) catch {};
    }
    pub fn command(self: *Page, method: []const u8, params: anytype) !V {
        return commandValue(self.a, &self.socket, method, params);
    }
    pub fn initScript(self: *Page, source: []const u8) !void {
        _ = try self.command("Page.addScriptToEvaluateOnNewDocument", .{ .source = source });
    }
    pub fn eval(self: *Page, expression: []const u8) !V {
        const result = try self.command("Runtime.evaluate", .{ .expression = expression, .awaitPromise = true, .returnByValue = true });
        if (field(result, "exceptionDetails") != .null) {
            std.debug.print("Browser evaluation failed: {s}\n", .{str(field(field(field(result, "exceptionDetails"), "exception"), "description"))});
            return error.BrowserEvaluationFailed;
        }
        return field(field(result, "result"), "value");
    }
    pub fn evaluate(self: *Page, function: []const u8, arg: anytype) !V {
        return self.eval(try self.a.print("({s})({s})", .{ function, try json(self.a, arg) }));
    }
    pub fn wait(self: *Page, expression: []const u8) !void {
        const deadline = now(self.io) + self.timeout_ms;
        while (now(self.io) < deadline) {
            const result = self.eval(expression) catch .null;
            if (boolean(result)) return;
            try self.pump();
            try std.Io.sleep(self.io, .fromMilliseconds(50), .awake);
        }
        std.debug.print("Browser condition timeout: {s}\n", .{expression});
        return error.BrowserConditionTimeout;
    }
    pub fn goto(self: *Page, target_url: []const u8) !void {
        self.allow_unload = true;
        defer self.allow_unload = false;
        const old = try self.eval("performance.timeOrigin");
        _ = try self.command("Page.navigate", .{ .url = target_url });
        try self.wait(try self.a.print("performance.timeOrigin !== {s}", .{try json(self.a, old)}));
        try self.wait("document.readyState === 'complete' && typeof window.__cdp === 'object'");
    }
    pub fn reload(self: *Page) !void {
        self.allow_unload = true;
        defer self.allow_unload = false;
        const old = try self.eval("performance.timeOrigin");
        _ = try self.command("Page.reload", .{});
        try self.wait(try self.a.print("performance.timeOrigin !== {s}", .{try json(self.a, old)}));
        try self.wait("document.readyState === 'complete' && typeof window.__cdp === 'object'");
    }
    pub fn url(self: *Page) ![]const u8 {
        return str(try self.eval("location.href"));
    }
    pub fn body(self: *Page) ![]const u8 {
        return str(try self.eval("document.body.innerText"));
    }
    pub fn mark(self: *Page) !usize {
        try self.pump();
        return self.requests.items.len;
    }
    pub const Match = struct { after: usize, method: []const u8, path: []const u8, query: ?[]const u8 = null, query_key: []const u8 = "q" };
    pub fn response(self: *Page, match: Match) !*Request {
        return self.responseAny(&.{match});
    }
    pub fn responseAny(self: *Page, matches: []const Match) !*Request {
        if (matches.len == 0) return error.EmptyResponseMatch;
        const deadline = now(self.io) + self.timeout_ms;
        while (now(self.io) < deadline) {
            try self.pump();
            for (self.requests.items, 0..) |r, index| for (matches) |match| {
                if (index < match.after) continue;
                if (!std.mem.eql(u8, r.method, match.method) or !std.mem.eql(u8, path(r.url), match.path) or r.status == 0 or !r.finished) continue;
                if (match.query) |query| {
                    const matched = try self.evaluate("x => (new URL(x.url).searchParams.get(x.key) || '') === x.query", .{ .url = r.url, .key = match.query_key, .query = query });
                    if (!boolean(matched)) continue;
                }
                return r;
            };
            try std.Io.sleep(self.io, .fromMilliseconds(50), .awake);
        }
        for (matches) |match| std.debug.print("Response timeout: {s} {s}\n", .{ match.method, match.path });
        return error.ResponseTimeout;
    }
    pub fn pump(self: *Page) !void {
        _ = try self.command("Runtime.evaluate", .{ .expression = "0", .returnByValue = true });
        // Body commands can deliver completion events for earlier requests.
        // Drain those completions too before publishing a response or snapshot.
        var captured = true;
        while (captured) {
            captured = false;
            var i: usize = 0;
            while (i < self.requests.items.len) : (i += 1) {
                const r = self.requests.items[i];
                if (!r.finished or r.failed or r.body != null or r.body_unavailable or r.status == 0) continue;
                captured = true;
                // Body ownership is bounded by Network.enable and the wire frame limit.
                const result = self.command("Network.getResponseBody", .{ .requestId = r.id }) catch {
                    r.body_unavailable = true;
                    continue;
                };
                const body_bytes = str(field(result, "body"));
                if (boolean(field(result, "base64Encoded"))) {
                    const decoded = try self.a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(body_bytes));
                    try std.base64.standard.Decoder.decode(decoded, body_bytes);
                    r.body = decoded;
                } else r.body = body_bytes;
            }
        }
    }
    fn find(self: *Page, id: []const u8) ?*Request {
        var n = self.requests.items.len;
        while (n > 0) {
            n -= 1;
            if (std.mem.eql(u8, self.requests.items[n].id, id)) return self.requests.items[n];
        }
        return null;
    }
    fn onEvent(ctx: *anyopaque, _: *cdp.WsSession, raw: []const u8) anyerror!void {
        const self: *Page = @ptrCast(@alignCast(ctx));
        const v = try parse(self.a, raw);
        const method = str(field(v, "method"));
        const p = field(v, "params");
        if (std.mem.eql(u8, method, "Page.javascriptDialogOpening")) {
            const accepted_unload = self.allow_unload and std.mem.eql(u8, str(field(p, "type")), "beforeunload");
            _ = try self.command("Page.handleJavaScriptDialog", .{ .accept = accepted_unload });
            if (!accepted_unload) return error.UnexpectedBrowserDialog;
        } else if (std.mem.eql(u8, method, "Fetch.requestPaused")) {
            const url_value = str(field(field(p, "request"), "url"));
            var allowed = std.mem.startsWith(u8, url_value, "data:") or std.mem.startsWith(u8, url_value, "blob:") or std.mem.eql(u8, url_value, "about:blank");
            for (self.origins) |origin| {
                if (std.mem.startsWith(u8, url_value, origin) and (url_value.len == origin.len or url_value[origin.len] == '/')) allowed = true;
            }
            if (allowed) try resolveInterception(self.a, &self.socket, "Fetch.continueRequest", .{ .requestId = str(field(p, "requestId")) }) else try resolveInterception(self.a, &self.socket, "Fetch.failRequest", .{ .requestId = str(field(p, "requestId")), .errorReason = "BlockedByClient" });
        } else if (std.mem.eql(u8, method, "Network.requestWillBeSent")) {
            if (self.requests.items.len >= 20000) return error.RequestLimitExceeded;
            const request = field(p, "request");
            const r = try self.a.create(Request);
            r.* = .{ .id = str(field(p, "requestId")), .url = str(field(request, "url")), .method = str(field(request, "method")), .post_data = str(field(request, "postData")) };
            try self.requests.append(self.a, r);
        } else if (std.mem.eql(u8, method, "Network.responseReceived")) {
            if (self.find(str(field(p, "requestId")))) |r| {
                const response_value = field(p, "response");
                r.status = number(field(response_value, "status"));
                r.headers = field(response_value, "headers");
            }
        } else if (std.mem.eql(u8, method, "Network.loadingFinished")) {
            if (self.find(str(field(p, "requestId")))) |r| r.finished = true;
        } else if (std.mem.eql(u8, method, "Network.loadingFailed")) {
            if (self.find(str(field(p, "requestId")))) |r| {
                r.failed = true;
                r.finished = true;
            }
        } else if (std.mem.eql(u8, method, "Runtime.exceptionThrown")) {
            const detail = field(p, "exceptionDetails");
            const description = str(field(field(detail, "exception"), "description"));
            try self.errors.append(self.a, if (description.len > 0) description else str(field(detail, "text")));
        }
    }
    pub fn css(self: *Page, selector: []const u8) Locator {
        return .{ .page = self, .expression = self.a.print("__cdp.css(document,{s})", .{json(self.a, selector) catch unreachable}) catch unreachable };
    }
    pub const Role = struct { role: []const u8, name: ?[]const u8 = null, regex: bool = false, exact: bool = true };
    pub fn role(self: *Page, options: Role) Locator {
        return .{ .page = self, .expression = self.a.print("__cdp.role(document,{s})", .{json(self.a, options) catch unreachable}) catch unreachable };
    }
    pub fn text(self: *Page, value: []const u8) Locator {
        return .{ .page = self, .expression = self.a.print("__cdp.text(document,{s},false)", .{json(self.a, value) catch unreachable}) catch unreachable };
    }
    pub fn textRegex(self: *Page, value: []const u8) Locator {
        return .{ .page = self, .expression = self.a.print("__cdp.text(document,{s},true)", .{json(self.a, value) catch unreachable}) catch unreachable };
    }
    pub fn label(self: *Page, value: []const u8) Locator {
        return .{ .page = self, .expression = self.a.print("__cdp.label(document,{s})", .{json(self.a, value) catch unreachable}) catch unreachable };
    }
    pub fn screenshot(self: *Page, output: []const u8) !void {
        const r = try self.command("Page.captureScreenshot", .{ .format = "png", .captureBeyondViewport = true });
        const data = str(field(r, "data"));
        const bytes = try self.a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(data));
        defer self.a.free(bytes);
        try std.base64.standard.Decoder.decode(bytes, data);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = output, .data = bytes });
    }
    pub fn download(self: *Page, control: Locator, output: []const u8) !V {
        _ = try self.browser.command("Browser.getVersion", .{});
        const start = self.browser.downloads.items.len;
        try control.click();
        const deadline = now(self.io) + self.timeout_ms;
        var guid: []const u8 = "";
        var filename: []const u8 = "";
        while (now(self.io) < deadline) {
            try self.pump();
            _ = try self.browser.command("Browser.getVersion", .{});
            for (self.browser.downloads.items[start..]) |event| {
                const p = field(event, "params");
                const method = str(field(event, "method"));
                if (std.mem.eql(u8, method, "Browser.downloadWillBegin")) {
                    guid = str(field(p, "guid"));
                    filename = str(field(p, "suggestedFilename"));
                }
                if (guid.len > 0 and std.mem.eql(u8, str(field(p, "guid")), guid) and std.mem.eql(u8, str(field(p, "state")), "completed")) {
                    const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, try self.a.print("{s}/{s}", .{ self.browser.downloads_dir, guid }), self.a, .limited(20 * 1024 * 1024));
                    try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = output, .data = bytes });
                    return val(self.a, .{ .filename = filename, .csv = bytes });
                }
                if (std.mem.eql(u8, str(field(p, "state")), "canceled")) return error.DownloadCanceled;
            }
            try std.Io.sleep(self.io, .fromMilliseconds(50), .awake);
        }
        return error.DownloadTimeout;
    }
};

pub const Locator = struct {
    page: *Page,
    expression: []const u8,
    pub fn css(self: Locator, selector: []const u8) Locator {
        return .{ .page = self.page, .expression = self.page.a.print("({s}).flatMap(n=>__cdp.css(n,{s}))", .{ self.expression, json(self.page.a, selector) catch unreachable }) catch unreachable };
    }
    pub fn role(self: Locator, options: Page.Role) Locator {
        return .{ .page = self.page, .expression = self.page.a.print("({s}).flatMap(n=>__cdp.role(n,{s}))", .{ self.expression, json(self.page.a, options) catch unreachable }) catch unreachable };
    }
    pub fn first(self: Locator) Locator {
        return self.nth(0);
    }
    pub fn nth(self: Locator, index: usize) Locator {
        return .{ .page = self.page, .expression = self.page.a.print("({s}).slice({d},{d})", .{ self.expression, index, index + 1 }) catch unreachable };
    }
    pub fn evalAll(self: Locator, function: []const u8) !V {
        return self.page.eval(try self.page.a.print("({s})({s})", .{ function, self.expression }));
    }
    pub fn eval(self: Locator, function: []const u8) !V {
        try self.waitAttached();
        return self.page.eval(try self.page.a.print("({s})(__cdp.one({s}))", .{ function, self.expression }));
    }
    pub fn count(self: Locator) !usize {
        return @intCast(number(try self.evalAll("ns=>ns.length")));
    }
    pub fn visible(self: Locator) !bool {
        return boolean(try self.evalAll("ns=>ns.length===1&&__cdp.visible(ns[0])"));
    }
    pub fn enabled(self: Locator) !bool {
        return boolean(try self.evalAll("ns=>ns.length===1&&!ns[0].disabled&&ns[0].getAttribute('aria-disabled')!=='true'"));
    }
    pub fn innerText(self: Locator) ![]const u8 {
        return str(try self.eval("n=>n.innerText"));
    }
    pub fn attribute(self: Locator, name: []const u8) !V {
        return self.eval(try self.page.a.print("n=>n.getAttribute({s})", .{try json(self.page.a, name)}));
    }
    pub fn waitAttached(self: Locator) !void {
        try self.page.wait(try self.page.a.print("({s}).length===1", .{self.expression}));
    }
    pub fn waitVisible(self: Locator) !void {
        try self.page.wait(try self.page.a.print("({s}).length===1&&__cdp.visible(({s})[0])", .{ self.expression, self.expression }));
    }
    pub fn waitEnabled(self: Locator) !void {
        try self.page.wait(try self.page.a.print("({s}).length===1&&__cdp.visible(({s})[0])&&!({s})[0].disabled&&({s})[0].getAttribute('aria-disabled')!=='true'", .{ self.expression, self.expression, self.expression, self.expression }));
    }
    pub fn waitHidden(self: Locator) !void {
        try self.page.wait(try self.page.a.print("({s}).every(n=>!__cdp.visible(n))", .{self.expression}));
    }
    pub fn handle(self: Locator) !Locator {
        const id = self.page.next_handle;
        self.page.next_handle += 1;
        _ = try self.eval(try self.page.a.print("n=>(__cdp.handles[{d}]=n,true)", .{id}));
        return .{ .page = self.page, .expression = try self.page.a.print("[__cdp.handles[{d}]]", .{id}) };
    }
    pub fn click(self: Locator) !void {
        const deadline = now(self.page.io) + self.page.timeout_ms;
        while (now(self.page.io) < deadline) {
            const point = try self.evalAll("ns=>ns.length===1?__cdp.point(ns[0]):null");
            if (point == .object) {
                const x = field(point, "x");
                const y = field(point, "y");
                _ = try self.page.command("Input.dispatchMouseEvent", .{ .type = "mouseMoved", .x = x, .y = y });
                _ = try self.page.eval("new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve(true))))");
                const settled = try self.evalAll("ns=>ns.length===1?__cdp.point(ns[0]):null");
                if (settled != .object or !std.mem.eql(u8, try json(self.page.a, point), try json(self.page.a, settled))) continue;
                _ = try self.page.command("Input.dispatchMouseEvent", .{ .type = "mousePressed", .x = x, .y = y, .button = "left", .buttons = @as(u32, 1), .clickCount = @as(u32, 1) });
                _ = try self.page.command("Input.dispatchMouseEvent", .{ .type = "mouseReleased", .x = x, .y = y, .button = "left", .buttons = @as(u32, 0), .clickCount = @as(u32, 1) });
                return;
            }
            try self.page.pump();
            try std.Io.sleep(self.page.io, .fromMilliseconds(50), .awake);
        }
        std.debug.print("Actionability timeout: {s}\n", .{self.expression});
        const diagnostic = self.evalAll("ns=>ns.map(n=>({tag:n.tagName,visible:__cdp.visible(n),disabled:n.disabled,ariaDisabled:n.getAttribute('aria-disabled'),rect:n.getBoundingClientRect().toJSON(),viewport:[innerWidth,innerHeight]}))") catch .null;
        std.debug.print("Actionability state: {s}\n", .{try json(self.page.a, diagnostic)});
        return error.ElementNotActionable;
    }
    pub fn focus(self: Locator) !void {
        _ = try self.eval("n=>{n.focus();return document.activeElement===n}");
    }
    pub fn pressEnter(self: Locator) !void {
        try self.focus();
        _ = try self.page.command("Input.dispatchKeyEvent", .{ .type = "keyDown", .key = "Enter", .code = "Enter", .windowsVirtualKeyCode = @as(u32, 13), .text = "\r" });
        _ = try self.page.command("Input.dispatchKeyEvent", .{ .type = "keyUp", .key = "Enter", .code = "Enter", .windowsVirtualKeyCode = @as(u32, 13) });
    }
    pub fn fill(self: Locator, text_value: []const u8) !void {
        try self.waitVisible();
        _ = try self.eval("n=>{if(n.disabled||n.readOnly)throw Error('input unavailable');n.focus();n.select();return true}");
        if (text_value.len == 0) {
            _ = try self.page.command("Input.dispatchKeyEvent", .{ .type = "keyDown", .key = "Backspace", .code = "Backspace", .windowsVirtualKeyCode = @as(u32, 8) });
            _ = try self.page.command("Input.dispatchKeyEvent", .{ .type = "keyUp", .key = "Backspace", .code = "Backspace", .windowsVirtualKeyCode = @as(u32, 8) });
        } else _ = try self.page.command("Input.insertText", .{ .text = text_value });
    }
    pub fn checked(self: Locator, expected: bool) !void {
        const before = boolean(try self.eval("n=>n.checked"));
        if (before != expected) try self.click();
        if (boolean(try self.eval("n=>n.checked")) != expected) return error.CheckboxDidNotChange;
    }
    pub fn select(self: Locator, option: []const u8) !void {
        _ = try self.eval(try self.page.a.print("n=>{{if(n.disabled||![...n.options].some(o=>o.value==={s}))throw Error('option unavailable');n.value={s};n.dispatchEvent(new Event('input',{{bubbles:true}}));n.dispatchEvent(new Event('change',{{bubbles:true}}));return true}}", .{ try json(self.page.a, option), try json(self.page.a, option) }));
    }
    pub fn file(self: Locator, filename: []const u8) !void {
        try self.waitAttached();
        // File controls may be hidden, but must be enabled before selection.
        try self.page.wait(try self.page.a.print("({s}).length===1&&!__cdp.one({s}).matches(':disabled')", .{ self.expression, self.expression }));
        const result = try self.page.command("Runtime.evaluate", .{ .expression = try self.page.a.print("__cdp.one({s})", .{self.expression}), .returnByValue = false });
        const id = str(field(field(result, "result"), "objectId"));
        if (id.len == 0) return error.FileInputMissing;
        defer {
            _ = self.page.command("Runtime.releaseObject", .{ .objectId = id }) catch {};
        }
        _ = try self.page.command("DOM.setFileInputFiles", .{ .files = .{filename}, .objectId = id });
    }
};
