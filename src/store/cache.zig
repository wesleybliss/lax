//! The last known state on disk, so the app opens with it and updates:
//! `<cache dir>/teams.json` (the workspaces) and `<cache dir>/<team>.json`
//! (its conversations, people and the last few messages of each).
//! Messages are stored in clear text, as Slack's own app does: the files are
//! readable by their owner only.
const std = @import("std");
const root = @import("root.zig");

const Store = root.Store;

/// Messages kept per conversation
pub const keep_messages = 25;
const version = 1;

const FReaction = struct { name: []const u8, count: u32, mine: bool = false };
const FMessage = struct {
    ts: []const u8,
    user: ?[]const u8 = null,
    text: []const u8 = "",
    thread_ts: ?[]const u8 = null,
    subtype: ?[]const u8 = null,
    reply_count: u32 = 0,
    reactions: []const FReaction = &.{},
};
const FChannel = struct {
    id: []const u8,
    name: []const u8 = "",
    kind: root.Kind,
    user_id: ?[]const u8 = null,
    dormant: bool = false,
    listed: bool = true,
    activity: []const u8 = "",
    messages: []const FMessage = &.{},
};
const FTeamFile = struct {
    version: u32 = 0,
    self_id: []const u8 = "",
    team_name: []const u8 = "",
    sidebar_mode: root.SidebarMode = .active,
    last_selected: []const u8 = "",
    users: []const root.User = &.{},
    channels: []const FChannel = &.{},
};
const FTeam = struct { id: []const u8, name: []const u8, url: []const u8 };
const FTeams = struct {
    version: u32 = 0,
    active: []const u8 = "",
    teams: []const FTeam = &.{},
};

fn file_mode() std.Io.File.Permissions {
    return if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(0o600) else .default_file;
}

fn dir_mode() std.Io.File.Permissions {
    return if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(0o700) else .default_file;
}

fn write(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8, data: []const u8) void {
    _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, dir_mode()) catch return;
    const path = std.fs.path.join(gpa, &.{ dir, name }) catch return;
    defer gpa.free(path);
    // A temp file renamed over the old one: a crash never leaves half a file
    const tmp = std.fmt.allocPrint(gpa, "{s}.tmp", .{path}) catch return;
    defer gpa.free(tmp);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data, .flags = .{ .permissions = file_mode() } }) catch return;
    std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io) catch {};
}

fn read(arena: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) ?[]u8 {
    const path = std.fs.path.join(arena, &.{ dir, name }) catch return null;
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch null;
}

/// Writes the shown workspace and the workspace list
pub fn save(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, st: *const Store) void {
    if (st.active_team.len == 0 or st.channels.items.len == 0) return;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The workspace list
    {
        var teams = a.alloc(FTeam, st.teams.items.len) catch return;
        for (st.teams.items, 0..) |t, i| teams[i] = .{ .id = t.id, .name = t.name, .url = t.url };
        const doc: FTeams = .{ .version = version, .active = st.active_team, .teams = teams };
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        std.json.Stringify.value(doc, .{}, &aw.writer) catch return;
        write(gpa, io, dir, "teams.json", aw.written());
        for (st.teams.items) |t| if (t.icon.len > 0) {
            const name = std.fmt.allocPrint(a, "icon-{s}.png", .{t.id}) catch continue;
            write(gpa, io, dir, name, t.icon);
        };
    }

    // The shown workspace
    var users: std.ArrayList(root.User) = .empty;
    var it = st.users.valueIterator();
    while (it.next()) |u| users.append(a, .{ .id = u.id, .name = u.name }) catch return;
    var channels = a.alloc(FChannel, st.channels.items.len) catch return;
    for (st.channels.items, 0..) |c, i| {
        const from = c.messages.items.len -| keep_messages;
        const src = c.messages.items[from..];
        const msgs = a.alloc(FMessage, src.len) catch return;
        for (src, 0..) |m, j| {
            const reactions = a.alloc(FReaction, m.reactions.items.len) catch return;
            for (m.reactions.items, 0..) |r, k| reactions[k] = .{ .name = r.name, .count = r.count, .mine = r.mine };
            msgs[j] = .{ .ts = m.ts, .user = m.user, .text = m.text, .thread_ts = m.thread_ts, .subtype = m.subtype, .reply_count = m.reply_count, .reactions = reactions };
        }
        channels[i] = .{
            .id = c.id,
            .name = c.name,
            .kind = c.kind,
            .user_id = c.user_id,
            .dormant = c.dormant,
            .listed = c.listed,
            .activity = if (c.activity.len > 0) c.activity else c.latest,
            .messages = msgs,
        };
    }
    const doc: FTeamFile = .{
        .version = version,
        .self_id = st.self_id,
        .team_name = st.team_name,
        .sidebar_mode = st.sidebar_mode,
        .last_selected = st.last_selected,
        .users = users.items,
        .channels = channels,
    };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    std.json.Stringify.value(doc, .{}, &aw.writer) catch return;
    const name = std.fmt.allocPrint(a, "{s}.json", .{st.active_team}) catch return;
    write(gpa, io, dir, name, aw.written());
}

/// Fills an empty store with what was saved: the workspace list and the one
/// last shown (`want` picks another when it is among them). False when
/// nothing usable was found.
pub fn loadStartup(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, st: *Store, want: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const data = read(a, io, dir, "teams.json") orelse return false;
    const doc = std.json.parseFromSliceLeaky(FTeams, a, data, .{ .ignore_unknown_fields = true }) catch return false;
    if (doc.version != version or doc.teams.len == 0) return false;
    var active = doc.active;
    for (doc.teams) |t| if (std.mem.eql(u8, t.id, want)) {
        active = want;
    };
    const infos = a.alloc(root.TeamInfo, doc.teams.len) catch return false;
    for (doc.teams, 0..) |t, i| infos[i] = .{ .id = t.id, .name = t.name, .url = t.url };
    st.apply(.{ .teams = .{ .list = infos, .active = active } }) catch return false;
    for (doc.teams) |t| {
        const icon_name = std.fmt.allocPrint(a, "icon-{s}.png", .{t.id}) catch continue;
        if (read(a, io, dir, icon_name)) |bytes| st.apply(.{ .team_icon = .{ .team = t.id, .bytes = bytes } }) catch {};
    }
    if (!loadTeam(a, io, dir, st, active)) return false;
    st.from_cache = true;
    return true;
}

/// Fills the shown (empty) workspace from its saved file
pub fn loadTeam(a: std.mem.Allocator, io: std.Io, dir: []const u8, st: *Store, team: []const u8) bool {
    const name = std.fmt.allocPrint(a, "{s}.json", .{team}) catch return false;
    const data = read(a, io, dir, name) orelse return false;
    const doc = std.json.parseFromSliceLeaky(FTeamFile, a, data, .{ .ignore_unknown_fields = true }) catch return false;
    if (doc.version != version) return false;
    applyTeam(a, st, doc) catch return false;
    return true;
}

fn applyTeam(a: std.mem.Allocator, st: *Store, doc: FTeamFile) !void {
    try st.apply(.{ .self = .{ .user_id = doc.self_id, .team_name = doc.team_name } });
    try st.apply(.{ .sidebar_mode = doc.sidebar_mode });
    try st.apply(.{ .users = doc.users });
    const infos = try a.alloc(root.ChannelInfo, doc.channels.len);
    for (doc.channels, 0..) |c, i| infos[i] = .{ .id = c.id, .name = c.name, .kind = c.kind, .user_id = c.user_id, .dormant = c.dormant };
    try st.apply(.{ .channels = infos });
    // Which conversations Slack keeps open, and their newest activity
    var counts: std.ArrayList(root.UnreadInfo) = .empty;
    for (doc.channels) |c| if (c.listed or c.kind == .channel or c.kind == .private) {
        try counts.append(a, .{ .id = c.id, .has_unreads = false, .latest = c.activity });
    };
    try st.apply(.{ .unreads = counts.items });
    for (doc.channels) |c| {
        if (c.messages.len == 0) continue;
        const msgs = try a.alloc(root.MessageInfo, c.messages.len);
        for (c.messages, 0..) |m, j| {
            const reactions = try a.alloc(root.ReactionInfo, m.reactions.len);
            for (m.reactions, 0..) |r, k| reactions[k] = .{ .name = r.name, .count = r.count, .mine = r.mine };
            msgs[j] = .{ .ts = m.ts, .user = m.user, .text = m.text, .thread_ts = m.thread_ts, .subtype = m.subtype, .reactions = reactions, .reply_count = m.reply_count };
        }
        try st.apply(.{ .history = .{ .channel = c.id, .messages = msgs } });
        // Not the server's word: opening it still fetches
        if (st.channel(c.id)) |ch| ch.history_loaded = false;
    }
    if (doc.last_selected.len > 0) st.rememberSelected(doc.last_selected);
    for (st.channels.items) |*c| c.stale = true;
}

test "the last known state survives a restart, and the server's list corrects it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const dir = try std.fmt.allocPrint(arena_state.allocator(), ".zig-cache/tmp/{s}/cache", .{tmp.sub_path});

    {
        var s = Store.init(gpa);
        defer s.deinit();
        try s.apply(.{ .teams = .{ .list = &.{.{ .id = "T1", .name = "A", .url = "https://a.slack.com" }}, .active = "T1" } });
        try s.apply(.{ .self = .{ .user_id = "U1", .team_name = "A" } });
        try s.apply(.{ .users = &.{ .{ .id = "U1", .name = "Me" }, .{ .id = "U2", .name = "Grace" } } });
        try s.apply(.{ .channels = &.{
            .{ .id = "C1", .name = "general", .kind = .channel },
            .{ .id = "C2", .name = "gone", .kind = .channel },
            .{ .id = "D1", .name = "", .kind = .im, .user_id = "U2", .dormant = true },
        } });
        try s.apply(.{ .unreads = &.{.{ .id = "C1", .has_unreads = false, .latest = "1700000100.000100" }} });
        try s.apply(.{ .history = .{ .channel = "C1", .messages = &.{
            .{ .ts = "1700000001.000100", .user = "U2", .text = "hello *world*", .reactions = &.{.{ .name = "+1", .count = 2, .mine = true }} },
            .{ .ts = "1700000100.000100", .user = "U1", .text = "second", .reply_count = 3 },
        } } });
        s.rememberSelected("C1");
        save(gpa, io, dir, &s);
    }

    var s = Store.init(gpa);
    defer s.deinit();
    try std.testing.expect(loadStartup(gpa, io, dir, &s, ""));
    try std.testing.expectEqualStrings("T1", s.active_team);
    try std.testing.expectEqualStrings("Me", s.userName("U1").?);
    try std.testing.expectEqual(@as(usize, 3), s.channels.items.len);
    try std.testing.expect(s.channel("D1").?.dormant);
    const c1 = s.channel("C1").?;
    try std.testing.expectEqual(@as(usize, 2), c1.messages.items.len);
    try std.testing.expectEqualStrings("hello *world*", c1.messages.items[0].text);
    try std.testing.expect(c1.messages.items[0].reactions.items[0].mine);
    try std.testing.expectEqual(@as(u32, 3), c1.messages.items[1].reply_count);
    // Opening a conversation still asks the server
    try std.testing.expect(!c1.history_loaded);
    try std.testing.expectEqualStrings("C1", s.last_selected);
    try std.testing.expect(s.from_cache);

    // The server's first answers: the workspace list, then every conversation
    try s.apply(.{ .teams = .{ .list = &.{.{ .id = "T1", .name = "A", .url = "https://a.slack.com" }}, .active = "T1" } });
    try std.testing.expect(!s.from_cache);
    try s.apply(.{ .channels = &.{
        .{ .id = "C1", .name = "general", .kind = .channel },
        .{ .id = "D1", .name = "", .kind = .im, .user_id = "U2" },
    } });
    try std.testing.expect(s.channel("C2") == null);
    try std.testing.expect(!s.channel("D1").?.dormant);
}

test "a cache for another workspace than the shown one is dropped" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const dir = try std.fmt.allocPrint(arena_state.allocator(), ".zig-cache/tmp/{s}/cache", .{tmp.sub_path});
    {
        var s = Store.init(gpa);
        defer s.deinit();
        try s.apply(.{ .teams = .{ .list = &.{ .{ .id = "T1", .name = "A", .url = "u" }, .{ .id = "T2", .name = "B", .url = "u" } }, .active = "T1" } });
        try s.apply(.{ .self = .{ .user_id = "U1", .team_name = "A" } });
        try s.apply(.{ .channels = &.{.{ .id = "C1", .name = "general", .kind = .channel }} });
        save(gpa, io, dir, &s);
    }
    var s = Store.init(gpa);
    defer s.deinit();
    try std.testing.expect(loadStartup(gpa, io, dir, &s, ""));
    try std.testing.expectEqual(@as(usize, 1), s.channels.items.len);
    // Slack opens T2 instead
    try s.apply(.{ .teams = .{ .list = &.{ .{ .id = "T1", .name = "A", .url = "u" }, .{ .id = "T2", .name = "B", .url = "u" } }, .active = "T2" } });
    try std.testing.expectEqualStrings("T2", s.active_team);
    try std.testing.expectEqual(@as(usize, 0), s.channels.items.len);
}
