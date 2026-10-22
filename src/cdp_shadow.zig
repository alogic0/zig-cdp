//! Explicit author shadow roots; no page instrumentation or implicit piercing.
const std = @import("std");
const J = @import("cdp_journey.zig");
const V = std.json.Value;
pub fn validate(hosts: []const []const u8) !void {
    if (hosts.len > 16) return error.ShadowDepthExceeded;
    for (hosts) |host| if (host.len == 0 or host.len > 8192) return error.InvalidLocator;
}
pub fn root(page: anytype) ![]const u8 {
    try validate(page.shadows);
    var object = J.field(try page.command("Runtime.evaluate", .{ .expression = "document", .objectGroup = page.group }), "result");
    for (page.shadows) |host| {
        const old = J.str(J.field(object, "objectId"));
        const result = try page.command("Runtime.callFunctionOn", .{ .objectId = old, .functionDeclaration = "function(css){const a=this.querySelectorAll(css);if(a.length!==1)return {count:a.length};return a[0]}", .arguments = .{.{ .value = host }}, .objectGroup = page.group });
        if (J.field(result, "exceptionDetails") != .null) return error.InvalidLocator;
        const element = J.field(result, "result");
        if (!std.mem.eql(u8, J.str(J.field(element, "subtype")), "node")) {
            const counts = try page.command("Runtime.callFunctionOn", .{ .objectId = J.field(element, "objectId"), .functionDeclaration = "function(){return this.count}", .returnByValue = true });
            return if (J.number(J.field(J.field(counts, "result"), "value")) > 1) error.AmbiguousShadowHost else error.ShadowHostNotFound;
        }
        const description = J.field(try page.command("DOM.describeNode", .{ .objectId = J.field(element, "objectId"), .depth = 0, .pierce = true }), "node");
        const roots = J.field(description, "shadowRoots");
        if (roots != .array) return error.ShadowRootNotFound;
        var selected: V = .null;
        for (roots.array.items) |candidate| if (!std.mem.eql(u8, J.str(J.field(candidate, "shadowRootType")), "user-agent")) {
            selected = candidate;
            break;
        };
        if (selected == .null) return error.ShadowRootNotFound;
        object = J.field(try page.command("DOM.resolveNode", .{ .backendNodeId = J.field(selected, "backendNodeId"), .objectGroup = page.group }), "object");
        _ = try page.command("Runtime.releaseObject", .{ .objectId = old });
        _ = try page.command("Runtime.releaseObject", .{ .objectId = J.field(element, "objectId") });
    }
    return J.str(J.field(object, "objectId"));
}
pub fn contains(page: anytype, scope: []const u8, backend: V) !bool {
    if (backend == .null) return false;
    const object = J.field(try page.command("DOM.resolveNode", .{ .backendNodeId = backend, .objectGroup = page.group }), "object");
    defer _ = page.command("Runtime.releaseObject", .{ .objectId = J.field(object, "objectId") }) catch {};
    const value = try page.command("Runtime.callFunctionOn", .{ .objectId = J.field(object, "objectId"), .functionDeclaration = "function(root){if(this.getRootNode()===root)return true;return [...root.querySelectorAll('slot')].some(s=>s.assignedElements({flatten:true}).some(n=>n===this||n.contains(this)))}", .arguments = .{.{ .objectId = scope }}, .returnByValue = true });
    return J.boolean(J.field(J.field(value, "result"), "value"));
}
pub fn discover(page: anytype, limit: usize) !V {
    const scope = try root(page);
    defer _ = page.command("Runtime.releaseObject", .{ .objectId = scope }) catch {};
    const node = J.field(try page.command("DOM.describeNode", .{ .objectId = scope, .depth = -1, .pierce = true }), "node");
    var scan: Scan = .{ .a = page.a, .limit = limit };
    try scan.walk(node, "", page.shadows, 0);
    return J.val(page.a, .{ .roots = scan.items.items, .visited_nodes = scan.nodes, .returned_bytes = scan.bytes });
}
const Scan = struct {
    a: std.mem.Allocator,
    limit: usize,
    items: std.ArrayList(V) = .empty,
    nodes: usize = 0,
    bytes: usize = 0,
    fn walk(self: *Scan, node: V, path: []const u8, hosts: []const []const u8, depth: usize) anyerror!void {
        self.nodes += 1;
        if (self.nodes > 10000 or depth > 128) return error.ShadowNodeLimitExceeded;
        const roots = J.field(node, "shadowRoots");
        if (roots == .array) for (roots.array.items) |shadow| {
            const kind = J.str(J.field(shadow, "shadowRootType"));
            if (std.mem.eql(u8, kind, "user-agent")) continue;
            if (hosts.len == 16 or self.items.items.len == 64) return error.ShadowDepthExceeded;
            const chain = try self.a.alloc([]const u8, hosts.len + 1);
            @memcpy(chain[0..hosts.len], hosts);
            chain[hosts.len] = path;
            const entry = try J.val(self.a, .{ .hosts = chain, .type = kind });
            self.bytes += (try J.json(self.a, entry)).len + 1;
            if (self.bytes > self.limit) return error.ShadowOutputLimitExceeded;
            try self.items.append(self.a, entry);
            try self.walk(shadow, "", chain, depth + 1);
        };
        const children = J.field(node, "children");
        if (children != .array) return;
        var counts: std.StringHashMapUnmanaged(usize) = .empty;
        defer counts.deinit(self.a);
        for (children.array.items) |child| {
            if (J.number(J.field(child, "nodeType")) != 1) continue;
            const tag = J.str(J.field(child, "localName"));
            const count = try counts.getOrPut(self.a, tag);
            if (!count.found_existing) count.value_ptr.* = 0;
            count.value_ptr.* += 1;
            const nth = count.value_ptr.*;
            const selector = try self.a.print("{s}{s}{s}:nth-of-type({d})", .{ path, if (path.len > 0) " > " else "", tag, nth });
            try self.walk(child, selector, hosts, depth + 1);
        }
    }
};
