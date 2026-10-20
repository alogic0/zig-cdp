const std = @import("std");
const session = @import("cli_session.zig");
const J = @import("cdp").journey;

const help =
    \\Usage: zig-cdp --session PATH COMMAND [ARGS]
    \\
    \\serve [--allow ORIGIN]... [--browser PATH] [--headed]
    \\      [--idle-timeout SECONDS]    Own a persistent browser (foreground)
    \\status                           Browser version, URL, and session state
    \\allow ORIGIN                     Allow an HTTP(S) origin for this page
    \\open URL                         Navigate the existing page
    \\reload                           Reload the page
    \\content HTML                     Replace the document with fixture HTML
    \\eval JAVASCRIPT                  Evaluate an expression, await promises
    \\click CSS                        Click one matching element
    \\fill CSS TEXT                    Fill one input
    \\text CSS                         Read one element's inner text
    \\wait JAVASCRIPT                  Wait until an expression returns true
    \\timeout MILLISECONDS             Set page wait timeout (1..120000)
    \\screenshot PATH                  Write a PNG
    \\upload CSS PATH                  Set one file input
    \\download CSS PATH                Click and save a completed download
    \\close                            Stop the owned browser and server
    \\
    \\PATH is a new session directory for serve, the same directory for clients.
    \\The default idle timeout is 900 seconds. Replies are JSON; failures exit 1.
    \\File paths are resolved from the client's current working directory.
    \\Use --session before COMMAND; --help and --version need no session.
    \\
;

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        const reply = J.json(init.arena.allocator(), .{ .ok = false, .err = @errorName(err) }) catch return 1;
        std.Io.File.stdout().writeStreamingAll(init.io, reply) catch {};
        std.Io.File.stdout().writeStreamingAll(init.io, "\n") catch {};
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    var iterator = std.process.Args.Iterator.init(init.minimal.args);
    _ = iterator.next();
    const first = iterator.next() orelse "--help";
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "help")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, help);
        return 0;
    }
    if (std.mem.eql(u8, first, "--version")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "zig-cdp 0.1.0\n");
        return 0;
    }
    if (!std.mem.eql(u8, first, "--session")) return error.ExpectedSessionOption;
    const path = try absolute(a, init.io, iterator.next() orelse return error.MissingSessionPath);
    const command = iterator.next() orelse return error.MissingCommand;
    if (std.mem.eql(u8, command, "serve")) {
        var options: session.Options = .{ .directory = path };
        var origins: std.ArrayList([]const u8) = .empty;
        while (iterator.next()) |arg| {
            if (std.mem.eql(u8, arg, "--headed")) {
                options.browser.headless = false;
            } else if (std.mem.eql(u8, arg, "--browser")) {
                options.browser.executable = try absolute(a, init.io, iterator.next() orelse return error.MissingBrowserPath);
            } else if (std.mem.eql(u8, arg, "--allow")) {
                const origin = iterator.next() orelse return error.MissingOrigin;
                try session.validateOrigin(origin);
                try origins.append(a, origin);
            } else if (std.mem.eql(u8, arg, "--idle-timeout")) {
                options.idle_seconds = try std.fmt.parseInt(u32, iterator.next() orelse return error.MissingIdleTimeout, 10);
                if (options.idle_seconds == 0 or options.idle_seconds > 86400) return error.InvalidIdleTimeout;
            } else return error.UnknownServeOption;
        }
        options.origins = origins.items;
        try session.serve(init.gpa, init.io, options);
        return 0;
    }
    var args: std.ArrayList([]const u8) = .empty;
    while (iterator.next()) |arg| try args.append(a, arg);
    const op = try session.operation(command, args.items.len);
    switch (op) {
        .screenshot => args.items[0] = try absolute(a, init.io, args.items[0]),
        .upload, .download => args.items[1] = try absolute(a, init.io, args.items[1]),
        else => {},
    }
    const reply = try session.request(a, init.io, path, .{ .command = command, .args = args.items });
    try std.Io.File.stdout().writeStreamingAll(init.io, reply);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    const parsed = try std.json.parseFromSlice(std.json.Value, a, reply, .{});
    defer parsed.deinit();
    return if (J.boolean(J.field(parsed.value, "ok"))) 0 else 1;
}

fn absolute(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (path.len == 0) return error.EmptyPath;
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    return std.fs.path.resolve(a, &.{ cwd, path });
}
