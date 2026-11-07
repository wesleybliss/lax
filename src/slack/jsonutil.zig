//! Small helpers for reading Slack's loosely-shaped JSON.
const std = @import("std");

pub fn str(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

pub fn flag(o: std.json.ObjectMap, k: []const u8) bool {
    const v = o.get(k) orelse return false;
    return v == .bool and v.bool;
}

pub fn obj(o: std.json.ObjectMap, k: []const u8) ?std.json.ObjectMap {
    const v = o.get(k) orelse return null;
    return if (v == .object) v.object else null;
}

pub fn arr(o: std.json.ObjectMap, k: []const u8) []const std.json.Value {
    const v = o.get(k) orelse return &.{};
    return if (v == .array) v.array.items else &.{};
}

/// `response_metadata.next_cursor`, or null on the last page
pub fn nextCursor(root: std.json.Value) ?[]const u8 {
    const meta = obj(root.object, "response_metadata") orelse return null;
    const c = str(meta, "next_cursor") orelse return null;
    return if (c.len == 0) null else c;
}
