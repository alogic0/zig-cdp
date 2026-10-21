//! CLI-test composition only. Each scenario owns an arena; command reports and
//! process handles have shorter explicit lifetimes. No production CDP imports.
const std = @import("std");
pub const S = @import("test_support");
pub const P = S.process;
pub const Io = std.Io;
pub const V = std.json.Value;
pub const field = S.json.field;
pub const str = S.json.str;
pub const arr = S.json.arr;
pub const is = S.json.is;
pub const eql = std.mem.eql;
pub fn check(ok: bool, message: []const u8) !void {
    if (!ok) {
        std.debug.print("ASSERT: {s}\n", .{message});
        return error.AssertionFailed;
    }
}
pub fn equal(actual: V, expected: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const want = try std.json.Stringify.valueAlloc(a, expected, .{});
    const got = try std.json.Stringify.valueAlloc(a, actual, .{});
    const parsed = try std.json.parseFromSlice(V, a, want, .{});
    if (!jsonEqual(actual, parsed.value)) {
        std.debug.print("ASSERT JSON: expected {s}; actual {s}\n", .{ want[0..@min(want.len, 4096)], got[0..@min(got.len, 4096)] });
        return error.AssertionFailed;
    }
}
fn jsonEqual(a: V, b: V) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .string => eql(u8, a.string, b.string),
        .number_string => eql(u8, a.number_string, b.number_string),
        .array => blk: {
            if (a.array.items.len != b.array.items.len) break :blk false;
            for (a.array.items, b.array.items) |x, y| if (!jsonEqual(x, y)) break :blk false;
            break :blk true;
        },
        .object => blk: {
            if (a.object.count() != b.object.count()) break :blk false;
            var it = a.object.iterator();
            while (it.next()) |e| if (!jsonEqual(e.value_ptr.*, b.object.get(e.key_ptr.*) orelse break :blk false)) break :blk false;
            break :blk true;
        },
    };
}
pub const Context = struct {
    a: std.mem.Allocator,
    io: Io,
    exe: []const u8,
    root: []const u8,
    scenario: []const u8,
    pub fn path(c: Context, name: []const u8) ![]const u8 {
        return std.fs.path.join(c.a, &.{ c.root, name });
    }
    pub fn parse(c: Context, data: []const u8) !V {
        return std.json.parseFromSliceLeaky(V, c.a, data, .{ .allocate = .alloc_always });
    }
    pub fn json(c: Context, value: anytype) ![]const u8 {
        return std.json.Stringify.valueAlloc(c.a, value, .{});
    }
    pub fn read(c: Context, path_name: []const u8) ![]u8 {
        return S.files.read(c.a, c.io, .{ .path = path_name, .limit = 20 * 1024 * 1024 });
    }
    pub fn write(c: Context, path_name: []const u8, data: []const u8) !void {
        try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = path_name, .data = data });
    }
    pub fn bytes(c: Context, path_name: []const u8, data: []const u8) !void {
        try S.files.expectBytes(c.a, c.io, .{ .path = path_name, .bytes = data });
    }
    pub fn exists(c: Context, path_name: []const u8) !bool {
        Io.Dir.cwd().access(c.io, path_name, .{}) catch |err| {
            if (err == error.FileNotFound) return false;
            return err;
        };
        return true;
    }
    pub fn dir(c: Context, path_name: []const u8) !void {
        try Io.Dir.cwd().createDirPath(c.io, path_name);
    }
    pub fn empty(c: Context, path_name: []const u8) !void {
        var d = try Io.Dir.cwd().openDir(c.io, path_name, .{ .iterate = true });
        defer d.close(c.io);
        var it = d.iterate();
        try check(try it.next(c.io) == null, "download staging is empty");
    }
    pub const Invoke = struct { ok: bool = true, stdin: ?[]const u8 = null, cwd: ?[]const u8 = null, timeout_ms: u32 = 20000 };
    pub fn invoke(c: Context, args: []const []const u8, options: Invoke) !V {
        const argv = try std.mem.concat(c.a, []const u8, &.{ &.{c.exe}, args });
        const report = try S.command.runReport(std.heap.page_allocator, c.io, .{ .run = .{
            .spawn = .{ .argv = argv, .cwd = if (options.cwd) |cwd| .{ .path = cwd } else .inherit },
            .stdout_limit = 20 * 1024 * 1024,
            .stderr_limit = 64 * 1024,
            .timeout_ms = options.timeout_ms,
            .exit_policy = .drain_output,
        }, .stdin = options.stdin });
        defer report.deinit(std.heap.page_allocator);
        errdefer std.debug.print("SCENARIO {s}; argv={any}; stdout={s}; stderr={s}\n", .{ c.scenario, argv, report.stdout[0..@min(report.stdout.len, 4096)], report.stderr[0..@min(report.stderr.len, 4096)] });
        try check(report.outcome == .completed and report.cleanup_failure == null and report.term != null, "command completed with bounded capture and clean ownership");
        const value = try c.parse(report.stdout);
        try equal(try field(value, "ok"), options.ok);
        try check((report.term.? == .exited and report.term.?.exited == 0) == options.ok, "exit status matches JSON outcome");
        return value;
    }
    pub fn command(c: Context, session: []const u8, args: []const []const u8) !V {
        const value = try c.invoke(try std.mem.concat(c.a, []const u8, &.{ &.{ "--session", session }, args }), .{});
        return field(value, "result");
    }
    pub fn failure(c: Context, session: []const u8, args: []const []const u8, code: []const u8) !void {
        const value = try c.invoke(try std.mem.concat(c.a, []const u8, &.{ &.{ "--session", session }, args }), .{ .ok = false });
        try equal(try field(value, "err"), code);
    }
    pub fn raw(c: Context, session: []const u8, payload: []const u8) !V {
        // The timeout covers connect, write and read, including oversized input.
        const Result = union(enum) { reply: anyerror!V, timeout: Io.Cancelable!void };
        var storage: [2]Result = undefined;
        var select: Io.Select(Result) = .init(c.io, &storage);
        defer select.cancelDiscard();
        try select.concurrent(.reply, rawInner, .{ c, session, payload });
        try select.concurrent(.timeout, Io.sleep, .{ c.io, Io.Duration.fromSeconds(10), .awake });
        return switch (try select.await()) {
            .reply => |r| try r,
            .timeout => error.RawRequestTimeout,
        };
    }
    fn rawInner(c: Context, session: []const u8, payload: []const u8) !V {
        const address = try Io.net.UnixAddress.init(try std.fs.path.join(c.a, &.{ session, "control.sock" }));
        const stream = try address.connect(c.io);
        defer stream.close(c.io);
        var wb: [4096]u8 = undefined;
        var writer = stream.writer(c.io, &wb);
        try writer.interface.writeAll(payload);
        try writer.interface.flush();
        var rb: [4096]u8 = undefined;
        var reader = stream.reader(c.io, &rb);
        // Server closes after its one newline reply; do not accept clipped data.
        const bytes_value = try reader.interface.allocRemaining(c.a, .limited(20 * 1024 * 1024));
        return c.parse(bytes_value);
    }
    pub fn request(c: Context, session: []const u8, input: anytype) !V {
        return c.raw(session, try c.a.print("{s}\n", .{try c.json(input)}));
    }
    pub fn http(c: Context, url: []const u8, method: std.http.Method) ![]const u8 {
        const Box = struct {
            c: Context,
            url: []const u8,
            method: std.http.Method,
            fn get(self: @This()) ![]const u8 {
                var client: std.http.Client = .{ .allocator = self.c.a, .io = self.c.io };
                defer client.deinit();
                const buffer = try self.c.a.alloc(u8, 1024 * 1024);
                var writer: Io.Writer = .fixed(buffer);
                const response = try client.fetch(.{ .location = .{ .url = self.url }, .method = self.method, .response_writer = &writer, .redirect_behavior = .not_allowed });
                try check(response.status == .ok, "independent browser HTTP request is 200");
                return writer.buffered();
            }
        };
        const Result = union(enum) { reply: anyerror![]const u8, timeout: Io.Cancelable!void };
        var storage: [2]Result = undefined;
        var select: Io.Select(Result) = .init(c.io, &storage);
        defer select.cancelDiscard();
        try select.concurrent(.reply, Box.get, .{Box{ .c = c, .url = url, .method = method }});
        try select.concurrent(.timeout, Io.sleep, .{ c.io, Io.Duration.fromSeconds(5), .awake });
        return switch (try select.await()) {
            .reply => |r| try r,
            .timeout => error.HttpTimeout,
        };
    }
};
pub const Session = struct {
    c: Context,
    path: []const u8,
    child: P.Child,
    log: Io.File,
    log_path: []const u8,
    ready: V,
    pub fn start(c: Context, name: []const u8, args: []const []const u8) !Session {
        const path_name = try c.path(name);
        const log_path = try c.path(try c.a.print("{s}.stderr", .{name}));
        const log = try Io.Dir.cwd().createFile(c.io, log_path, .{ .read = true });
        errdefer log.close(c.io);
        const argv = try std.mem.concat(c.a, []const u8, &.{ &.{ c.exe, "--session", path_name, "serve" }, args });
        var child = try P.Child.spawn(std.heap.page_allocator, c.io, .{ .argv = argv, .stdout = .pipe, .stderr = .{ .file = log } });
        errdefer {
            _ = child.stop(10000) catch {};
            child.deinit();
        }
        errdefer printLog(c, log_path);
        var buffer: [4096]u8 = undefined;
        var reader = P.PipeReader.init(child.stdout.?, c.io, &buffer);
        const line = try S.readiness.line(c.a, c.io, &child, &reader, .{ .max_bytes = 8192, .timeout_ms = 20000 });
        const ready = try c.parse(line);
        try equal(try field(ready, "ready"), true);
        return .{ .c = c, .path = path_name, .child = child, .log = log, .log_path = log_path, .ready = ready };
    }
    pub fn done(self: *Session) !void {
        errdefer printLog(self.c, self.log_path);
        const term = try self.child.wait(10000);
        try check(term == .exited and term.exited == 0, "serve exits successfully");
        try check(!try self.c.exists(self.path), "session directory and socket removed");
        try check(try self.c.exists(try str(self.ready, "profile")) == (try field(self.ready, "persistent_profile")).bool, "only caller-owned profile survives");
        try check(!try S.resources.present(self.c.io, @intCast((try field(self.ready, "pid")).integer)), "owned browser PID absent");
    }
    pub fn close(self: *Session) !void {
        _ = try self.c.command(self.path, &.{"close"});
        try self.done();
    }
    pub fn deinit(self: *Session) void {
        _ = self.child.stop(10000) catch |err| {
            std.debug.print("Session cleanup: {s}\n", .{@errorName(err)});
        };
        self.child.deinit();
        self.log.close(self.c.io);
    }
    pub fn browserUrl(self: Session, suffix: []const u8) ![]const u8 {
        return self.c.a.print("http://127.0.0.1:{d}{s}", .{ (try field(self.ready, "port")).integer, suffix });
    }
    pub fn pages(self: Session) ![]V {
        const value = try self.c.parse(try self.c.http(try self.browserUrl("/json/list"), .GET));
        var result: std.ArrayList(V) = .empty;
        for (value.array.items) |v| if (is(try field(v, "type"), "page")) {
            try result.append(self.c.a, v);
        };
        return result.toOwnedSlice(self.c.a);
    }
};
pub fn printLog(c: Context, path: []const u8) void {
    const file = Io.Dir.cwd().openFile(c.io, path, .{}) catch return;
    defer file.close(c.io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(c.io, &buffer);
    var excerpt: [8192]u8 = undefined;
    const n = reader.interface.readSliceShort(&excerpt) catch return;
    std.debug.print("{s}: {s}\n", .{ path, excerpt[0..n] });
}
