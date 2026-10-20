//! Executable-only session policy and local command transport.
const std = @import("std");
const J = @import("cdp").journey;
const A = std.mem.Allocator;
const V = std.json.Value;
const Stream = std.Io.net.Stream;

pub const Options = struct {
    directory: []const u8,
    browser: J.Browser.Options = .{},
    origins: []const []const u8 = &.{},
    idle_seconds: u32 = 900,
};
pub const Request = struct { command: []const u8, args: []const []const u8 };
const max_request = 1024 * 1024;
const max_response = 16 * 1024 * 1024;

const Op = enum { status, allow, open, reload, content, eval, click, fill, text, wait, timeout, screenshot, upload, download, close };

pub fn operation(command: []const u8, argc: usize) !Op {
    const op = std.meta.stringToEnum(Op, command) orelse return error.UnknownCommand;
    const count: usize = switch (op) {
        .status, .reload, .close => 0,
        .fill, .upload, .download => 2,
        else => 1,
    };
    if (argc != count) return error.WrongArgumentCount;
    return op;
}

pub fn validateOrigin(origin: []const u8) !void {
    if (origin.len > 2048 or std.mem.indexOfAny(u8, origin, " \t\r\n\\%") != null) return error.InvalidOrigin;
    const uri = std.Uri.parse(origin) catch return error.InvalidOrigin;
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return error.InvalidOrigin;
    const host = uri.host orelse return error.InvalidOrigin;
    if (host.isEmpty() or !uri.path.isEmpty() or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidOrigin;
}

var stopping = std.atomic.Value(bool).init(false);
fn signal(_: std.posix.SIG) callconv(.c) void {
    stopping.store(true, .release);
}
fn awaitSignal(io: std.Io) !void {
    while (!stopping.load(.acquire)) try std.Io.sleep(io, .fromMilliseconds(50), .awake);
}

pub fn serve(backing: A, io: std.Io, options: Options) !void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const a = arena.allocator();
    const socket_path = try std.fs.path.join(a, &.{ options.directory, "control.sock" });
    const address = try std.Io.net.UnixAddress.init(socket_path);
    try std.Io.Dir.cwd().createDir(io, options.directory, .fromMode(0o700));
    defer std.Io.Dir.cwd().deleteDir(io, options.directory) catch |err| cleanupError(err);
    var listener = try address.listen(io, .{ .kernel_backlog = 16 });
    defer std.Io.Dir.cwd().deleteFile(io, socket_path) catch |err| cleanupError(err);
    defer listener.deinit(io);

    stopping.store(false, .release);
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = signal }, .mask = std.posix.sigemptyset(), .flags = 0 };
    var old_int: std.posix.Sigaction = undefined;
    var old_term: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, &action, &old_int);
    defer std.posix.sigaction(.INT, &old_int, null);
    std.posix.sigaction(.TERM, &action, &old_term);
    defer std.posix.sigaction(.TERM, &old_term, null);

    const browser = try J.Browser.startWithOptions(a, io, options.browser);
    defer browser.stop();
    const page = try browser.page(&.{});
    defer page.close();
    var state: State = .{ .page = page };
    for (options.origins) |origin| try state.allow(origin);
    const ready = try J.json(a, .{ .ok = true, .ready = true, .session = options.directory, .browser = browser.version, .pid = browser.child.pid, .profile = browser.profile });
    try std.Io.File.stdout().writeStreamingAll(io, ready);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");

    const Result = union(enum) { server: anyerror!void, signal: anyerror!void };
    var results: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &results);
    defer select.cancelDiscard();
    select.async(.server, loop, .{ backing, io, &listener, &state, options.idle_seconds });
    select.async(.signal, awaitSignal, .{io});
    switch (try select.await()) {
        .server => |result| try result,
        .signal => |result| try result,
    }
}

fn cleanupError(err: anyerror) void {
    std.debug.print("Session cleanup failed: {s}\n", .{@errorName(err)});
}

fn loop(backing: A, io: std.Io, listener: *std.Io.net.Server, state: *State, idle_seconds: u32) !void {
    const Event = union(enum) { stream: std.Io.net.Server.AcceptError!Stream, tick: std.Io.Cancelable!void };
    var results: [2]Event = undefined;
    var select = std.Io.Select(Event).init(io, &results);
    defer {
        // Accept may have completed at the same time as a signal or idle expiry.
        while (select.cancel()) |event| switch (event) {
            .stream => |result| if (result) |stream| stream.close(io) else |_| {},
            .tick => {},
        };
    }
    select.async(.stream, std.Io.net.Server.accept, .{ listener, io });
    select.async(.tick, std.Io.sleep, .{ io, .fromMilliseconds(100), .awake });
    var last_activity = std.Io.Clock.awake.now(io).toMilliseconds();
    while (!state.closed) {
        switch (try select.await()) {
            .tick => |result| {
                try result;
                if (std.Io.Clock.awake.now(io).toMilliseconds() - last_activity >= @as(i64, idle_seconds) * 1000) return;
                if (!state.failed) state.page.pump() catch |err| {
                    if (err == error.Canceled) return err;
                    state.failed = true;
                    std.debug.print("Browser session failed: {s}\n", .{@errorName(err)});
                };
                select.async(.tick, std.Io.sleep, .{ io, .fromMilliseconds(100), .awake });
            },
            .stream => |result| {
                const stream = try result;
                defer stream.close(io);
                var scratch = std.heap.ArenaAllocator.init(backing);
                defer scratch.deinit();
                const a = scratch.allocator();
                const reply = respond(a, io, stream, state) catch |err| blk: {
                    if (err == error.Canceled) return err;
                    break :blk try J.json(a, .{ .ok = false, .err = @errorName(err) });
                };
                writeLine(io, stream, reply) catch |err| {
                    if (err == error.Canceled) return err;
                    std.debug.print("Client reply failed: {s}\n", .{@errorName(err)});
                };
                last_activity = std.Io.Clock.awake.now(io).toMilliseconds();
                if (!state.closed) select.async(.stream, std.Io.net.Server.accept, .{ listener, io });
            },
        }
    }
}

fn respond(a: A, io: std.Io, stream: Stream, state: *State) ![]const u8 {
    const line = try readLine(a, io, stream, .{ .limit = max_request, .timeout_ms = 5000 });
    const parsed = std.json.parseFromSlice(Request, a, line, .{}) catch return error.InvalidRequest;
    defer parsed.deinit();
    const op = try operation(parsed.value.command, parsed.value.args.len);
    const value = try state.execute(op, parsed.value.args);
    const reply = try J.json(a, .{ .ok = true, .result = value });
    if (reply.len > max_response) return error.ResponseTooLarge;
    return reply;
}

const State = struct {
    page: *J.Page,
    origins: std.ArrayList([]const u8) = .empty,
    closed: bool = false,
    failed: bool = false,

    fn allow(self: *State, origin: []const u8) !void {
        try validateOrigin(origin);
        for (self.origins.items) |existing| if (std.mem.eql(u8, existing, origin)) return;
        try self.origins.append(self.page.a, try self.page.a.dupe(u8, origin));
        self.page.origins = self.origins.items;
    }
    fn permitted(self: *State, url: []const u8) bool {
        if (std.mem.eql(u8, url, "about:blank") or std.mem.startsWith(u8, url, "data:") or std.mem.startsWith(u8, url, "blob:")) return true;
        for (self.origins.items) |origin| {
            if (std.mem.startsWith(u8, url, origin) and (url.len == origin.len or url[origin.len] == '/')) return true;
        }
        return false;
    }
    fn execute(self: *State, op: Op, args: []const []const u8) !V {
        const p = self.page;
        if (op != .close and self.failed) return error.SessionFailed;
        switch (op) {
            .close => {
                self.closed = true;
                return .{ .string = "closing" };
            },
            .status => return J.val(p.a, .{ .browser = p.browser.version, .url = try p.url(), .origins = self.origins.items, .timeout_ms = p.timeout_ms }),
            .allow => try self.allow(args[0]),
            .open => {
                const url = J.str(try p.evaluate("url => new URL(url).href", args[0]));
                if (!self.permitted(url)) return error.OriginNotAllowed;
                try p.goto(url);
                return .{ .string = try p.url() };
            },
            .reload => try p.reload(),
            .content => {
                _ = try p.evaluate("html => { document.open(); document.write(html); document.close(); return true; }", args[0]);
            },
            .eval => return p.eval(args[0]),
            .click => try p.css(args[0]).click(),
            .fill => try p.css(args[0]).fill(args[1]),
            .text => return .{ .string = try p.css(args[0]).innerText() },
            .wait => try p.wait(args[0]),
            .timeout => {
                const ms = try std.fmt.parseInt(u32, args[0], 10);
                if (ms == 0 or ms > 120000) return error.InvalidTimeout;
                p.timeout_ms = ms;
            },
            .screenshot => {
                try p.screenshot(args[0]);
                return .{ .string = args[0] };
            },
            .upload => try p.css(args[0]).file(args[1]),
            .download => {
                const result = try p.download(p.css(args[0]), args[1]);
                return J.val(p.a, .{ .filename = J.str(J.field(result, "filename")), .path = args[1], .bytes = J.str(J.field(result, "csv")).len });
            },
        }
        return .{ .bool = true };
    }
};

pub fn request(a: A, io: std.Io, directory: []const u8, input: Request) ![]const u8 {
    const address = try std.Io.net.UnixAddress.init(try std.fs.path.join(a, &.{ directory, "control.sock" }));
    const stream = try address.connect(io);
    defer stream.close(io);
    const payload = try J.json(a, input);
    if (payload.len > max_request) return error.RequestTooLarge;
    try writeLine(io, stream, payload);
    return readLine(a, io, stream, .{ .limit = max_response, .timeout_ms = 180000 });
}

fn writeLine(io: std.Io, stream: Stream, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

fn readLine(a: A, io: std.Io, stream: Stream, options: struct { limit: usize, timeout_ms: i64 }) ![]const u8 {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(a);
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + options.timeout_ms;
    while (true) {
        const remaining = deadline - std.Io.Clock.awake.now(io).toMilliseconds();
        if (remaining <= 0) return error.Timeout;
        var buffer: [4096]u8 = undefined;
        var buffers = [_][]u8{&buffer};
        const read = try io.operateTimeout(.{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &buffers } }, .{ .duration = .{ .raw = .fromMilliseconds(@intCast(remaining)), .clock = .awake } });
        const n = (try read.net_read).data_len;
        if (n == 0) return error.ConnectionClosed;
        const newline = std.mem.indexOfScalar(u8, buffer[0..n], '\n');
        const chunk = buffer[0 .. newline orelse n];
        if (chunk.len > options.limit - line.items.len) return error.MessageTooLarge;
        try line.appendSlice(a, chunk);
        if (newline != null) return line.toOwnedSlice(a);
    }
}
