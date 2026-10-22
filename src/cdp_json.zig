//! Chrome may send unpaired UTF-16 escapes in truncated RemoteObject previews.
//! Preserve wire bytes; represent only those unrepresentable scalar values as
//! U+FFFD when decoding JSON into UTF-8. Other syntax errors remain errors.
const std = @import("std");
const A = std.mem.Allocator;
const V = std.json.Value;
pub fn parsed(a: A, bytes: []const u8) !std.json.Parsed(V) {
    return std.json.parseFromSlice(V, a, bytes, .{ .allocate = .alloc_always }) catch |err| {
        if (err != error.SyntaxError) return err;
        const copy = try a.dupe(u8, bytes);
        defer a.free(copy);
        if (!repair(copy)) return err;
        return std.json.parseFromSlice(V, a, copy, .{ .allocate = .alloc_always });
    };
}
pub fn value(a: A, bytes: []const u8) !V {
    return std.json.parseFromSliceLeaky(V, a, bytes, .{ .allocate = .alloc_always }) catch |err| {
        if (err != error.SyntaxError) return err;
        const copy = try a.dupe(u8, bytes);
        defer a.free(copy);
        if (!repair(copy)) return err;
        return std.json.parseFromSliceLeaky(V, a, copy, .{ .allocate = .alloc_always });
    };
}
fn code(bytes: []const u8) ?u16 {
    if (bytes.len < 6 or bytes[0] != '\\' or bytes[1] != 'u') return null;
    return std.fmt.parseInt(u16, bytes[2..6], 16) catch null;
}
fn repair(bytes: []u8) bool {
    var inside = false;
    var changed = false;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == '"') {
            inside = !inside;
            i += 1;
            continue;
        }
        if (!inside or bytes[i] != '\\') {
            i += 1;
            continue;
        }
        if (code(bytes[i..])) |unit| {
            if (std.unicode.utf16IsHighSurrogate(unit)) {
                if (code(bytes[i + 6 ..])) |low| if (std.unicode.utf16IsLowSurrogate(low)) {
                    i += 12;
                    continue;
                };
                @memcpy(bytes[i + 2 .. i + 6], "FFFD");
                changed = true;
            } else if (std.unicode.utf16IsLowSurrogate(unit)) {
                @memcpy(bytes[i + 2 .. i + 6], "FFFD");
                changed = true;
            }
            i += 6;
        } else i += @min(@as(usize, 2), bytes.len - i);
    }
    return changed;
}
test "Chrome preview surrogates decode without changing valid JSON strings" {
    const a = std.testing.allocator;
    var result = try parsed(a,
        \\{"high":"\ud83e","low":"\uddea","pair":"\ud83e\udded","literal":"\\ud83e","quote":"\"\ud83e"}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("�", result.value.object.get("high").?.string);
    try std.testing.expectEqualStrings("�", result.value.object.get("low").?.string);
    try std.testing.expectEqualStrings("🧭", result.value.object.get("pair").?.string);
    try std.testing.expectEqualStrings("\\ud83e", result.value.object.get("literal").?.string);
    try std.testing.expectEqualStrings("\"�", result.value.object.get("quote").?.string);
    try std.testing.expectError(error.SyntaxError, parsed(a, "{\"x\":\"\\ud83e\", bad}"));
}
