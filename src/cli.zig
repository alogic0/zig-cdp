const std = @import("std");
const session = @import("cli_session.zig");
const J = @import("cdp").journey;
const Agent = @import("cdp").agent;
const observe = @import("cli_observe.zig");
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
    \\shadow-roots                     Discover author shadow host paths and types
    \\frames                           List frame IDs, parents, names and URLs
    \\new-tab [URL] [--background]     Create and select a tab (default blank)
    \\switch-tab ID [--background]    Select a tab; background is session-only
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
    \\upload CSS PATH                  Replace one file input selection
    \\upload LOCATOR --file PATH...     Set 1..64 files; multiple control required
    \\download CSS PATH                Click and save a completed download
    \\drag SOURCE DESTINATION         Held drag; --hold MS (300), --steps N (12)
    \\  LOCATOR --to-selector CSS | --to-role ROLE [--to-name NAME] | --to-text TEXT
    \\protocol METHOD [--params FILE|-] Supported page CDP call; JSON object params
    \\sequence --file FILE|-           Version 1, 1..128 steps, one --timeout budget
    \\pause MS                        Delay 0..10000 ms within the command budget
    \\observe --tab ID --out NEW_PATH  Independent finite capture; wait for readiness
    \\  --events console,exceptions,network --duration MS (default 30000; max 120000)
    \\  --body-method METHOD --body-url EXACT_URL (optional matched response text)
    \\  --max-events N (4096), --max-bytes N (8388608), --body-limit N (1048576)
    \\  Limits above are ceilings; stdout emits readiness and a final summary.
    \\close                            Stop the owned browser and server
    \\
    \\LOCATOR: --selector CSS | --role ROLE [--name NAME] | --text TEXT
    \\Element commands also accept LOCATOR instead of positional CSS.
    \\Options: --tab ID, --frame ID, --shadow HOST_CSS (repeatable), --timeout MS, --limit BYTES, --state STATE
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
    var input: session.Request = .{ .command = "" };
    var diagnostics: Agent.Diagnostics = .{};
    return run(init, &input, &diagnostics) catch |err| {
        const reply = session.failure(init.arena.allocator(), input, err, diagnostics) catch return 1;
        std.Io.File.stdout().writeStreamingAll(init.io, reply) catch {};
        std.Io.File.stdout().writeStreamingAll(init.io, "\n") catch {};
        return 1;
    };
}

fn run(init: std.process.Init, input: *session.Request, diagnostics: *Agent.Diagnostics) !u8 {
    const a = init.arena.allocator();
    var iterator = std.process.Args.Iterator.init(init.minimal.args);
    _ = iterator.next();
    const first = iterator.next() orelse "--help";
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "help")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, help);
        return 0;
    }
    if (std.mem.eql(u8, first, "--version")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "zig-cdp 0.3.0\n");
        return 0;
    }
    const borrowed = std.mem.eql(u8, first, "--endpoint");
    if (!borrowed and !std.mem.eql(u8, first, "--session")) return error.ExpectedSessionOption;
    const target = iterator.next() orelse return error.MissingSessionPath;
    const path = if (borrowed) target else try absolute(a, init.io, target);
    const command = iterator.next() orelse return error.MissingCommand;
    input.command = command;
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
    if (std.mem.eql(u8, command, "observe")) {
        var options: observe.Options = .{};
        var seen: std.StringHashMap(void) = .init(a);
        while (iterator.next()) |option| {
            if (seen.contains(option)) return error.InvalidOption;
            try seen.put(option, {});
            const value = iterator.next() orelse return error.MissingOptionValue;
            if (std.mem.eql(u8, option, "--tab")) options.tab = value else if (std.mem.eql(u8, option, "--out")) options.out = try absolute(a, init.io, value) else if (std.mem.eql(u8, option, "--events")) options.events = value else if (std.mem.eql(u8, option, "--duration")) options.duration = std.fmt.parseInt(u32, value, 10) catch return error.InvalidLimit else if (std.mem.eql(u8, option, "--max-events")) options.max_events = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLimit else if (std.mem.eql(u8, option, "--max-bytes")) options.max_bytes = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLimit else if (std.mem.eql(u8, option, "--body-limit")) options.body_limit = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLimit else if (std.mem.eql(u8, option, "--body-url")) options.body_url = value else if (std.mem.eql(u8, option, "--body-method")) options.body_method = value else return error.UnknownOption;
        }
        return observe.run(a, init.gpa, init.io, path, borrowed, options);
    }
    input.* = .{ .command = command };
    var args: std.ArrayList([]const u8) = .empty;
    var shadows: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    var output: ?[]const u8 = null;
    var literal = false;
    var value_supplied = false;
    var screenshot_mode = false;
    while (iterator.next()) |arg| {
        if (!literal and std.mem.eql(u8, arg, "--")) {
            literal = true;
        } else if (!literal and std.mem.startsWith(u8, arg, "--")) {
            input.modern = true;
            if (std.mem.eql(u8, arg, "--background")) {
                if (input.background) return error.InvalidOption;
                input.background = true;
                continue;
            }
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
            } else if (std.mem.startsWith(u8, arg, "--to-")) {
                if (!std.mem.eql(u8, command, "drag")) return error.InvalidOption;
                if (input.destination == null) input.destination = .{};
                const q = &input.destination.?;
                const destination = if (std.mem.eql(u8, arg, "--to-selector")) &q.selector else if (std.mem.eql(u8, arg, "--to-role")) &q.role else if (std.mem.eql(u8, arg, "--to-name")) &q.name else if (std.mem.eql(u8, arg, "--to-text")) &q.text else return error.UnknownOption;
                if (destination.* != null) return error.InvalidLocator;
                destination.* = value;
            } else if (std.mem.eql(u8, arg, "--hold")) {
                if (!std.mem.eql(u8, command, "drag")) return error.InvalidOption;
                input.hold_ms = std.fmt.parseInt(u32, value, 10) catch return error.InvalidDrag;
            } else if (std.mem.eql(u8, arg, "--steps")) {
                if (!std.mem.eql(u8, command, "drag")) return error.InvalidOption;
                input.steps = std.fmt.parseInt(u32, value, 10) catch return error.InvalidDrag;
            } else if (std.mem.eql(u8, arg, "--file") and std.mem.eql(u8, command, "upload")) {
                if (files.items.len == 64) return error.FileCountExceeded;
                try files.append(a, try absolute(a, init.io, value));
            } else if (std.mem.eql(u8, arg, "--params") or std.mem.eql(u8, arg, "--file")) {
                if (value_supplied or !(std.mem.eql(u8, command, "protocol") and std.mem.eql(u8, arg, "--params") or std.mem.eql(u8, command, "sequence") and std.mem.eql(u8, arg, "--file"))) return error.InvalidOption;
                value_supplied = true;
                try args.append(a, try readInput(a, init.io, value));
            } else if (std.mem.eql(u8, arg, "--shadow")) {
                if (shadows.items.len == 16) return error.ShadowDepthExceeded;
                try shadows.append(a, value);
            } else if (std.mem.eql(u8, arg, "--frame")) {
                if (input.frame != null) return error.InvalidOption;
                input.frame = value;
            } else if (std.mem.eql(u8, arg, "--tab")) {
                if (input.tab != null) return error.InvalidOption;
                input.tab = value;
            } else if (std.mem.eql(u8, arg, "--timeout")) {
                if (input.timeout_ms != null) return error.InvalidOption;
                input.timeout_ms = std.fmt.parseInt(u32, value, 10) catch return error.InvalidTimeout;
            } else if (std.mem.eql(u8, arg, "--limit")) {
                if (!std.mem.eql(u8, command, "read") and !std.mem.eql(u8, command, "snapshot") and !std.mem.eql(u8, command, "shadow-roots")) return error.InvalidOption;
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
    if (std.mem.eql(u8, command, "protocol") and args.items.len == 1) try args.append(a, "{}");
    if (std.mem.eql(u8, command, "sequence") and args.items.len == 1) {
        var sequence = try session.parseSequence(a, args.items[0]);
        defer sequence.deinit();
        for (sequence.value.steps) |*step| {
            if (std.mem.eql(u8, step.command, "upload") and step.files.len > 0) {
                const paths = try a.alloc([]const u8, step.files.len);
                for (step.files, 0..) |file, i| paths[i] = try absolute(a, init.io, file);
                step.files = paths;
                try Agent.validateFiles(init.io, paths);
            } else if (std.mem.eql(u8, step.command, "screenshot") or std.mem.eql(u8, step.command, "upload")) {
                const index: usize = if (std.mem.eql(u8, step.command, "screenshot") or step.locator != null) 0 else 1;
                const copy = try a.dupe([]const u8, step.args);
                copy[index] = try absolute(a, init.io, copy[index]);
                step.args = copy;
                if (std.mem.eql(u8, step.command, "upload")) try Agent.validateFiles(init.io, &.{copy[index]});
            }
        }
        args.items[0] = try J.json(a, sequence.value);
    }
    input.files = files.items;
    input.shadows = shadows.items;
    input.args = args.items;
    const op = try session.operation(input.*);
    switch (op) {
        .screenshot => args.items[0] = try absolute(a, init.io, args.items[0]),
        .upload => {
            if (input.files.len == 0) {
                const index: usize = if (input.locator == null) 1 else 0;
                args.items[index] = try absolute(a, init.io, args.items[index]);
                try Agent.validateFiles(init.io, &.{args.items[index]});
            } else try Agent.validateFiles(init.io, input.files);
        },
        .download => {
            const index: usize = if (input.locator == null) 1 else 0;
            args.items[index] = try absolute(a, init.io, args.items[index]);
        },
        else => {},
    }
    diagnostics.phase = .connect;
    const reply = if (borrowed) try endpoint.run(a, init.io, path, input.*) else try session.request(a, init.io, path, input.*);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, reply, .{});
    defer parsed.deinit();
    if (output) |destination| if (J.boolean(J.field(parsed.value, "ok"))) {
        diagnostics.phase = .output;
        diagnostics.action = switch (op) {
            .click, .fill, .select, .press, .drag, .protocol, .sequence, .upload, .download, .open, .reload, .content, .eval, .@"new-tab", .@"switch-tab", .@"close-tab", .close => .completed,
            else => .not_started,
        };
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
