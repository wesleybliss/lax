//! Typed real-time events. Parsing is lenient: unknown events and unknown
//! fields never fail, they surface as `.unknown` so protocol drift is visible.
//!
//! Verified against live traffic (2026-11): hello, message, user_typing,
//! im_marked, channel_marked, presence_change, pong, reconnect_url,
//! user_invalidated. Also seen live and deliberately ignored (`.unknown`):
//! user_interaction_changed, clear_megaphone_notification, visits_changed,
//! badge_counts_updated. Not yet verified live (shapes from Slack docs and
//! wee-slack): group_marked, mpim_marked, message_deleted.
//! Also verified: thread replies, message_replied, message_changed,
//! reaction_added, reaction_removed. Seen and ignored: thread_subscribed,
//! thread_marked, update_global_thread_state, activity.
const std = @import("std");

pub const Error = error{BadFrame} || std.mem.Allocator.Error;

pub const Message = struct {
    channel: []const u8,
    /// Absent for bot and system messages
    user: ?[]const u8,
    ts: []const u8,
    thread_ts: ?[]const u8,
    subtype: ?[]const u8,
    /// Slack mrkdwn, still HTML-escaped (`&lt; &gt; &amp;`)
    text: []const u8,
    /// Bookkeeping events (e.g. `message_replied`): never render these
    hidden: bool,
    /// The `files` array as sent, for the caller to read
    files: []const std.json.Value = &.{},

    pub fn isThreadReply(m: Message) bool {
        const t = m.thread_ts orelse return false;
        return !std.mem.eql(u8, t, m.ts);
    }
};

/// An edit: replaces the text of the message at `ts`
pub const Changed = struct {
    channel: []const u8,
    ts: []const u8,
    text: []const u8,
    files: []const std.json.Value = &.{},
};

/// A thread's parent got a new reply count (the hidden `message_replied`)
pub const ReplyCount = struct {
    channel: []const u8,
    ts: []const u8,
    count: u32,
};

pub const Deleted = struct {
    channel: []const u8,
    ts: []const u8,
};

pub const Typing = struct {
    channel: []const u8,
    user: []const u8,
    thread_ts: ?[]const u8,
};

pub const Marked = struct {
    channel: []const u8,
    ts: []const u8,
    /// `unread_count_display` when Slack sends it
    unread: ?u32,
    mentions: ?u32,
};

pub const Reaction = struct {
    added: bool,
    user: []const u8,
    /// Name with optional skin tone suffix, e.g. `+1::skin-tone-3`
    name: []const u8,
    channel: []const u8,
    ts: []const u8,
};

pub const Presence = struct {
    /// `active` or `away`
    state: []const u8,
    users: []const []const u8,
};

pub const Event = union(enum) {
    hello,
    message: Message,
    message_changed: Changed,
    message_deleted: Deleted,
    reply_count: ReplyCount,
    typing: Typing,
    marked: Marked,
    reaction: Reaction,
    presence: Presence,
    /// Refetch this user
    user_invalidated: []const u8,
    pong: u32,
    reconnect_url,
    /// Anything else, with its `type`
    unknown: []const u8,
};

/// Parses one text frame. Result strings live in `arena`.
pub fn parse(arena: std.mem.Allocator, frame: []const u8) Error!Event {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, frame, .{}) catch return error.BadFrame;
    if (root != .object) return error.BadFrame;
    const o = root.object;
    const kind = str(o, "type") orelse return error.BadFrame;
    const eql = std.mem.eql;

    if (eql(u8, kind, "hello")) return .hello;
    if (eql(u8, kind, "reconnect_url")) return .reconnect_url;
    if (eql(u8, kind, "pong")) return .{ .pong = if (int(o, "reply_to")) |n| n else 0 };
    if (eql(u8, kind, "message")) {
        if (str(o, "subtype")) |sub| {
            if (eql(u8, sub, "message_changed")) {
                const inner = obj(o, "message") orelse return error.BadFrame;
                return .{ .message_changed = .{
                    .channel = str(o, "channel") orelse return error.BadFrame,
                    .ts = str(inner, "ts") orelse return error.BadFrame,
                    .text = str(inner, "text") orelse "",
                    .files = arr(inner, "files"),
                } };
            }
            if (eql(u8, sub, "message_replied")) {
                const inner = obj(o, "message") orelse return error.BadFrame;
                return .{ .reply_count = .{
                    .channel = str(o, "channel") orelse return error.BadFrame,
                    .ts = str(inner, "ts") orelse return error.BadFrame,
                    .count = if (int(inner, "reply_count")) |n| n else 0,
                } };
            }
            if (eql(u8, sub, "message_deleted")) return .{ .message_deleted = .{
                .channel = str(o, "channel") orelse return error.BadFrame,
                .ts = str(o, "deleted_ts") orelse return error.BadFrame,
            } };
        }
    }
    if (eql(u8, kind, "message")) return .{ .message = .{
        .channel = str(o, "channel") orelse return error.BadFrame,
        .user = str(o, "user"),
        .ts = str(o, "ts") orelse return error.BadFrame,
        .thread_ts = str(o, "thread_ts"),
        .subtype = str(o, "subtype"),
        .text = str(o, "text") orelse "",
        .hidden = flag(o, "hidden"),
        .files = arr(o, "files"),
    } };
    if (eql(u8, kind, "user_typing")) return .{ .typing = .{
        .channel = str(o, "channel") orelse return error.BadFrame,
        .user = str(o, "user") orelse return error.BadFrame,
        .thread_ts = str(o, "thread_ts"),
    } };
    if (std.mem.endsWith(u8, kind, "_marked") and !std.mem.startsWith(u8, kind, "thread")) return .{ .marked = .{
        .channel = str(o, "channel") orelse return error.BadFrame,
        .ts = str(o, "ts") orelse return error.BadFrame,
        .unread = if (int(o, "unread_count_display")) |n| n else null,
        .mentions = if (int(o, "mention_count_display")) |n| n else null,
    } };
    if (eql(u8, kind, "reaction_added") or eql(u8, kind, "reaction_removed")) {
        const item = o.get("item") orelse return error.BadFrame;
        if (item != .object) return error.BadFrame;
        return .{ .reaction = .{
            .added = eql(u8, kind, "reaction_added"),
            .user = str(o, "user") orelse return error.BadFrame,
            .name = str(o, "reaction") orelse return error.BadFrame,
            .channel = str(item.object, "channel") orelse return error.BadFrame,
            .ts = str(item.object, "ts") orelse return error.BadFrame,
        } };
    }
    if (eql(u8, kind, "presence_change")) {
        var users: std.ArrayList([]const u8) = .empty;
        if (str(o, "user")) |u| try users.append(arena, u);
        if (o.get("users")) |list| if (list == .array) for (list.array.items) |u| {
            if (u == .string) try users.append(arena, u.string);
        };
        return .{ .presence = .{ .state = str(o, "presence") orelse return error.BadFrame, .users = users.items } };
    }
    if (eql(u8, kind, "user_invalidated")) {
        const u = o.get("user") orelse return error.BadFrame;
        return switch (u) {
            .string => |id| .{ .user_invalidated = id },
            .object => |uo| .{ .user_invalidated = str(uo, "id") orelse return error.BadFrame },
            else => error.BadFrame,
        };
    }
    return .{ .unknown = kind };
}

fn str(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

fn arr(o: std.json.ObjectMap, k: []const u8) []const std.json.Value {
    const v = o.get(k) orelse return &.{};
    return if (v == .array) v.array.items else &.{};
}

fn obj(o: std.json.ObjectMap, k: []const u8) ?std.json.ObjectMap {
    const v = o.get(k) orelse return null;
    return if (v == .object) v.object else null;
}

fn flag(o: std.json.ObjectMap, k: []const u8) bool {
    const v = o.get(k) orelse return false;
    return v == .bool and v.bool;
}

fn int(o: std.json.ObjectMap, k: []const u8) ?u32 {
    const v = o.get(k) orelse return null;
    return switch (v) {
        .integer => |n| std.math.cast(u32, n),
        else => null,
    };
}

fn parseFixture(arena: std.mem.Allocator, comptime name: []const u8) Error!Event {
    return parse(arena, @embedFile("fixtures/" ++ name));
}

test "message fixture" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const ev = try parseFixture(a.allocator(), "message.json");
    try std.testing.expectEqualStrings("D000000001", ev.message.channel);
    try std.testing.expectEqualStrings("U000000001", ev.message.user.?);
    try std.testing.expectEqual(@as(?[]const u8, null), ev.message.thread_ts);
    try std.testing.expect(std.mem.indexOf(u8, ev.message.text, "&lt;world&gt;") != null);
}

test "typing, marked, reaction, presence, user_invalidated, pong, hello" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try std.testing.expectEqualStrings("U000000001", (try parseFixture(arena, "user_typing.json")).typing.user);
    const m = (try parseFixture(arena, "im_marked.json")).marked;
    try std.testing.expectEqualStrings("1700000000.000100", m.ts);
    try std.testing.expectEqual(@as(?u32, 0), m.unread);
    const cm = (try parseFixture(arena, "channel_marked.json")).marked;
    try std.testing.expectEqual(@as(?u32, 3), cm.unread);
    try std.testing.expectEqual(@as(?u32, 1), cm.mentions);
    const r = (try parseFixture(arena, "reaction_added.json")).reaction;
    try std.testing.expect(r.added);
    try std.testing.expectEqualStrings("+1::skin-tone-3", r.name);
    const p = (try parseFixture(arena, "presence_change.json")).presence;
    try std.testing.expectEqual(@as(usize, 2), p.users.len);
    try std.testing.expectEqualStrings("U000000001", (try parseFixture(arena, "user_invalidated.json")).user_invalidated);
    try std.testing.expectEqual(@as(u32, 7), (try parseFixture(arena, "pong.json")).pong);
    try std.testing.expect((try parseFixture(arena, "hello.json")) == .hello);
}

test "unknown types and garbage" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const ev = try parse(a.allocator(), "{\"type\":\"some_new_thing\",\"x\":1}");
    try std.testing.expectEqualStrings("some_new_thing", ev.unknown);
    try std.testing.expectError(error.BadFrame, parse(a.allocator(), "not json"));
    try std.testing.expectError(error.BadFrame, parse(a.allocator(), "{\"type\":\"message\"}"));
}

test "thread reply, message_replied, edit, delete" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const reply = (try parseFixture(arena, "message_thread_reply.json")).message;
    try std.testing.expect(reply.isThreadReply());
    try std.testing.expect(!reply.hidden);
    const replied = (try parseFixture(arena, "message_replied.json")).reply_count;
    try std.testing.expectEqualStrings("1700000000.000100", replied.ts);
    try std.testing.expectEqual(@as(u32, 1), replied.count);
    const changed = (try parseFixture(arena, "message_changed.json")).message_changed;
    try std.testing.expectEqualStrings("1700000000.000100", changed.ts);
    try std.testing.expectEqualStrings("edited text", changed.text);
    const deleted = (try parseFixture(arena, "message_deleted.json")).message_deleted;
    try std.testing.expectEqualStrings("1700000000.000100", deleted.ts);
}
