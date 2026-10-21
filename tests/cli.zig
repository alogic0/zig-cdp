const std = @import("std");
const H = @import("cli_support.zig");
const S = H.S;
const F = @import("http_fixture");
comptime {
    if (S.compiled_mode != @import("builtin").mode or F.compiled_mode != @import("builtin").mode) @compileError("CLI fixture/support profile mismatch");
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args.next() orelse return error.MissingCli, init.arena.allocator());
    const selected = if (args.next()) |flag| blk: {
        if (!std.mem.eql(u8, flag, "--case")) return error.InvalidRunnerArgument;
        break :blk args.next() orelse return error.MissingScenario;
    } else null;
    if (args.next() != null) return error.InvalidRunnerArgument;
    const executable_bytes = try S.files.read(init.gpa, init.io, .{ .path = exe, .limit = 128 * 1024 * 1024 });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(executable_bytes, &digest, .{});
    init.gpa.free(executable_bytes);
    std.debug.print("CLI acceptance native={s} support={s} http={s} compiler={s} cli_sha256={s}\n", .{ @tagName(@import("builtin").mode), @tagName(S.compiled_mode), @tagName(F.compiled_mode), @import("builtin").zig_version_string, std.fmt.bytesToHex(digest, .lower) });
    const cases = [_]struct { name: []const u8, run: *const fn (H.Context) anyerror!void }{
        .{ .name = "contract", .run = @import("cli_contract.zig").run },
        .{ .name = "agent", .run = @import("cli_agent.zig").run },
        .{ .name = "lifecycle", .run = @import("cli_lifecycle.zig").run },
        .{ .name = "discovery", .run = @import("cli_faults.zig").run },
        .{ .name = "endpoint", .run = @import("cli_endpoint.zig").run },
        .{ .name = "resources", .run = @import("cli_resources.zig").run },
    };
    var completed: usize = 0;
    for (cases) |case| {
        if (selected) |name| if (!std.mem.eql(u8, name, case.name)) continue;
        var workspace = try S.Workspace.init(init.gpa, init.io, .{ .prefix = "cdp-native-cli-" });
        defer workspace.close(.failure) catch |err| std.debug.print("Workspace cleanup: {s}\n", .{@errorName(err)});
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        var trace: H.Trace = .{};
        const c: H.Context = .{ .a = arena.allocator(), .io = init.io, .exe = exe, .root = workspace.path, .scenario = case.name, .trace = &trace };
        errdefer std.debug.print("FAIL scenario={s}; last operation={s}\n", .{ case.name, trace.buffer[0..trace.len] });
        try case.run(c);
        try workspace.close(.success);
        completed += 1;
        std.debug.print("PASS {s}\n", .{case.name});
    }
    if (completed == 0) return error.UnknownScenario;
    std.debug.print("PASS native CLI: {d} scenario groups\n", .{completed});
}
