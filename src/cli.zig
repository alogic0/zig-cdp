const std = @import("std");
const session = @import("cli_session.zig");
const J = @import("cdp").journey;
const Agent = @import("cdp").agent;
const endpoint = @import("cli_endpoint.zig");

const help =
    \\Usage: zig-cdp --session PATH COMMAND [ARGS]
    \\       zig-cdp --endpoint URL COMMAND [--tab ID] [ARGS]
    \\
    \\serve [--allow ORIGIN]... [--browser PATH] [--headed]
    \\      [--user-data-dir PATH] [--idle-timeout SECONDS]
    \\                                Own a persistent browser (foreground)
    \\status                           Browser version, URL, and session state
    \\tabs                             List tab IDs, titles, URLs, and selection
    \\new-tab [URL]                    Create and select a tab (default blank)
    \\switch-tab ID                    Select a tab for subsequent commands
    \\close-tab [ID]                   Close a tab (default selected)
    \\allow ORIGIN                     Allow an HTTP(S) origin for session tabs
    \\open URL                         Navigate the existing page
    \\reload                           Reload the page
    \\content HTML                     Replace the document with fixture HTML
    \\eval JAVASCRIPT                  Evaluate an expression, await promises
    \\click CSS                        Click one matching element
    \\fill CSS TEXT                    Fill one input
    \\text CSS                         Read one element's inner text
    \\read [LOCATOR]                   Read bounded rendered text (default body)
    \\snapshot                         Read bounded Chrome accessibility nodes
    \\select CSS VALUE                 Select one enabled native option
    \\press KEY                        Press a key or modifier combination
    \\wait JAVASCRIPT                  Wait until an expression returns true
    \\timeout MILLISECONDS             Set page wait timeout (1..120000)
    \\screenshot PATH                  Write a PNG
    \\upload CSS PATH                  Set one file input
    \\download CSS PATH                Click and save a completed download
    \\close                            Stop the owned browser and server
    \\
    \\LOCATOR: --selector CSS | --role ROLE [--name NAME] | --text TEXT
    \\Element commands also accept LOCATOR instead of positional CSS.
    \\Options: --tab ID, --timeout MS, --limit BYTES, --state STATE
    \\         --value TEXT | --value-file PATH|- (fill/select)
    \\         --script PATH|- (eval), --key KEY (press)
    \\         --full-page | --viewport (screenshot), --out PATH
    \\
    \\PATH is a new session directory for serve, the same directory for clients.
    \\--user-data-dir uses an existing, unlocked profile and preserves it on close.
    \\Without it, the browser uses a fresh temporary profile and isolated context.
    \\Chrome selects a free loopback port; readiness and status report that port.
    \\The default idle timeout is 900 seconds. Replies are JSON; failures exit 1.
    \\File paths are resolved from the client's current working directory.
    \\Use --session before COMMAND; --help and --version need no session.
    \\--endpoint accepts loopback HTTP discovery or a browser WebSocket URL.
    \\Endpoint commands disconnect when done and never stop the browser.
    \\Use --tab ID for page operations; close-tab explicitly closes one tab.
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
    const borrowed = std.mem.eql(u8, first, "--endpoint");
    if (!borrowed and !std.mem.eql(u8, first, "--session")) return error.ExpectedSessionOption;
    const target = iterator.next() orelse return error.MissingSessionPath;
    const path = if (borrowed) target else try absolute(a, init.io, target);
    const command = iterator.next() orelse return error.MissingCommand;
    if (std.mem.eql(u8, command, "serve")) {
        if (borrowed) return error.InvalidEndpointCommand;
        var options: session.Options = .{ .directory = path };
        var origins: std.ArrayList([]const u8) = .empty;
        while (iterator.next()) |arg| {
            if (std.mem.eql(u8, arg, "--headed")) {
                options.browser.headless = false;
            } else if (std.mem.eql(u8, arg, "--browser")) {
                options.browser.executable = try absolute(a, init.io, iterator.next() orelse return error.MissingBrowserPath);
            } else if (std.mem.eql(u8, arg, "--user-data-dir")) {
                options.browser.user_data_dir = try absolute(a, init.io, iterator.next() orelse return error.MissingProfilePath);
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
    var input: session.Request = .{ .command = command };
    var args: std.ArrayList([]const u8) = .empty;
    var output: ?[]const u8 = null;
    var literal = false;
    var value_supplied = false;
    var screenshot_mode = false;
    while (iterator.next()) |arg| {
        if (!literal and std.mem.eql(u8, arg, "--")) {
            literal = true;
        } else if (!literal and std.mem.startsWith(u8, arg, "--")) {
            input.modern = true;
            if (std.mem.eql(u8, arg, "--full-page") or std.mem.eql(u8, arg, "--viewport")) {
                if (screenshot_mode or !std.mem.eql(u8, command, "screenshot")) return error.InvalidOption;
                screenshot_mode = true;
                input.full_page = std.mem.eql(u8, arg, "--full-page");
                continue;
            }
            const value = iterator.next() orelse return error.MissingOptionValue;
            if (std.mem.eql(u8, arg, "--selector") or std.mem.eql(u8, arg, "--role") or std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "--text")) {
                if (input.locator == null) input.locator = .{};
                const query = &input.locator.?;
                const destination = if (std.mem.eql(u8, arg, "--selector")) &query.selector else if (std.mem.eql(u8, arg, "--role")) &query.role else if (std.mem.eql(u8, arg, "--name")) &query.name else &query.text;
                if (destination.* != null) return error.InvalidLocator;
                destination.* = value;
            } else if (std.mem.eql(u8, arg, "--tab")) {
                if (input.tab != null) return error.InvalidOption;
                input.tab = value;
            } else if (std.mem.eql(u8, arg, "--timeout")) {
                if (input.timeout_ms != null) return error.InvalidOption;
                input.timeout_ms = std.fmt.parseInt(u32, value, 10) catch return error.InvalidTimeout;
            } else if (std.mem.eql(u8, arg, "--limit")) {
                if (!std.mem.eql(u8, command, "read") and !std.mem.eql(u8, command, "snapshot")) return error.InvalidOption;
                input.limit = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLimit;
            } else if (std.mem.eql(u8, arg, "--state")) {
                if (!std.mem.eql(u8, command, "wait")) return error.InvalidOption;
                input.state = value;
            } else if (std.mem.eql(u8, arg, "--out")) {
                if (output != null) return error.InvalidOption;
                output = try absolute(a, init.io, value);
            } else if (std.mem.eql(u8, arg, "--value") or std.mem.eql(u8, arg, "--value-file")) {
                if (value_supplied or (!std.mem.eql(u8, command, "fill") and !std.mem.eql(u8, command, "select"))) return error.InvalidOption;
                value_supplied = true;
                try args.append(a, if (std.mem.eql(u8, arg, "--value-file")) try readInput(a, init.io, value) else value);
            } else if (std.mem.eql(u8, arg, "--script")) {
                if (!std.mem.eql(u8, command, "eval") or value_supplied) return error.InvalidOption;
                value_supplied = true;
                try args.append(a, try readInput(a, init.io, value));
            } else if (std.mem.eql(u8, arg, "--key")) {
                if (!std.mem.eql(u8, command, "press")) return error.InvalidOption;
                try args.append(a, value);
            } else return error.UnknownOption;
        } else try args.append(a, arg);
    }
    if (std.mem.eql(u8, command, "screenshot") and output != null) {
        try args.append(a, output.?);
        output = null;
    }
    input.args = args.items;
    const op = try session.operation(input);
    switch (op) {
        .screenshot => args.items[0] = try absolute(a, init.io, args.items[0]),
        .upload, .download => {
            const index: usize = if (input.locator == null) 1 else 0;
            args.items[index] = try absolute(a, init.io, args.items[index]);
        },
        else => {},
    }
    const reply = if (borrowed) try endpoint.run(a, init.io, path, input) else try session.request(a, init.io, path, input);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, reply, .{});
    defer parsed.deinit();
    if (output) |destination| if (J.boolean(J.field(parsed.value, "ok"))) {
        try Agent.writeFile(init.io, destination, reply);
        try std.Io.File.stdout().writeStreamingAll(init.io, try J.json(a, .{ .ok = true, .file = destination }));
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return 0;
    };
    try std.Io.File.stdout().writeStreamingAll(init.io, reply);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    return if (J.boolean(J.field(parsed.value, "ok"))) 0 else 1;
}

fn readInput(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "-")) {
        var buffer: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().reader(io, &buffer);
        return reader.interface.allocRemaining(a, .limited(1024 * 1024));
    }
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
}

fn absolute(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (path.len == 0) return error.EmptyPath;
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    return std.fs.path.resolve(a, &.{ cwd, path });
}
