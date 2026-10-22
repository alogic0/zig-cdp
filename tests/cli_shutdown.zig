const std = @import("std");
const H = @import("cli_support.zig");
pub fn run(c: H.Context) !void {
    var peer = try H.Session.start(c, "shutdown-peer", &.{});
    defer peer.deinit();
    for (0..8) |i| {
        var owner = try H.Session.start(c, try c.a.print("shutdown-{d}", .{i}), &.{});
        defer owner.deinit();
        const linux = std.os.linux;
        const fd = linux.pidfd_open(@intCast((try H.field(owner.ready, "pid")).integer), 0);
        if (linux.errno(fd) != .SUCCESS) return error.BrowserPidfdFailed;
        const file: H.Io.File = .{ .handle = @intCast(fd), .flags = .{ .nonblocking = false } };
        defer file.close(c.io);
        if (i % 2 == 0) {
            if (linux.errno(linux.pidfd_send_signal(file.handle, .STOP, null, 0)) != .SUCCESS) return error.BrowserSignalFailed;
            defer _ = linux.pidfd_send_signal(file.handle, .CONT, null, 0);
            try owner.child.signal(.TERM);
            try owner.done();
        } else {
            // Race a signal with the owner's periodic socket writes.
            try c.io.sleep(.fromMilliseconds(@intCast(90 + i)), .awake);
            try owner.child.signal(.INT);
            try owner.done();
        }
        try H.equal(try c.command(peer.path, &.{ "eval", "42" }), 42);
    }
    try peer.close();
}
