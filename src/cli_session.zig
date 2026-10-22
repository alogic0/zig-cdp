//! Executable-only session policy and local command transport.
const std = @import("std");
const J = @import("cdp").journey;
const Agent = @import("cdp").agent;
const A = std.mem.Allocator;
const V = std.json.Value;
const Stream = std.Io.net.Stream;

pub const Options = struct {
    directory: []const u8,
    browser: J.Browser.Options = .{},
    origins: []const []const u8 = &.{},
    idle_seconds: u32 = 900,
};
pub const Request = struct {
    command: []const u8,
    args: []const []const u8 = &.{},
    locator: ?Agent.Query = null,
    tab: ?[]const u8 = null,
    frame: ?[]const u8 = null,
    timeout_ms: ?u32 = null,
    limit: usize = 20_000,
    state: []const u8 = "visible",
    full_page: bool = false,
    background: bool = false,
    modern: bool = false,
    files: []const []const u8 = &.{},
    params: ?V = null,
    destination: ?Agent.Query = null,
    hold_ms: u32 = 300,
    steps: u32 = 12,
};
const max_request = 1024 * 1024;
const max_response = 16 * 1024 * 1024;

const Op = enum { status, tabs, frames, @"new-tab", @"switch-tab", @"close-tab", allow, open, reload, content, eval, click, fill, text, read, snapshot, select, press, wait, timeout, screenshot, upload, download, drag, protocol, sequence, pause, close };

pub fn operation(input: Request) anyerror!Op {
    const op = std.meta.stringToEnum(Op, input.command) orelse return error.UnknownCommand;
    const argc = input.args.len;
    if (input.frame) |frame| {
        if (frame.len == 0 or frame.len > 256) return error.InvalidFrame;
        switch (op) {
            .status, .open, .reload, .content, .eval, .click, .fill, .text, .read, .snapshot, .select, .press, .wait, .upload, .download, .drag, .protocol, .sequence, .pause => {},
            else => return error.InvalidOption,
        }
    }
    if (input.files.len > 64) return error.FileCountExceeded;
    if (input.files.len > 0 and op != .upload) return error.InvalidOption;
    if (op != .drag and (input.destination != null or input.hold_ms != 300 or input.steps != 12)) return error.InvalidOption;
    if (op == .drag) {
        if (input.hold_ms > 10000 or input.steps < 2 or input.steps > 120) return error.InvalidDrag;
        if (input.destination) |destination| try destination.validate();
        if (input.locator != null and input.destination == null) return error.InvalidLocator;
    }
    if (op != .protocol and input.params != null) return error.InvalidOption;
    if (op == .protocol) {
        if (input.params) |params| {
            if (argc != 1) return error.WrongArgumentCount;
            try Agent.validateProtocol(input.args[0], params);
        } else {
            if (argc != 2) return error.WrongArgumentCount;
            var parsed = std.json.parseFromSlice(V, std.heap.page_allocator, input.args[1], .{}) catch return error.InvalidProtocolParameters;
            defer parsed.deinit();
            try Agent.validateProtocol(input.args[0], parsed.value);
        }
    }
    if (op == .sequence) {
        if (argc != 1) return error.WrongArgumentCount;
        var parsed = try parseSequence(std.heap.page_allocator, input.args[0]);
        defer parsed.deinit();
        if (input.frame != null) for (parsed.value.steps) |step| {
            if (std.mem.eql(u8, step.command, "screenshot")) return error.FrameCommandUnsupported;
        };
    }
    if (op == .pause) {
        if (argc != 1) return error.WrongArgumentCount;
        const ms = std.fmt.parseInt(u32, input.args[0], 10) catch return error.InvalidPause;
        if (ms > 10000) return error.InvalidPause;
    }
    if (!std.mem.eql(u8, input.state, "visible") and !std.mem.eql(u8, input.state, "hidden") and !std.mem.eql(u8, input.state, "attached") and !std.mem.eql(u8, input.state, "detached")) return error.InvalidWaitState;
    if (!std.mem.eql(u8, input.state, "visible") and (op != .wait or input.locator == null)) return error.InvalidOption;
    if (input.full_page and op != .screenshot) return error.InvalidOption;
    if (input.background and op != .@"new-tab" and op != .@"switch-tab") return error.InvalidOption;
    if (input.tab != null and (op == .close or op == .allow or op == .timeout or op == .tabs or op == .@"new-tab" or op == .@"switch-tab")) return error.InvalidOption;
    if (input.limit == 0 or input.limit > 1024 * 1024) return error.InvalidLimit;
    if (input.timeout_ms) |ms| if (ms == 0 or ms > 120000) return error.InvalidTimeout;
    if (input.locator) |query| {
        try query.validate();
        const valid = switch (op) {
            .click, .text, .read, .wait, .drag => argc == 0,
            .fill, .select, .press, .download => argc == 1,
            .upload => argc == (if (input.files.len == 0) @as(usize, 1) else 0),
            else => return error.InvalidLocator,
        };
        if (!valid) return error.WrongArgumentCount;
        return op;
    }
    const valid = switch (op) {
        .status, .tabs, .frames, .reload, .close, .read, .snapshot => argc == 0,
        .@"new-tab" => argc <= 1,
        .@"close-tab" => argc <= 1 and !(input.tab != null and argc != 0),
        .fill, .select, .download => argc == 2,
        .upload => argc == (if (input.files.len == 0) @as(usize, 2) else 1),
        .protocol => argc == (if (input.params == null) @as(usize, 2) else 1),
        .drag => argc == (if (input.destination == null) @as(usize, 2) else 1),
        else => argc == 1,
    };
    if (!valid) return error.WrongArgumentCount;
    return op;
}

pub const Sequence = struct { version: u8, steps: []Request };
pub fn parseSequence(a: A, raw: []const u8) anyerror!std.json.Parsed(Sequence) {
    if (raw.len > 1024 * 1024) return error.SequenceTooLarge;
    var parsed = std.json.parseFromSlice(Sequence, a, raw, .{}) catch return error.InvalidSequence;
    errdefer parsed.deinit();
    if (parsed.value.version != 1 or parsed.value.steps.len == 0 or parsed.value.steps.len > 128) return error.InvalidSequence;
    for (parsed.value.steps) |*step| {
        step.modern = true;
        if (step.tab != null or step.frame != null or step.timeout_ms != null or step.background) return error.InvalidSequence;
        const op = std.meta.stringToEnum(Op, step.command) orelse return error.InvalidSequence;
        switch (op) {
            .open, .reload, .content, .eval, .click, .fill, .text, .read, .snapshot, .select, .press, .wait, .screenshot, .upload, .drag, .protocol, .pause => {},
            else => return error.InvalidSequence,
        }
        _ = try operation(step.*);
    }
    return parsed;
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
    try browser.socket.setAllocator(backing);
    browser.capture_observations = false;
    browser.configure_downloads = false;
    const page = if (browser.persistent_profile) try browser.profilePage(&.{}) else try browser.page(&.{});
    try page.socket.setAllocator(backing);
    defer page.detach();
    var state: State = .{ .a = a, .backing = backing, .browser = browser, .context = page.context, .page = page };
    defer state.deinit();
    state.selectPage(page);
    try state.downloadBehavior("deny");
    try state.pages.append(backing, .{ .page = page });
    for (options.origins) |origin| try state.allow(origin);
    const ready = try J.json(a, .{ .ok = true, .ready = true, .session = options.directory, .browser = browser.version, .pid = browser.child.pid, .profile = browser.profile, .persistent_profile = browser.persistent_profile, .port = browser.client.port });
    try std.Io.File.stdout().writeStreamingAll(io, ready);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");

    const Result = union(enum) { server: anyerror!void, signal: anyerror!void };
    var results: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &results);
    defer select.cancelDiscard();
    // Both branches must progress independently, even with no spare async slots.
    try select.concurrent(.server, loop, .{ backing, io, &listener, &state, options.idle_seconds });
    try select.concurrent(.signal, awaitSignal, .{io});
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
    try select.concurrent(.stream, std.Io.net.Server.accept, .{ listener, io });
    try select.concurrent(.tick, std.Io.sleep, .{ io, .fromMilliseconds(100), .awake });
    var last_activity = std.Io.Clock.awake.now(io).toMilliseconds();
    while (!state.closed) {
        switch (try select.await()) {
            .tick => |result| {
                try result;
                if (std.Io.Clock.awake.now(io).toMilliseconds() - last_activity >= @as(i64, idle_seconds) * 1000) return;
                if (!state.failed) state.pump() catch |err| {
                    if (err == error.Canceled) return err;
                    state.failed = true;
                    std.debug.print("Browser session failed: {s}\n", .{@errorName(err)});
                };
                try select.concurrent(.tick, std.Io.sleep, .{ io, .fromMilliseconds(100), .awake });
            },
            .stream => |result| {
                const stream = try result;
                defer stream.close(io);
                var scratch = std.heap.ArenaAllocator.init(backing);
                defer scratch.deinit();
                const a = scratch.allocator();
                const reply = respond(a, io, stream, state) catch |err| blk: {
                    if (err == error.Canceled) return err;
                    break :blk try failure(a, .{ .command = "" }, err, .{});
                };
                writeLine(io, stream, reply) catch |err| {
                    if (err == error.Canceled) return err;
                    std.debug.print("Client reply failed: {s}\n", .{@errorName(err)});
                };
                last_activity = std.Io.Clock.awake.now(io).toMilliseconds();
                if (!state.closed) try select.concurrent(.stream, std.Io.net.Server.accept, .{ listener, io });
            },
        }
    }
}

fn respond(a: A, io: std.Io, stream: Stream, state: *State) ![]const u8 {
    const line = try readLine(a, io, stream, .{ .limit = max_request, .timeout_ms = 5000 });
    const parsed = std.json.parseFromSlice(Request, a, line, .{}) catch return error.InvalidRequest;
    defer parsed.deinit();
    var diagnostics: Agent.Diagnostics = .{};
    _ = operation(parsed.value) catch |err| return failure(a, parsed.value, err, diagnostics);
    var input = parsed.value;
    if (input.tab == null) input.tab = try a.dupe(u8, state.selected());
    const Result = union(enum) { value: anyerror!V, budget: std.Io.Cancelable!void, disconnected: anyerror!void };
    var results: [3]Result = undefined;
    var select = std.Io.Select(Result).init(io, &results);
    var joined = false;
    defer if (!joined) select.cancelDiscard();
    const budget = parsed.value.timeout_ms orelse @as(u32, @intCast(state.timeout_ms));
    try select.concurrent(.value, State.execute, .{ state, a, parsed.value, &diagnostics, @as(i64, @intCast(std.Io.Clock.awake.now(io).toMilliseconds())) + budget });
    try select.concurrent(.budget, std.Io.sleep, .{ io, .fromMilliseconds(@as(i64, budget) + 300), .awake });
    if (std.mem.eql(u8, input.command, "drag") or std.mem.eql(u8, input.command, "sequence")) try select.concurrent(.disconnected, awaitDisconnect, .{ io, stream });
    const result = try select.await();
    select.cancelDiscard();
    joined = true;
    const value = switch (result) {
        .value => |value| value catch |err| {
            if (err == error.Canceled) return err;
            return failure(a, input, err, diagnostics);
        },
        .budget => return failure(a, input, error.CommandTimeout, diagnostics),
        .disconnected => return failure(a, input, error.ClientDisconnected, diagnostics),
    };
    const reply = try J.json(a, .{ .ok = true, .result = value, .command = parsed.value.command, .tab = parsed.value.tab orelse state.selected() });
    if (reply.len > max_response) {
        diagnostics.phase = .output;
        return failure(a, input, error.ResponseTooLarge, diagnostics);
    }
    return reply;
}

fn awaitDisconnect(io: std.Io, stream: Stream) !void {
    var buffer: [1]u8 = undefined;
    var buffers = [_][]u8{&buffer};
    const result = try io.operateTimeout(.{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &buffers } }, .{ .duration = .{ .raw = .fromSeconds(180), .clock = .awake } });
    _ = try result.net_read;
}

pub fn failure(a: A, input: Request, err: anyerror, diagnostics: Agent.Diagnostics) ![]const u8 {
    return J.json(a, .{ .ok = false, .err = @errorName(err), .command = input.command, .tab = input.tab, .frame = input.frame, .@"error" = .{ .code = @errorName(err), .phase = diagnostics.phase, .match_count = diagnostics.match_count, .action = diagnostics.action, .step = diagnostics.step, .steps = diagnostics.steps, .input_release = diagnostics.input_release } });
}

pub fn executePage(page: *Agent.Page, input: Request) anyerror!V {
    const op = try operation(input);
    if (input.frame) |frame| if (page.frame == null or !std.mem.eql(u8, page.frame.?, frame)) try page.setFrame(frame);
    const query: Agent.Query = input.locator orelse .{ .selector = if (input.args.len > 0) input.args[0] else "body" };
    const index: usize = if (input.locator == null) 1 else 0;
    switch (op) {
        .frames => return page.frames(),
        .drag => try page.drag(query, input.destination orelse .{ .selector = input.args[1] }, input.hold_ms, input.steps),
        .protocol => return page.protocol(input.args[0], if (input.params) |params| try J.parse(page.a, try J.json(page.a, params)) else try J.parse(page.a, input.args[1])),
        .pause => try page.delay(try std.fmt.parseInt(u32, input.args[0], 10)),
        .sequence => return executeSequence(page, input.args[0], null),
        .snapshot => return page.snapshot(input.limit),
        .read => return page.read(input.locator, input.limit),
        .text => return page.text(query),
        .click => page.click(query) catch |err| {
            if (!input.modern and (err == error.ElementDisabled or err == error.ElementCovered or err == error.ElementNotVisible or err == error.ElementNotStable)) return error.ElementNotActionable;
            return err;
        },
        .fill => try page.fill(query, input.args[index]),
        .select => try page.select(query, input.args[index]),
        .press => try page.press(input.locator, input.args[0]),
        .wait => if (input.locator == null) try page.waitExpression(input.args[0]) else try page.wait(query, input.state),
        .upload => try page.uploadFiles(query, if (input.files.len == 0) &.{input.args[index]} else input.files),
        .screenshot => {
            const result = try page.screenshot(input.args[0], input.full_page);
            return if (input.modern) result else .{ .string = input.args[0] };
        },
        .open => {
            const url = J.str(try page.eval(try page.a.print("new URL({s}).href", .{try J.json(page.a, input.args[0])})));
            try page.goto(url);
            return .{ .string = J.str(try page.eval("location.href")) };
        },
        .reload => try page.reload(),
        .content => try page.content(input.args[0]),
        .eval => {
            page.diagnostics.phase = .action;
            page.diagnostics.action = .possibly_dispatched;
            const result = try page.eval(input.args[0]);
            page.diagnostics.action = .completed;
            return result;
        },
        else => return error.InvalidEndpointCommand,
    }
    return .{ .bool = true };
}

fn executeSequence(page: *Agent.Page, raw: []const u8, unload: ?*bool) anyerror!V {
    var parsed = try parseSequence(page.a, raw);
    defer parsed.deinit();
    for (parsed.value.steps) |step| if (std.mem.eql(u8, step.command, "upload")) try Agent.validateFiles(page.io, if (step.files.len > 0) step.files else &.{step.args[if (step.locator == null) @as(usize, 1) else 0]});
    const reports = try page.a.alloc(Agent.Diagnostics.Step, parsed.value.steps.len);
    for (parsed.value.steps, 0..) |step, i| reports[i] = .{ .index = i, .command = try page.a.dupe(u8, step.command) };
    page.diagnostics.steps = reports;
    defer page.input.release(page);
    var results: std.ArrayList(V) = .empty;
    var output_bytes: usize = 0;
    for (parsed.value.steps, 0..) |step, i| {
        page.diagnostics.step = i;
        page.diagnostics.action = .not_started;
        page.diagnostics.match_count = null;
        const previous_unload = if (unload) |flag| flag.* else false;
        if (unload) |flag| if (std.mem.eql(u8, step.command, "open") or std.mem.eql(u8, step.command, "reload")) {
            flag.* = true;
        };
        defer if (unload) |flag| {
            flag.* = previous_unload;
        };
        const result = executePage(page, step) catch |err| {
            reports[i].action = page.diagnostics.action;
            reports[i].err = @errorName(err);
            return err;
        };
        reports[i].action = page.diagnostics.action;
        output_bytes += (try J.json(page.a, result)).len;
        if (output_bytes > 8 * 1024 * 1024) return error.SequenceOutputTooLarge;
        try results.append(page.a, result);
    }
    page.input.release(page);
    if (page.diagnostics.input_release == .incomplete) return error.InputReleaseIncomplete;
    return J.val(page.a, .{ .steps = reports, .results = results.items, .input_release = page.diagnostics.input_release });
}

const State = struct {
    a: A,
    backing: A,
    browser: *J.Browser,
    context: []const u8,
    page: *J.Page,
    selected_target: [128]u8 = undefined,
    selected_len: usize = 0,
    pages: std.ArrayList(Record) = .empty,
    origins: std.ArrayList([]const u8) = .empty,
    timeout_ms: i64 = 30000,
    deadline_ms: i64 = 0,
    closed: bool = false,
    failed: bool = false,

    const Record = struct { page: *J.Page, arena: ?*std.heap.ArenaAllocator = null };

    fn selected(self: *const State) []const u8 {
        return self.selected_target[0..self.selected_len];
    }
    fn selectPage(self: *State, page: *J.Page) void {
        self.page = page;
        self.selected_len = page.target.len;
        @memcpy(self.selected_target[0..self.selected_len], page.target);
    }
    fn deinit(self: *State) void {
        while (self.pages.items.len > 0) self.removePage(self.pages.items[0].page.target);
        self.pages.deinit(self.backing);
        for (self.origins.items) |origin| self.backing.free(origin);
        self.origins.deinit(self.backing);
    }
    fn contains(tabs: []const J.Browser.Tab, id: []const u8) bool {
        for (tabs) |tab| if (std.mem.eql(u8, tab.id, id)) return true;
        return false;
    }
    fn removePage(self: *State, id: []const u8) void {
        for (self.pages.items, 0..) |record, index| {
            if (!std.mem.eql(u8, record.page.target, id)) continue;
            record.page.detach();
            _ = self.pages.orderedRemove(index);
            if (record.arena) |arena| {
                arena.deinit();
                self.backing.destroy(arena);
            }
            return;
        }
    }
    fn createPage(self: *State, id: ?[]const u8) !*J.Page {
        if (self.pages.items.len >= 64) return error.TabLimitExceeded;
        const arena = try self.backing.create(std.heap.ArenaAllocator);
        arena.* = .init(self.backing);
        errdefer {
            arena.deinit();
            self.backing.destroy(arena);
        }
        const page = if (id) |target|
            try self.browser.attachTabWithOptions(arena.allocator(), target, self.context, self.origins.items, .{ .background = true })
        else
            try self.browser.newTabWithOptions(arena.allocator(), self.context, self.origins.items, .{ .background = true });
        errdefer {
            if (id == null) self.closeTarget(page.target) catch {};
            page.detach();
        }
        try page.socket.setAllocator(self.backing);
        page.socket.deadline_ms = self.deadline_ms;
        try self.pages.append(self.backing, .{ .page = page, .arena = arena });
        return page;
    }
    fn obtain(self: *State, id: []const u8) !*J.Page {
        for (self.pages.items) |record| if (std.mem.eql(u8, record.page.target, id)) return record.page;
        return self.createPage(id);
    }
    fn activate(self: *State, page: *J.Page) !void {
        _ = try Agent.call(self.a, &self.browser.socket, "Target.activateTarget", .{ .targetId = page.target });
    }
    fn closeTarget(self: *State, id: []const u8) !void {
        if (!J.boolean(J.field(try Agent.call(self.a, &self.browser.socket, "Target.closeTarget", .{ .targetId = id }), "success"))) return error.TabNotFound;
    }
    fn refresh(self: *State) ![]const J.Browser.Tab {
        var tabs = try self.browser.tabsWithAllocator(self.a, self.context);
        if (tabs.len > 64) return error.TabLimitExceeded;
        const selected_id = try self.a.dupe(u8, self.selected());
        var index: usize = 0;
        while (index < self.pages.items.len) {
            const page = self.pages.items[index].page;
            if (contains(tabs, page.target)) index += 1 else self.removePage(page.target);
        }
        if (tabs.len == 0) {
            self.selectPage(try self.createPage(null));
            tabs = try self.browser.tabsWithAllocator(self.a, self.context);
        } else if (!contains(tabs, selected_id)) {
            self.selectPage(try self.obtain(tabs[0].id));
        }
        return tabs;
    }
    fn deadlines(self: *State, deadline: ?i64) void {
        self.browser.socket.deadline_ms = deadline;
        for (self.pages.items) |record| record.page.socket.deadline_ms = deadline;
    }
    fn pump(self: *State) !void {
        var scratch = std.heap.ArenaAllocator.init(self.backing);
        defer scratch.deinit();
        self.a = scratch.allocator();
        self.deadline_ms = @intCast(std.Io.Clock.awake.now(self.browser.io).toMilliseconds() + 1000);
        self.deadlines(self.deadline_ms);
        defer self.deadlines(null);
        _ = try self.refresh();
        for (self.pages.items) |record| {
            const id = try self.a.dupe(u8, record.page.target);
            _ = Agent.call(self.a, &record.page.socket, "Runtime.evaluate", .{ .expression = "0", .returnByValue = true }) catch |err| {
                if (err == error.Canceled) return err;
                const tabs = try self.refresh();
                if (contains(tabs, id)) return err;
                return;
            };
        }
    }
    fn describe(self: *State, page: *J.Page) !V {
        const info = J.field(try Agent.call(self.a, &self.browser.socket, "Target.getTargetInfo", .{ .targetId = page.target }), "targetInfo");
        return J.val(self.a, .{ .id = page.target, .title = J.str(J.field(info, "title")), .url = J.str(J.field(info, "url")), .selected = true });
    }
    fn newTab(self: *State, input: ?[]const u8, background: bool, diagnostics: *Agent.Diagnostics) !V {
        const url = input orelse "about:blank";
        _ = std.Uri.parse(url) catch return error.InvalidUrl;
        if (!self.permitted(url)) return error.OriginNotAllowed;
        diagnostics.phase = .action;
        diagnostics.action = .possibly_dispatched;
        const page = try self.createPage(null);
        errdefer {
            self.closeTarget(page.target) catch {};
            self.removePage(page.target);
        }
        if (!std.mem.eql(u8, url, "about:blank")) {
            var command = try self.commandPage(page, diagnostics);
            defer command.deinit();
            try command.goto(url);
        }
        const result = try self.describe(page);
        if (!background) try self.activate(page);
        self.selectPage(page);
        diagnostics.action = .completed;
        return result;
    }
    fn closeTab(self: *State, tabs: []const J.Browser.Tab, id: []const u8, diagnostics: *Agent.Diagnostics) !V {
        if (!contains(tabs, id)) return error.TabNotFound;
        const closing_selected = std.mem.eql(u8, self.page.target, id);
        var next = self.page;
        if (tabs.len == 1) next = try self.createPage(null) else if (closing_selected) {
            for (tabs) |tab| if (!std.mem.eql(u8, tab.id, id)) {
                next = try self.obtain(tab.id);
                break;
            };
        }
        diagnostics.phase = .action;
        diagnostics.action = .possibly_dispatched;
        try self.closeTarget(id);
        const closed_id = try self.a.dupe(u8, id);
        if (closing_selected) self.selectPage(next);
        self.removePage(id);
        diagnostics.action = .completed;
        return J.val(self.a, .{ .closed = closed_id, .selected = self.page.target });
    }
    fn allow(self: *State, origin: []const u8) !void {
        try validateOrigin(origin);
        for (self.origins.items) |existing| if (std.mem.eql(u8, existing, origin)) return;
        if (self.origins.items.len >= 128) return error.OriginLimitExceeded;
        const copy = try self.backing.dupe(u8, origin);
        errdefer self.backing.free(copy);
        try self.origins.append(self.backing, copy);
        for (self.pages.items) |record| record.page.origins = self.origins.items;
    }
    fn permitted(self: *State, url: []const u8) bool {
        if (std.mem.eql(u8, url, "about:blank") or std.mem.startsWith(u8, url, "data:") or std.mem.startsWith(u8, url, "blob:")) return true;
        for (self.origins.items) |origin| {
            if (std.mem.startsWith(u8, url, origin) and (url.len == origin.len or url[origin.len] == '/')) return true;
        }
        return false;
    }
    fn downloadBehavior(self: *State, behavior: []const u8) !void {
        if (self.context.len == 0) {
            _ = try Agent.call(self.a, &self.browser.socket, "Browser.setDownloadBehavior", .{ .behavior = behavior, .downloadPath = self.browser.downloads_dir, .eventsEnabled = true });
        } else {
            _ = try Agent.call(self.a, &self.browser.socket, "Browser.setDownloadBehavior", .{ .behavior = behavior, .browserContextId = self.context, .downloadPath = self.browser.downloads_dir, .eventsEnabled = true });
        }
    }
    fn cancelDownload(self: *State, guid: []const u8) !void {
        if (self.context.len == 0) {
            _ = try Agent.call(self.a, &self.browser.socket, "Browser.cancelDownload", .{ .guid = guid });
        } else {
            _ = try Agent.call(self.a, &self.browser.socket, "Browser.cancelDownload", .{ .guid = guid, .browserContextId = self.context });
        }
    }
    fn commandPage(self: *State, p: *J.Page, diagnostics: *Agent.Diagnostics) !Agent.Page {
        const remaining = self.deadline_ms - 100 - std.Io.Clock.awake.now(p.io).toMilliseconds();
        if (remaining <= 0) return error.CommandTimeout;
        var page = try Agent.Page.init(self.a, p.io, &p.socket, @intCast(remaining), diagnostics);
        page.targets = p.frame_targets;
        return page;
    }
    fn execute(self: *State, a: A, input: Request, diagnostics: *Agent.Diagnostics, deadline: i64) !V {
        self.a = a;
        self.deadline_ms = deadline + 100;
        self.deadlines(self.deadline_ms);
        defer self.deadlines(null);
        const op = try operation(input);
        if (op == .close) {
            diagnostics.phase = .action;
            diagnostics.action = .completed;
            self.closed = true;
            return .{ .string = "closing" };
        }
        if (self.failed) return error.SessionFailed;
        diagnostics.phase = .connect;
        const tabs = try self.refresh();
        switch (op) {
            .tabs => {
                var result: std.ArrayList(V) = .empty;
                for (tabs) |tab| try result.append(a, try J.val(a, .{ .id = tab.id, .title = tab.title, .url = tab.url, .selected = std.mem.eql(u8, tab.id, self.page.target) }));
                return .{ .array = result.toManaged(a) };
            },
            .@"new-tab" => return self.newTab(if (input.args.len == 0) null else input.args[0], input.background, diagnostics),
            .@"switch-tab" => {
                if (!contains(tabs, input.args[0])) return error.TabNotFound;
                const next = try self.obtain(input.args[0]);
                diagnostics.phase = .action;
                diagnostics.action = .possibly_dispatched;
                if (!input.background) try self.activate(next);
                self.selectPage(next);
                diagnostics.action = .completed;
                return self.describe(next);
            },
            .@"close-tab" => return self.closeTab(tabs, input.tab orelse if (input.args.len > 0) input.args[0] else self.page.target, diagnostics),
            .allow => {
                try self.allow(input.args[0]);
                return .{ .bool = true };
            },
            .timeout => {
                const ms = std.fmt.parseInt(u32, input.args[0], 10) catch return error.InvalidTimeout;
                if (ms == 0 or ms > 120000) return error.InvalidTimeout;
                self.timeout_ms = ms;
                return .{ .bool = true };
            },
            else => {},
        }
        const p = if (input.tab) |id| blk: {
            if (!contains(tabs, id)) return error.TabNotFound;
            break :blk try self.obtain(id);
        } else self.page;
        if (op == .sequence) {
            var sequence = try parseSequence(a, input.args[0]);
            defer sequence.deinit();
            for (sequence.value.steps) |step| if (std.mem.eql(u8, step.command, "open") and !self.permitted(step.args[0])) return error.OriginNotAllowed;
        }
        var page = try self.commandPage(p, diagnostics);
        defer page.deinit();
        if (input.frame) |frame| try page.setFrame(frame);
        switch (op) {
            .sequence => return executeSequence(&page, input.args[0], &p.allow_unload),
            .status => return J.val(a, .{ .browser = self.browser.version, .url = J.str(try page.eval("location.href")), .tab_id = p.target, .origins = self.origins.items, .timeout_ms = self.timeout_ms, .profile = self.browser.profile, .persistent_profile = self.browser.persistent_profile, .port = self.browser.client.port }),
            .open => {
                const url = J.str(try page.eval(try a.print("new URL({s}).href", .{try J.json(a, input.args[0])})));
                if (!self.permitted(url)) return error.OriginNotAllowed;
                p.allow_unload = true;
                defer p.allow_unload = false;
                try page.goto(url);
                return .{ .string = J.str(try page.eval("location.href")) };
            },
            .reload => {
                p.allow_unload = true;
                defer p.allow_unload = false;
                try page.reload();
                return .{ .bool = true };
            },
            .download => {
                // Scoped event storage and staging cleanup even if a command
                // times out after Chrome begins writing its file.
                try self.downloadBehavior("allowAndName");
                self.browser.downloads = .empty;
                self.browser.download_bytes = 0;
                self.browser.download_allocator = a;
                defer {
                    const protection = p.io.swapCancelProtection(.blocked);
                    defer _ = p.io.swapCancelProtection(protection);
                    self.browser.socket.deadline_ms = @intCast(std.Io.Clock.awake.now(p.io).toMilliseconds() + 200);
                    for (self.browser.downloads.items) |event| {
                        if (!std.mem.eql(u8, J.str(J.field(event, "method")), "Browser.downloadWillBegin")) continue;
                        const guid = J.str(J.field(J.field(event, "params"), "guid"));
                        var finished = false;
                        for (self.browser.downloads.items) |progress| {
                            const params = J.field(progress, "params");
                            if (std.mem.eql(u8, guid, J.str(J.field(params, "guid"))) and
                                (std.mem.eql(u8, J.str(J.field(params, "state")), "completed") or
                                    std.mem.eql(u8, J.str(J.field(params, "state")), "canceled"))) finished = true;
                        }
                        if (!finished) self.cancelDownload(guid) catch {};
                    }
                    self.downloadBehavior("deny") catch {};
                    self.browser.download_allocator = null;
                    self.browser.downloads = .empty;
                    self.browser.download_bytes = 0;
                    var dir = std.Io.Dir.cwd().openDir(p.io, self.browser.downloads_dir, .{ .iterate = true }) catch null;
                    if (dir) |*directory| {
                        defer directory.close(p.io);
                        var iterator = directory.iterate();
                        while (iterator.next(p.io) catch null) |entry| directory.deleteFile(p.io, entry.name) catch {};
                    }
                }
                const query = input.locator orelse Agent.Query{ .selector = input.args[0] };
                try page.click(query);
                while (std.Io.Clock.awake.now(p.io).toMilliseconds() < page.deadline_ms) {
                    _ = try page.eval("0");
                    _ = try Agent.call(a, &self.browser.socket, "Browser.getVersion", .{});
                    var guid: []const u8 = "";
                    var filename: []const u8 = "";
                    for (self.browser.downloads.items) |event| {
                        const params = J.field(event, "params");
                        if (J.number(J.field(params, "totalBytes")) > 20 * 1024 * 1024 or J.number(J.field(params, "receivedBytes")) > 20 * 1024 * 1024) {
                            try self.cancelDownload(J.str(J.field(params, "guid")));
                            return error.DownloadTooLarge;
                        }
                        if (std.mem.eql(u8, J.str(J.field(event, "method")), "Browser.downloadWillBegin")) {
                            guid = J.str(J.field(params, "guid"));
                            filename = J.str(J.field(params, "suggestedFilename"));
                        }
                        if (guid.len > 0 and std.mem.eql(u8, guid, J.str(J.field(params, "guid")))) {
                            const state = J.str(J.field(params, "state"));
                            if (std.mem.eql(u8, state, "canceled")) return error.DownloadCanceled;
                            if (std.mem.eql(u8, state, "completed")) {
                                const path = try a.print("{s}/{s}", .{ self.browser.downloads_dir, guid });
                                const bytes = try std.Io.Dir.cwd().readFileAlloc(p.io, path, a, .limited(20 * 1024 * 1024));
                                diagnostics.phase = .output;
                                try Agent.writeFile(p.io, input.args[if (input.locator == null) 1 else 0], bytes);
                                return J.val(a, .{ .filename = filename, .path = input.args[if (input.locator == null) 1 else 0], .bytes = bytes.len });
                            }
                        }
                    }
                    try p.io.sleep(.fromMilliseconds(25), .awake);
                }
                return error.DownloadTimeout;
            },
            else => return executePage(&page, input),
        }
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
    writer.interface.writeAll(bytes) catch |err| return if ((writer.err orelse err) == error.Canceled) error.Canceled else err;
    writer.interface.writeByte('\n') catch |err| return if ((writer.err orelse err) == error.Canceled) error.Canceled else err;
    writer.interface.flush() catch |err| return if ((writer.err orelse err) == error.Canceled) error.Canceled else err;
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
