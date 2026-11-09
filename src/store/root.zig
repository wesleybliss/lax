//! In-memory cache the UI reads from. Owned and mutated by the UI thread
//! only: the network thread sends `Update`s through a `Queue`, and the UI
//! thread applies them. Memory is bounded per channel.
const std = @import("std");

pub const Queue = @import("queue.zig").Queue;
pub const Wake = @import("wake.zig").Wake;
pub const cache = @import("cache.zig");

test {
    _ = @import("queue.zig");
    _ = @import("wake.zig");
    _ = @import("cache.zig");
}

pub const Kind = enum { channel, private, im, mpim };

/// A `fetch_image` id with this prefix asks for a user's profile picture (the rest is the user id)
pub const avatar_prefix = "avatar:";
/// A `fetch_image` id with this prefix asks for a file's full-size picture (the rest is the file id)
pub const full_prefix = "full:";

pub const User = struct {
    id: []const u8,
    name: []const u8,
    /// An app or bot: its DM goes under Apps
    is_bot: bool = false,
    /// URL of the profile picture (empty: none)
    image: []const u8 = "",
};

/// Where Slack's channel sections put a conversation in the sidebar
pub const SectionPlace = enum {
    /// No section: it is listed by kind (Channels, Direct messages, Apps)
    none,
    /// The Starred section
    starred,
    /// A custom section above the Direct messages list
    above,
    /// A custom section below it
    below,
};

/// The pages behind the sidebar's top rows that list messages
pub const FeedKind = enum { threads, drafts, saved };

/// One line of such a page, as the network side reports it
pub const FeedEntryInfo = struct {
    channel: []const u8,
    ts: []const u8,
    /// The thread it belongs to (empty when none)
    thread_ts: []const u8 = "",
    user: []const u8 = "",
    text: []const u8 = "",
    /// A short tag: "3 replies", "Draft", "Scheduled", "Sent"
    note: []const u8 = "",
    /// The newest reply, for a thread
    reply_user: []const u8 = "",
    reply_text: []const u8 = "",
    unread: bool = false,
};

pub const FeedEntry = struct {
    channel: []u8,
    ts: []u8,
    thread_ts: []u8,
    user: []u8,
    text: []u8,
    note: []u8,
    reply_user: []u8,
    reply_text: []u8,
    unread: bool,
};

pub const Feed = struct {
    entries: std.ArrayList(FeedEntry) = .empty,
    /// Slack has answered at least once
    loaded: bool = false,
};

/// What the network side knows about a conversation
pub const ChannelInfo = struct {
    id: []const u8,
    name: []const u8,
    kind: Kind,
    /// The other person, for a 1:1 DM
    user_id: ?[]const u8 = null,
    /// Slack marks it dormant: no recent activity (`properties.is_dormant`)
    dormant: bool = false,
    /// The channel section holding it (a custom one's name), by `place`
    section: []const u8 = "",
    place: SectionPlace = .none,
    /// Position among the custom sections
    section_rank: u16 = 0,
};

/// Slack's `sidebar_behavior` preference: which conversations the sidebar lists
pub const SidebarMode = enum {
    /// Everything the client keeps open
    all,
    /// Skip dormant ones ("Most recent")
    active,
    /// Only those with unread messages
    unread,
    /// Only those that mention you
    mentions,

    /// Parses the pref value, `active` for an unknown one
    pub fn parse(value: []const u8) SidebarMode {
        if (value.len == 0) return .all;
        if (std.mem.eql(u8, value, "hide_inactive_channels")) return .active;
        if (std.mem.eql(u8, value, "show_mentions_only")) return .mentions;
        if (std.mem.eql(u8, value, "hide_read_channels") or std.mem.eql(u8, value, "hide_read_channels_unless_starred")) return .unread;
        return .active;
    }
};

/// Slack's desktop notification level for a conversation
pub const NotifyMode = enum {
    everything,
    /// @you, @channel and @here, keywords; always for a DM
    mentions,
    nothing,

    /// Parses a pref value ("everything", "mentions_dms", "nothing"), `mentions` for an unknown one
    pub fn parse(value: []const u8) NotifyMode {
        if (std.mem.eql(u8, value, "everything")) return .everything;
        if (std.mem.eql(u8, value, "nothing")) return .nothing;
        return .mentions;
    }
};

/// One conversation's own notification settings (they win over the global ones)
pub const ChannelNotify = struct {
    desktop: ?NotifyMode = null,
    muted: bool = false,
    /// Unix seconds a temporary mute ends (0: until unmuted)
    muted_until: i64 = 0,
    /// Ignore @channel and @here
    quiet_broadcast: bool = false,
};

pub const ChannelNotifyInfo = struct {
    id: []const u8,
    settings: ChannelNotify,
};

/// The `all_notifications_prefs` Slack setting
pub const NotifyInfo = struct {
    /// Channels
    desktop: NotifyMode = .mentions,
    /// Group DMs
    group: NotifyMode = .everything,
    /// Comma separated words that always notify (unless `nothing`)
    keywords: []const u8 = "",
    /// Notifications say "New message" instead of the text
    hide_text: bool = false,
    channels: []const ChannelNotifyInfo = &.{},
};

const NotifyPrefs = struct {
    desktop: NotifyMode = .mentions,
    group: NotifyMode = .everything,
    keywords: []u8 = &.{},
    hide_text: bool = false,
    channels: std.StringHashMapUnmanaged(ChannelNotify) = .empty,
};

/// A message that should raise a desktop notification
pub const Notice = struct {
    /// The workspace's name
    team: []u8,
    channel: []u8,
    /// A channel's `#name`, a person's name
    title: []u8,
    /// The author's id (may be empty)
    user: []u8,
    /// Slack mrkdwn
    text: []u8,
    thread_ts: []u8,
    hide_text: bool,
};

/// Notices waiting for the UI; the oldest are dropped past this
pub const max_notices = 50;

pub const ReactionInfo = struct {
    /// Emoji name, with a `::skin-tone-N` suffix if any
    name: []const u8,
    count: u32,
    /// We reacted with it
    mine: bool = false,
};

/// A file attached to a message
pub const FileInfo = struct {
    id: []const u8,
    name: []const u8,
    mimetype: []const u8 = "",
    /// Opens it in the browser
    link: []const u8 = "",
    /// The file's bytes (private to the workspace): for the full-size picture and downloads
    url: []const u8 = "",
    /// An image's preview picture (empty: none yet, or not an image) and its size
    thumb: []const u8 = "",
    thumb_w: u32 = 0,
    thumb_h: u32 = 0,
};

pub const MessageInfo = struct {
    ts: []const u8,
    user: ?[]const u8,
    /// What a bot author calls itself: names `user` when that is a `bot_id`
    bot_name: ?[]const u8 = null,
    /// Slack mrkdwn, entities still escaped
    text: []const u8,
    thread_ts: ?[]const u8 = null,
    subtype: ?[]const u8 = null,
    reactions: []const ReactionInfo = &.{},
    /// Replies, for a thread parent
    reply_count: u32 = 0,
    files: []const FileInfo = &.{},
};

pub const Connection = enum { connecting, online, offline };

pub const TeamInfo = struct {
    id: []const u8,
    name: []const u8,
    url: []const u8,
};

/// Initial read state for a conversation (from `client.counts`)
pub const UnreadInfo = struct {
    id: []const u8,
    has_unreads: bool,
    mentions: u32 = 0,
    /// Newest activity, for ordering
    latest: []const u8 = "",
};

/// Where an app update is, from the updater thread's point of view
pub const UpdatePhase = enum {
    /// A newer release exists; clicking installs it
    available,
    downloading,
    /// The package manager is running (it asks for the password)
    installing,
    /// Something went wrong (`message`); clicking tries again
    failed,
    /// Installed: the app should restart into it
    restart,
};

/// How a check the user asked for ended
pub const UpdateCheck = enum {
    /// A newer release exists (see `app_update`)
    found,
    current,
    failed,
    /// This install does not update itself
    unsupported,
};

pub const AppUpdate = struct {
    phase: UpdatePhase,
    version: []const u8,
    message: []const u8 = "",
};

pub const Update = union(enum) {
    self: struct { user_id: []const u8, team_name: []const u8 },
    channels: []const ChannelInfo,
    users: []const User,
    /// Messages for one channel in any order (initial load or gap fill).
    /// `older` pages all precede what we hold and are prepended.
    history: struct { channel: []const u8, messages: []const MessageInfo, has_more: bool = false, older: bool = false },
    /// A thread's parent and replies, oldest first
    thread_history: struct { channel: []const u8, thread_ts: []const u8, messages: []const MessageInfo },
    /// A reply that arrived live
    thread_message: struct { channel: []const u8, thread_ts: []const u8, message: MessageInfo },
    reply_count: struct { channel: []const u8, ts: []const u8, count: u32 },
    reaction: struct { channel: []const u8, ts: []const u8, name: []const u8, user: []const u8, added: bool },
    /// `at_ms` is the network thread's monotonic clock, comparable with the UI's
    typing: struct { channel: []const u8, user: []const u8, at_ms: i64 },
    presence: struct { users: []const []const u8, active: bool },
    /// A new message (live event or our own send)
    message: struct { channel: []const u8, message: MessageInfo },
    /// `files`: what the edit says is attached (a file's preview arrives this way); empty keeps what is shown
    edited: struct { channel: []const u8, ts: []const u8, text: []const u8, files: []const FileInfo = &.{} },
    /// A file's preview picture, encoded (PNG, JPEG, ...)
    file_image: struct { id: []const u8, bytes: []const u8 },
    /// A user's profile picture, encoded
    avatar: struct { user: []const u8, bytes: []const u8 },
    deleted: struct { channel: []const u8, ts: []const u8 },
    /// Read up to `ts` on another client (or this one); counts when Slack says
    marked: struct { channel: []const u8, ts: []const u8, unread: ?u32 = null, mentions: ?u32 = null },
    unreads: []const UnreadInfo,
    sidebar_mode: SidebarMode,
    notify: NotifyInfo,
    /// A top-row page's contents, newest first
    feed: struct { kind: FeedKind, entries: []const FeedEntryInfo },
    /// The workspaces to switch between, and which one is shown
    teams: struct { list: []const TeamInfo, active: []const u8 },
    /// A workspace's icon (an encoded PNG)
    team_icon: struct { team: []const u8, bytes: []const u8 },
    /// No usable session: ask the user for a token and cookie (the reason)
    need_manual: []const u8,
    manual_done,
    connection: Connection,
    /// A human-readable problem for the status line
    status: []const u8,
    /// The app itself: a newer release, and how installing it is going
    app_update: AppUpdate,
    update_check: UpdateCheck,
    /// Something for the user to read briefly ("Saved to ~/Downloads/a.png")
    toast: []const u8,
};

/// An update with the memory its slices point into
pub const Item = struct {
    arena: std.heap.ArenaAllocator,
    update: Update,
    /// The workspace the update belongs to (empty: whichever is shown)
    team_buf: [32]u8 = undefined,
    team_len: u8 = 0,

    pub fn setTeam(i: *Item, id: []const u8) void {
        const n = @min(id.len, i.team_buf.len);
        @memcpy(i.team_buf[0..n], id[0..n]);
        i.team_len = @intCast(n);
    }

    pub fn team(i: *const Item) []const u8 {
        return i.team_buf[0..i.team_len];
    }

    pub fn deinit(i: *Item) void {
        i.arena.deinit();
    }
};

pub const Reaction = struct {
    name: []u8,
    count: u32,
    mine: bool,
};

pub const Message = struct {
    ts: []u8,
    user: ?[]u8,
    text: []u8,
    thread_ts: ?[]u8,
    subtype: ?[]u8,
    reactions: std.ArrayList(Reaction) = .empty,
    reply_count: u32 = 0,
    files: []FileInfo = &.{},
};

pub const Typing = struct { user: []u8, at_ms: i64 };

/// The thread open in the side panel
pub const Thread = struct {
    channel: []u8,
    ts: []u8,
    messages: std.ArrayList(Message) = .empty,
    loaded: bool = false,
};

/// A typing indicator lasts this long without a new event
pub const typing_ms = 5000;

/// Milliseconds on a monotonic clock shared by every thread
pub fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .awake).toNanoseconds(), 1_000_000));
}

pub const Channel = struct {
    id: []u8,
    name: []u8,
    kind: Kind,
    user_id: ?[]u8,
    messages: std.ArrayList(Message) = .empty,
    /// Bumped when messages change anywhere but the end, so views can
    /// drop cached layout
    rev: u32 = 0,
    unread: bool = false,
    mentions: u32 = 0,
    /// Newest message ts we hold
    latest: []u8,
    /// Newest activity Slack reported, for ordering the sidebar
    activity: []u8,
    /// Older messages exist on the server
    has_older: bool = false,
    /// Messages prepended since the view last looked (it shifts its layout)
    prepended: usize = 0,
    typing: std.ArrayList(Typing) = .empty,
    history_loaded: bool = false,
    /// A DM or group DM Slack's client keeps open (it is in `client.counts`).
    /// Others stay out of the sidebar unless they get a message.
    listed: bool = true,
    dormant: bool = false,
    /// The channel section holding it (a custom one's name), by `place`
    section: []u8 = &.{},
    place: SectionPlace = .none,
    section_rank: u16 = 0,
    /// Loaded from the disk cache and not yet confirmed by Slack
    stale: bool = false,
};

pub const max_messages_per_channel = 1000;

const StoredUser = struct { id: []u8, name: []u8, online: bool = false, is_bot: bool = false, image: []u8 = &.{}, avatar: []u8 = &.{} };

pub const Team = struct { id: []u8, name: []u8, url: []u8, icon: []u8 = &.{} };

/// Everything cached for one workspace: the store shows one and keeps the
/// others parked, so switching back is instant
const Space = struct {
    self_id: []u8,
    team_name: []u8,
    users: std.StringHashMapUnmanaged(StoredUser),
    channels: std.ArrayList(Channel),
    thread: ?Thread,
    connection: Connection,
    status: []u8,
    last_selected: []u8,
    sidebar_mode: SidebarMode,
    notify: NotifyPrefs,
    feeds: [feed_kinds]Feed,

    const empty: Space = .{ .self_id = &.{}, .team_name = &.{}, .users = .empty, .channels = .empty, .thread = null, .connection = .connecting, .status = &.{}, .last_selected = &.{}, .sidebar_mode = .active, .notify = .{}, .feeds = @splat(.{}) };
};

const feed_kinds = std.enums.values(FeedKind).len;

pub const Store = struct {
    gpa: std.mem.Allocator,
    self_id: []u8,
    team_name: []u8,
    users: std.StringHashMapUnmanaged(StoredUser) = .empty,
    channels: std.ArrayList(Channel) = .empty,
    connection: Connection = .connecting,
    status: []u8,
    teams: std.ArrayList(Team) = .empty,
    active_team: []u8,
    /// Bumped by `reset`: views holding conversation ids must start over
    epoch: u32 = 0,
    /// Set while the session is unusable and the user must paste credentials
    need_manual: ?[]u8 = null,
    thread: ?Thread = null,
    /// The conversation open last in this workspace, to return to
    last_selected: []u8 = &.{},
    sidebar_mode: SidebarMode = .active,
    notify: NotifyPrefs = .{},
    /// Messages the UI should announce; it takes them after each batch of updates
    notices: std.ArrayList(Notice) = .empty,
    feeds: [feed_kinds]Feed = @splat(.{}),
    /// Filled from the disk cache; the first workspace list confirms or replaces it
    from_cache: bool = false,
    /// A newer release of the app (not tied to a workspace); its strings are owned
    app_update: ?AppUpdate = null,
    /// The answer to the user's "Check for updates", until the UI shows it
    update_check: ?UpdateCheck = null,
    /// A message from the network side, until the UI shows it (owned)
    toast: ?[]u8 = null,
    /// Other workspaces' data, by team id
    parked: std.StringHashMapUnmanaged(Space) = .empty,
    /// Files' preview pictures by file id (ids are unique across workspaces)
    images: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa, .self_id = &.{}, .team_name = &.{}, .status = &.{}, .active_team = &.{} };
    }

    fn clearAppUpdate(s: *Store) void {
        const u = s.app_update orelse return;
        s.gpa.free(u.version);
        s.gpa.free(u.message);
        s.app_update = null;
    }

    pub fn deinit(s: *Store) void {
        s.clearAppUpdate();
        s.gpa.free(s.active_team);
        if (s.need_manual) |m| s.gpa.free(m);
        if (s.toast) |t| s.gpa.free(t);
        s.clearTeams();
        s.teams.deinit(s.gpa);
        var shown = s.takeSpace();
        s.freeSpace(&shown);
        var it = s.parked.iterator();
        while (it.next()) |kv| {
            s.freeSpace(kv.value_ptr);
            s.gpa.free(kv.key_ptr.*);
        }
        s.parked.deinit(s.gpa);
        s.clearImages();
        s.clearNotices();
        s.notices.deinit(s.gpa);
    }

    fn clearTeams(s: *Store) void {
        for (s.teams.items) |t| {
            s.gpa.free(t.id);
            s.gpa.free(t.name);
            s.gpa.free(t.url);
            s.gpa.free(t.icon);
        }
        s.teams.clearRetainingCapacity();
    }

    // The shown workspace's data moves in and out of `Space`s

    fn takeSpace(s: *Store) Space {
        const sp: Space = .{ .self_id = s.self_id, .team_name = s.team_name, .users = s.users, .channels = s.channels, .thread = s.thread, .connection = s.connection, .status = s.status, .last_selected = s.last_selected, .sidebar_mode = s.sidebar_mode, .notify = s.notify, .feeds = s.feeds };
        s.putSpace(.empty);
        return sp;
    }

    fn putSpace(s: *Store, sp: Space) void {
        s.self_id = sp.self_id;
        s.team_name = sp.team_name;
        s.users = sp.users;
        s.channels = sp.channels;
        s.thread = sp.thread;
        s.connection = sp.connection;
        s.status = sp.status;
        s.last_selected = sp.last_selected;
        s.sidebar_mode = sp.sidebar_mode;
        s.notify = sp.notify;
        s.feeds = sp.feeds;
    }

    fn swapSpace(s: *Store, other: *Space) void {
        const mine = s.takeSpace();
        s.putSpace(other.*);
        other.* = mine;
    }

    fn freeSpace(s: *Store, sp: *Space) void {
        s.gpa.free(sp.self_id);
        s.gpa.free(sp.team_name);
        s.gpa.free(sp.status);
        s.gpa.free(sp.last_selected);
        var it = sp.users.valueIterator();
        while (it.next()) |u| {
            s.gpa.free(u.id);
            s.gpa.free(u.name);
            s.gpa.free(u.image);
            s.gpa.free(u.avatar);
        }
        sp.users.deinit(s.gpa);
        for (sp.channels.items) |*c| s.freeChannel(c);
        sp.channels.deinit(s.gpa);
        if (sp.thread) |*t| s.freeThread(t);
        for (&sp.feeds) |*f| s.clearFeed(f);
        for (&sp.feeds) |*f| f.entries.deinit(s.gpa);
        s.freeNotify(&sp.notify);
    }

    fn clearFeed(s: *Store, f: *Feed) void {
        for (f.entries.items) |e| {
            inline for (.{ e.channel, e.ts, e.thread_ts, e.user, e.text, e.note, e.reply_user, e.reply_text }) |str| s.gpa.free(str);
        }
        f.entries.clearRetainingCapacity();
    }

    pub fn feed(s: *const Store, kind: FeedKind) *const Feed {
        return &s.feeds[@intFromEnum(kind)];
    }

    fn setFeed(s: *Store, kind: FeedKind, infos: []const FeedEntryInfo) std.mem.Allocator.Error!void {
        const f = &s.feeds[@intFromEnum(kind)];
        s.clearFeed(f);
        errdefer s.clearFeed(f);
        try f.entries.ensureTotalCapacity(s.gpa, infos.len);
        for (infos) |i| {
            var e: FeedEntry = undefined;
            var done: usize = 0;
            errdefer inline for (.{ "channel", "ts", "thread_ts", "user", "text", "note", "reply_user", "reply_text" }, 0..) |name, k| {
                if (k < done) s.gpa.free(@field(e, name));
            };
            inline for (.{ "channel", "ts", "thread_ts", "user", "text", "note", "reply_user", "reply_text" }) |name| {
                @field(e, name) = try s.gpa.dupe(u8, @field(i, name));
                done += 1;
            }
            e.unread = i.unread;
            f.entries.appendAssumeCapacity(e);
        }
        f.loaded = true;
    }

    /// Shows another workspace: the current one is parked with everything it
    /// holds, the other comes back as it was (or empty, to be loaded)
    pub fn setActive(s: *Store, team: []const u8) std.mem.Allocator.Error!void {
        if (std.mem.eql(u8, s.active_team, team)) return;
        const new_id = try s.gpa.dupe(u8, team);
        errdefer s.gpa.free(new_id);
        const old_key = try s.gpa.dupe(u8, s.active_team);
        errdefer s.gpa.free(old_key);
        try s.parked.ensureUnusedCapacity(s.gpa, 1);

        var old = s.takeSpace();
        if (s.active_team.len > 0) {
            s.parked.putAssumeCapacity(old_key, old);
        } else {
            s.freeSpace(&old);
            s.gpa.free(old_key);
        }
        if (s.parked.fetchRemove(team)) |kv| {
            s.putSpace(kv.value);
            s.gpa.free(kv.key);
        }
        // What was shown last may be out of date: the connection starts over
        s.connection = .connecting;
        s.gpa.free(s.active_team);
        s.active_team = new_id;
        s.epoch +%= 1;
    }

    /// Applies an update the network side tagged with its workspace
    pub fn applyItem(s: *Store, item: *const Item) std.mem.Allocator.Error!void {
        switch (item.update) {
            .teams, .need_manual, .manual_done, .app_update, .update_check, .toast => return s.apply(item.update),
            else => {},
        }
        const tag = item.team();
        if (tag.len == 0 or std.mem.eql(u8, tag, s.active_team)) return s.apply(item.update);
        if (s.parked.getPtr(tag)) |sp| {
            s.swapSpace(sp);
            defer s.swapSpace(sp);
            return s.apply(item.update);
        }
    }

    /// Whether the sidebar lists a conversation, following the user's Slack
    /// preference (the selected one is always listed by the view)
    pub fn shownInSidebar(s: *const Store, c: *const Channel) bool {
        if (c.unread or c.mentions > 0) return s.sidebar_mode != .mentions or c.mentions > 0;
        if (!c.listed) return false;
        return switch (s.sidebar_mode) {
            .all => true,
            .active => !c.dormant,
            .unread, .mentions => false,
        };
    }

    pub fn rememberSelected(s: *Store, id: []const u8) void {
        s.replace(&s.last_selected, id) catch {};
    }

    fn freeMessage(s: *Store, m: *Message) void {
        for (m.reactions.items) |r| s.gpa.free(r.name);
        m.reactions.deinit(s.gpa);
        s.gpa.free(m.ts);
        if (m.user) |u| s.gpa.free(u);
        s.gpa.free(m.text);
        if (m.thread_ts) |t| s.gpa.free(t);
        if (m.subtype) |t| s.gpa.free(t);
        s.freeFiles(m.files);
    }

    fn freeFiles(s: *Store, files: []FileInfo) void {
        for (files) |f| for ([_][]const u8{ f.id, f.name, f.mimetype, f.link, f.url, f.thumb }) |str| if (str.len > 0) s.gpa.free(str);
        s.gpa.free(files);
    }

    /// Copies of `infos` the store owns (empty strings stay unallocated)
    fn dupeFiles(s: *Store, infos: []const FileInfo) std.mem.Allocator.Error![]FileInfo {
        if (infos.len == 0) return &.{};
        const out = try s.gpa.alloc(FileInfo, infos.len);
        var made: usize = 0;
        errdefer s.freeFiles(out[0..made]);
        for (infos) |f| {
            out[made] = .{ .id = "", .name = "", .thumb_w = f.thumb_w, .thumb_h = f.thumb_h };
            made += 1;
            const dst = &out[made - 1];
            inline for (.{ "id", "name", "mimetype", "link", "url", "thumb" }) |field| {
                const src = @field(f, field);
                if (src.len > 0) @field(dst, field) = try s.gpa.dupe(u8, src);
            }
        }
        return out;
    }

    /// Files `info` has and the held copy of the message lacks; whether it took them
    fn adoptFiles(s: *Store, m: *Message, info: MessageInfo) std.mem.Allocator.Error!bool {
        if (m.files.len > 0 or info.files.len == 0) return false;
        m.files = try s.dupeFiles(info.files);
        return true;
    }

    /// Forgets every preview picture (the conversation changed)
    pub fn clearImages(s: *Store) void {
        var it = s.images.iterator();
        while (it.next()) |kv| {
            s.gpa.free(kv.key_ptr.*);
            s.gpa.free(kv.value_ptr.*);
        }
        s.images.clearAndFree(s.gpa);
    }

    /// A file's preview picture, if it has arrived
    pub fn fileImage(s: *const Store, id: []const u8) ?[]const u8 {
        return s.images.get(id);
    }

    fn freeChannel(s: *Store, c: *Channel) void {
        for (c.messages.items) |*m| s.freeMessage(m);
        c.messages.deinit(s.gpa);
        for (c.typing.items) |t| s.gpa.free(t.user);
        c.typing.deinit(s.gpa);
        s.gpa.free(c.id);
        s.gpa.free(c.name);
        if (c.user_id) |u| s.gpa.free(u);
        s.gpa.free(c.latest);
        s.gpa.free(c.activity);
        s.gpa.free(c.section);
    }

    fn replace(s: *Store, slot: *[]u8, value: []const u8) std.mem.Allocator.Error!void {
        const copy = try s.gpa.dupe(u8, value);
        s.gpa.free(slot.*);
        slot.* = copy;
    }

    pub fn channel(s: *Store, id: []const u8) ?*Channel {
        for (s.channels.items) |*c| if (std.mem.eql(u8, c.id, id)) return c;
        return null;
    }

    pub fn userName(s: *const Store, id: []const u8) ?[]const u8 {
        return if (s.users.get(id)) |u| u.name else null;
    }

    /// Display name of a conversation: DMs use the other person's name
    pub fn channelName(s: *const Store, c: *const Channel) []const u8 {
        if (c.user_id) |uid| if (s.userName(uid)) |n| return n;
        return c.name;
    }

    /// Your own DM (Slack's "you" conversation)
    pub fn isSelfDm(s: *const Store, c: *const Channel) bool {
        if (c.kind != .im) return false;
        const uid = c.user_id orelse return false;
        return s.self_id.len > 0 and std.mem.eql(u8, uid, s.self_id);
    }

    /// A DM with an app or bot (listed under Apps)
    pub fn isApp(s: *const Store, c: *const Channel) bool {
        if (c.kind != .im) return false;
        const uid = c.user_id orelse return false;
        return if (s.users.get(uid)) |u| u.is_bot else false;
    }

    /// Where a user's profile picture is (empty: none)
    pub fn userImageUrl(s: *const Store, id: []const u8) []const u8 {
        return if (s.users.get(id)) |u| u.image else "";
    }

    /// A user's profile picture, if it has arrived
    pub fn userAvatar(s: *const Store, id: []const u8) ?[]const u8 {
        const u = s.users.get(id) orelse return null;
        return if (u.avatar.len > 0) u.avatar else null;
    }

    pub fn isOnline(s: *const Store, user_id: []const u8) bool {
        return if (s.users.get(user_id)) |u| u.online else false;
    }

    /// Users typing in `c` as of `now_ms`, written to `out` (names or ids);
    /// returns how many
    pub fn typingNow(s: *const Store, c: *const Channel, now_ms: i64, out: [][]const u8) usize {
        var n: usize = 0;
        for (c.typing.items) |t| {
            if (now_ms - t.at_ms > typing_ms or n >= out.len) continue;
            if (std.mem.eql(u8, t.user, s.self_id)) continue;
            out[n] = s.userName(t.user) orelse t.user;
            n += 1;
        }
        return n;
    }

    pub fn messages(s: *Store, channel_id: []const u8) []const Message {
        return if (s.channel(channel_id)) |c| c.messages.items else &.{};
    }

    pub fn apply(s: *Store, u: Update) std.mem.Allocator.Error!void {
        switch (u) {
            .self => |v| {
                try s.replace(&s.self_id, v.user_id);
                try s.replace(&s.team_name, v.team_name);
            },
            .channels => |list| {
                for (list) |info| try s.upsertChannel(info);
                // The list is complete: what came from the cache and is not in it is gone
                var i = s.channels.items.len;
                while (i > 0) {
                    i -= 1;
                    if (!s.channels.items[i].stale) continue;
                    var gone = s.channels.orderedRemove(i);
                    s.freeChannel(&gone);
                }
            },
            .users => |list| for (list) |user| try s.upsertUser(user),
            .history => |h| {
                const c = s.channel(h.channel) orelse return;
                if (h.older) {
                    try s.prependMessages(c, h.messages);
                } else {
                    for (h.messages) |m| try s.insertMessage(c, m, false);
                    c.history_loaded = true;
                    c.rev +%= 1;
                }
                c.has_older = h.has_more;
            },
            .thread_history => |h| {
                try s.openThread(h.channel, h.thread_ts);
                const t = &s.thread.?;
                if (!std.mem.eql(u8, t.channel, h.channel) or !std.mem.eql(u8, t.ts, h.thread_ts)) return;
                for (h.messages) |m| try s.insertInto(&t.messages, m, null);
                t.loaded = true;
            },
            .thread_message => |m| {
                // Replies to the parent in the channel list: keep its count honest
                if (s.thread) |*t| if (std.mem.eql(u8, t.channel, m.channel) and std.mem.eql(u8, t.ts, m.thread_ts)) {
                    try s.insertInto(&t.messages, m.message, null);
                };
                // A broadcast reply is announced as the channel message it also is
                const broadcast = if (m.message.subtype) |sub| std.mem.eql(u8, sub, "thread_broadcast") else false;
                if (!broadcast) if (s.channel(m.channel)) |c| try s.notice(c, m.message);
            },
            .reply_count => |r| {
                const c = s.channel(r.channel) orelse return;
                const i = findTs(c.messages.items, r.ts) orelse return;
                c.messages.items[i].reply_count = r.count;
                c.rev +%= 1;
            },
            .reaction => |r| {
                const c = s.channel(r.channel) orelse return;
                const i = findTs(c.messages.items, r.ts) orelse return;
                try s.applyReaction(&c.messages.items[i], r.name, r.user, r.added);
                c.rev +%= 1;
                if (s.thread) |*t| if (std.mem.eql(u8, t.channel, r.channel)) if (findTs(t.messages.items, r.ts)) |ti| {
                    try s.applyReaction(&t.messages.items[ti], r.name, r.user, r.added);
                };
            },
            .typing => |t| {
                const c = s.channel(t.channel) orelse return;
                for (c.typing.items) |*x| if (std.mem.eql(u8, x.user, t.user)) {
                    x.at_ms = t.at_ms;
                    return;
                };
                const user = try s.gpa.dupe(u8, t.user);
                errdefer s.gpa.free(user);
                try c.typing.append(s.gpa, .{ .user = user, .at_ms = t.at_ms });
            },
            .presence => |p| for (p.users) |id| {
                if (s.users.getPtr(id)) |user| user.online = p.active;
            },
            .message => |m| {
                const c = s.channel(m.channel) orelse return;
                try s.insertMessage(c, m.message, true);
            },
            .edited => |e| {
                const c = s.channel(e.channel) orelse return;
                const i = findTs(c.messages.items, e.ts) orelse return;
                try s.replace(&c.messages.items[i].text, e.text);
                if (e.files.len > 0) {
                    const files = try s.dupeFiles(e.files);
                    s.freeFiles(c.messages.items[i].files);
                    c.messages.items[i].files = files;
                }
                c.rev +%= 1;
            },
            .file_image => |f| {
                // Keyed by file id: the same file in two places is one picture
                const bytes = try s.gpa.dupe(u8, f.bytes);
                errdefer s.gpa.free(bytes);
                const gop = try s.images.getOrPut(s.gpa, f.id);
                if (gop.found_existing) {
                    s.gpa.free(gop.value_ptr.*);
                } else {
                    gop.key_ptr.* = s.gpa.dupe(u8, f.id) catch |e| {
                        _ = s.images.remove(f.id);
                        return e;
                    };
                }
                gop.value_ptr.* = bytes;
            },
            .avatar => |a| if (s.users.getPtr(a.user)) |user| try s.replace(&user.avatar, a.bytes),
            .deleted => |d| {
                const c = s.channel(d.channel) orelse return;
                const i = findTs(c.messages.items, d.ts) orelse return;
                var m = c.messages.orderedRemove(i);
                s.freeMessage(&m);
                c.rev +%= 1;
            },
            .marked => |m| {
                const c = s.channel(m.channel) orelse return;
                if (m.unread) |n| {
                    c.unread = n > 0;
                    c.mentions = m.mentions orelse 0;
                } else if (c.messages.items.len == 0 or !tsLess(m.ts, c.messages.items[c.messages.items.len - 1].ts)) {
                    // Read through the newest message we hold
                    c.unread = false;
                    c.mentions = 0;
                }
            },
            .unreads => |list| {
                // Slack lists the conversations it keeps open here: the other DMs are closed
                for (s.channels.items) |*c| if (c.kind == .im or c.kind == .mpim) {
                    c.listed = false;
                };
                for (list) |info| {
                    const c = s.channel(info.id) orelse continue;
                    c.listed = true;
                    c.unread = info.has_unreads;
                    c.mentions = info.mentions;
                    if (info.latest.len > 0) try s.replace(&c.activity, info.latest);
                }
            },
            .sidebar_mode => |m| s.sidebar_mode = m,
            .notify => |n| try s.setNotify(n),
            .feed => |f| try s.setFeed(f.kind, f.entries),
            .teams => |t| {
                var fresh: std.ArrayList(Team) = .empty;
                errdefer {
                    for (fresh.items) |x| {
                        s.gpa.free(x.id);
                        s.gpa.free(x.name);
                        s.gpa.free(x.url);
                    }
                    fresh.deinit(s.gpa);
                }
                for (t.list) |info| {
                    const id = try s.gpa.dupe(u8, info.id);
                    errdefer s.gpa.free(id);
                    const name = try s.gpa.dupe(u8, info.name);
                    errdefer s.gpa.free(name);
                    const url = try s.gpa.dupe(u8, info.url);
                    errdefer s.gpa.free(url);
                    try fresh.append(s.gpa, .{ .id = id, .name = name, .url = url });
                }
                // Icons already fetched move over to the new entries
                for (fresh.items) |*x| for (s.teams.items) |*old| if (std.mem.eql(u8, old.id, x.id)) {
                    x.icon = old.icon;
                    old.icon = &.{};
                };
                s.clearTeams();
                s.teams.deinit(s.gpa);
                s.teams = fresh;
                // The first list picks the shown workspace; after that the UI does
                if (s.active_team.len == 0) try s.replace(&s.active_team, t.active) else if (s.from_cache) {
                    // Opened with the disk cache: if Slack shows another workspace, start over
                    if (!std.mem.eql(u8, s.active_team, t.active)) {
                        var old = s.takeSpace();
                        s.freeSpace(&old);
                        try s.replace(&s.active_team, t.active);
                        s.epoch +%= 1;
                    }
                }
                s.from_cache = false;
            },
            .team_icon => |ic| for (s.teams.items) |*x| if (std.mem.eql(u8, x.id, ic.team)) {
                const copy = try s.gpa.dupe(u8, ic.bytes);
                s.gpa.free(x.icon);
                x.icon = copy;
            },
            .need_manual => |reason| {
                const copy = try s.gpa.dupe(u8, reason);
                if (s.need_manual) |old| s.gpa.free(old);
                s.need_manual = copy;
            },
            .manual_done => {
                if (s.need_manual) |old| s.gpa.free(old);
                s.need_manual = null;
            },
            .connection => |v| s.connection = v,
            .status => |msg| try s.replace(&s.status, msg),
            .update_check => |r| s.update_check = r,
            .toast => |text| {
                const copy = try s.gpa.dupe(u8, text);
                if (s.toast) |old| s.gpa.free(old);
                s.toast = copy;
            },
            .app_update => |info| {
                const version = try s.gpa.dupe(u8, info.version);
                errdefer s.gpa.free(version);
                const message = try s.gpa.dupe(u8, info.message);
                s.clearAppUpdate();
                s.app_update = .{ .phase = info.phase, .version = version, .message = message };
            },
        }
    }

    pub fn closeThread(s: *Store) void {
        const t = &(s.thread orelse return);
        s.freeThread(t);
        s.thread = null;
    }

    fn freeThread(s: *Store, t: *Thread) void {
        for (t.messages.items) |*m| s.freeMessage(m);
        t.messages.deinit(s.gpa);
        s.gpa.free(t.channel);
        s.gpa.free(t.ts);
    }

    fn openThread(s: *Store, channel_id: []const u8, ts: []const u8) std.mem.Allocator.Error!void {
        if (s.thread) |t| if (std.mem.eql(u8, t.channel, channel_id) and std.mem.eql(u8, t.ts, ts)) return;
        s.closeThread();
        const ch = try s.gpa.dupe(u8, channel_id);
        errdefer s.gpa.free(ch);
        s.thread = .{ .channel = ch, .ts = try s.gpa.dupe(u8, ts) };
    }

    /// Marks a thread as the one to show (before its replies arrive)
    pub fn showThread(s: *Store, channel_id: []const u8, ts: []const u8) std.mem.Allocator.Error!void {
        try s.openThread(channel_id, ts);
    }

    fn applyReaction(s: *Store, m: *Message, name: []const u8, user: []const u8, added: bool) std.mem.Allocator.Error!void {
        const mine = std.mem.eql(u8, user, s.self_id);
        for (m.reactions.items, 0..) |*r, i| if (std.mem.eql(u8, r.name, name)) {
            if (added) {
                r.count += 1;
                if (mine) r.mine = true;
            } else {
                r.count -|= 1;
                if (mine) r.mine = false;
                if (r.count == 0) {
                    s.gpa.free(r.name);
                    _ = m.reactions.orderedRemove(i);
                }
            }
            return;
        };
        if (!added) return;
        const copy = try s.gpa.dupe(u8, name);
        errdefer s.gpa.free(copy);
        try m.reactions.append(s.gpa, .{ .name = copy, .count = 1, .mine = mine });
    }

    /// Builds a stored message from the wire form
    fn makeMessage(s: *Store, info: MessageInfo) std.mem.Allocator.Error!Message {
        var m: Message = .{
            .ts = try s.gpa.dupe(u8, info.ts),
            .user = null,
            .text = &.{},
            .thread_ts = null,
            .subtype = null,
            .reply_count = info.reply_count,
        };
        errdefer s.freeMessage(&m);
        if (info.user) |u| m.user = try s.gpa.dupe(u8, u);
        m.text = try s.gpa.dupe(u8, info.text);
        if (info.thread_ts) |t| m.thread_ts = try s.gpa.dupe(u8, t);
        if (info.subtype) |t| m.subtype = try s.gpa.dupe(u8, t);
        m.files = try s.dupeFiles(info.files);
        for (info.reactions) |r| {
            const name = try s.gpa.dupe(u8, r.name);
            errdefer s.gpa.free(name);
            try m.reactions.append(s.gpa, .{ .name = name, .count = r.count, .mine = r.mine });
        }
        return m;
    }

    /// Sorted insert by ts; an existing ts is left alone. Returns the index
    /// it went to, or null if it was already there.
    fn insertInto(s: *Store, list: *std.ArrayList(Message), info: MessageInfo, _: ?void) std.mem.Allocator.Error!void {
        const items = list.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (tsLess(items[mid].ts, info.ts)) lo = mid + 1 else hi = mid;
        }
        if (lo < items.len and std.mem.eql(u8, items[lo].ts, info.ts)) {
            _ = try s.adoptFiles(&items[lo], info);
            return;
        }
        var m = try s.makeMessage(info);
        errdefer s.freeMessage(&m);
        try list.insert(s.gpa, lo, m);
    }

    /// An older page: everything precedes what is held
    fn prependMessages(s: *Store, c: *Channel, infos: []const MessageInfo) std.mem.Allocator.Error!void {
        var added: usize = 0;
        for (infos) |info| {
            const before = c.messages.items.len;
            try s.insertInto(&c.messages, info, null);
            if (c.messages.items.len > before) added += 1;
        }
        c.prepended += added;
    }

    fn freeNotify(s: *Store, n: *NotifyPrefs) void {
        s.gpa.free(n.keywords);
        var it = n.channels.keyIterator();
        while (it.next()) |k| s.gpa.free(k.*);
        n.channels.deinit(s.gpa);
    }

    fn setNotify(s: *Store, info: NotifyInfo) std.mem.Allocator.Error!void {
        var fresh: NotifyPrefs = .{ .desktop = info.desktop, .group = info.group, .hide_text = info.hide_text };
        errdefer s.freeNotify(&fresh);
        fresh.keywords = try s.gpa.dupe(u8, info.keywords);
        for (info.channels) |c| {
            const id = try s.gpa.dupe(u8, c.id);
            errdefer s.gpa.free(id);
            try fresh.channels.put(s.gpa, id, c.settings);
        }
        s.freeNotify(&s.notify);
        s.notify = fresh;
    }

    /// Whether Slack's notification settings call for a desktop notification
    /// for a message someone else just sent. Thread follows are not known,
    /// so a reply in a channel notifies only like any other message there.
    pub fn wantsNotice(s: *const Store, c: *const Channel, info: MessageInfo) bool {
        if (info.user) |u| if (std.mem.eql(u8, u, s.self_id)) return false;
        // System messages (joins, pins, topic changes) never notify
        if (info.subtype) |sub| {
            for ([_][]const u8{ "bot_message", "file_share", "thread_broadcast", "me_message" }) |ok| {
                if (std.mem.eql(u8, sub, ok)) break;
            } else return false;
        }
        if (s.isSelfDm(c)) return false;
        const own = s.notify.channels.get(c.id) orelse ChannelNotify{};
        if (own.muted) {
            // The message's own timestamp is the clock for a temporary mute
            const now = std.fmt.parseInt(i64, info.ts[0 .. std.mem.indexOfScalar(u8, info.ts, '.') orelse info.ts.len], 10) catch 0;
            if (own.muted_until == 0 or now < own.muted_until) return false;
        }
        const mode = own.desktop orelse if (c.kind == .mpim) s.notify.group else s.notify.desktop;
        switch (mode) {
            .nothing => return false,
            .everything => return true,
            .mentions => {},
        }
        // 1:1 DMs are covered by "mentions and DMs"
        if (c.kind == .im) return true;
        if (s.directlyMentioned(info.text)) return true;
        if (!own.quiet_broadcast and s.broadcastsToMe(info.text)) return true;
        return hasKeyword(s.notify.keywords, info.text);
    }

    fn broadcastsToMe(_: *const Store, text: []const u8) bool {
        return std.mem.indexOf(u8, text, "<!here") != null or std.mem.indexOf(u8, text, "<!channel") != null or std.mem.indexOf(u8, text, "<!everyone") != null;
    }

    fn directlyMentioned(s: *const Store, text: []const u8) bool {
        if (s.self_id.len == 0) return false;
        var buf: [32]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "<@{s}", .{s.self_id}) catch return false;
        return std.mem.indexOf(u8, text, needle) != null;
    }

    /// Queues a notification when the settings want one
    fn notice(s: *Store, c: *const Channel, info: MessageInfo) std.mem.Allocator.Error!void {
        if (!s.wantsNotice(c, info)) return;
        const team = try s.gpa.dupe(u8, s.team_name);
        errdefer s.gpa.free(team);
        const channel_id = try s.gpa.dupe(u8, c.id);
        errdefer s.gpa.free(channel_id);
        const title = if (c.kind == .channel or c.kind == .private)
            try std.fmt.allocPrint(s.gpa, "#{s}", .{c.name})
        else
            try s.gpa.dupe(u8, s.channelName(c));
        errdefer s.gpa.free(title);
        const user = try s.gpa.dupe(u8, info.user orelse "");
        errdefer s.gpa.free(user);
        const text = try s.gpa.dupe(u8, info.text);
        errdefer s.gpa.free(text);
        const thread_ts = try s.gpa.dupe(u8, if (info.thread_ts) |t| t else "");
        errdefer s.gpa.free(thread_ts);
        if (s.notices.items.len >= max_notices) {
            var old = s.notices.orderedRemove(0);
            s.freeNotice(&old);
        }
        try s.notices.append(s.gpa, .{ .team = team, .channel = channel_id, .title = title, .user = user, .text = text, .thread_ts = thread_ts, .hide_text = s.notify.hide_text });
    }

    fn freeNotice(s: *Store, n: *Notice) void {
        inline for (.{ n.team, n.channel, n.title, n.user, n.text, n.thread_ts }) |str| s.gpa.free(str);
    }

    pub fn clearNotices(s: *Store) void {
        for (s.notices.items) |*n| s.freeNotice(n);
        s.notices.clearRetainingCapacity();
    }

    fn mentionsMe(s: *const Store, text: []const u8) bool {
        if (std.mem.indexOf(u8, text, "<!here") != null or std.mem.indexOf(u8, text, "<!channel") != null or std.mem.indexOf(u8, text, "<!everyone") != null) return true;
        if (s.self_id.len == 0) return false;
        var buf: [32]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "<@{s}", .{s.self_id}) catch return false;
        return std.mem.indexOf(u8, text, needle) != null;
    }

    /// A bot with no user record (a webhook, say) is only a `bot_id`: name it from its messages
    fn nameBot(s: *Store, info: MessageInfo) std.mem.Allocator.Error!void {
        const id = info.user orelse return;
        const name = info.bot_name orelse return;
        if (s.users.get(id)) |u| if (std.mem.eql(u8, u.name, name)) return;
        try s.upsertUser(.{ .id = id, .name = name, .is_bot = true });
    }

    fn upsertUser(s: *Store, user: User) std.mem.Allocator.Error!void {
        if (s.users.getPtr(user.id)) |existing| {
            try s.replace(&existing.name, user.name);
            existing.is_bot = user.is_bot;
            // A new picture URL makes the held picture stale; keep it until the new one arrives
            if (user.image.len > 0) try s.replace(&existing.image, user.image);
            return;
        }
        const id = try s.gpa.dupe(u8, user.id);
        errdefer s.gpa.free(id);
        const name = try s.gpa.dupe(u8, user.name);
        errdefer s.gpa.free(name);
        const image = try s.gpa.dupe(u8, user.image);
        errdefer s.gpa.free(image);
        try s.users.put(s.gpa, id, .{ .id = id, .name = name, .is_bot = user.is_bot, .image = image });
    }

    fn upsertChannel(s: *Store, info: ChannelInfo) std.mem.Allocator.Error!void {
        if (s.channel(info.id)) |c| {
            try s.replace(&c.name, info.name);
            try s.replace(&c.section, info.section);
            c.place = info.place;
            c.section_rank = info.section_rank;
            c.dormant = info.dormant;
            c.stale = false;
            return;
        }
        var c: Channel = .{
            .id = try s.gpa.dupe(u8, info.id),
            .name = undefined,
            .kind = info.kind,
            .user_id = null,
            .latest = &.{},
            .activity = &.{},
            .dormant = info.dormant,
            .section = &.{},
            .place = info.place,
            .section_rank = info.section_rank,
        };
        errdefer s.gpa.free(c.id);
        c.name = try s.gpa.dupe(u8, info.name);
        errdefer s.gpa.free(c.name);
        if (info.user_id) |uid| c.user_id = try s.gpa.dupe(u8, uid);
        errdefer if (c.user_id) |uid| s.gpa.free(uid);
        c.activity = try s.gpa.dupe(u8, "");
        errdefer s.gpa.free(c.activity);
        c.section = try s.gpa.dupe(u8, info.section);
        errdefer s.gpa.free(c.section);
        try s.channels.append(s.gpa, c);
    }

    fn insertMessage(s: *Store, c: *Channel, info: MessageInfo, live: bool) std.mem.Allocator.Error!void {
        try s.nameBot(info);
        const items = c.messages.items;
        // Binary search for the slot; an existing ts is an echo or a refetch
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (tsLess(items[mid].ts, info.ts)) lo = mid + 1 else hi = mid;
        }
        if (lo < items.len and std.mem.eql(u8, items[lo].ts, info.ts)) {
            // Seen already (the disk cache keeps no files): Slack's copy may know more
            if (try s.adoptFiles(&items[lo], info)) c.rev +%= 1;
            return;
        }

        var m = try s.makeMessage(info);
        errdefer s.freeMessage(&m);
        try c.messages.insert(s.gpa, lo, m);
        // Inserting before the end changes layout under a view
        if (lo != c.messages.items.len - 1) c.rev +%= 1;

        if (lo == c.messages.items.len - 1) {
            try s.replace(&c.latest, info.ts);
            if (live) try s.replace(&c.activity, info.ts);
            const mine = if (info.user) |u| std.mem.eql(u8, u, s.self_id) else false;
            if (live) c.listed = true;
            if (live and !mine) {
                c.unread = true;
                if (c.kind == .im or c.kind == .mpim or s.mentionsMe(info.text)) c.mentions += 1;
                try s.notice(c, info);
            }
        }
        // Bound memory: drop the oldest
        while (c.messages.items.len > max_messages_per_channel) {
            var old = c.messages.orderedRemove(0);
            s.freeMessage(&old);
            c.rev +%= 1;
        }
    }
};

/// Whether `text` holds one of the comma separated `keywords`, ignoring case
fn hasKeyword(keywords: []const u8, text: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, keywords, ',');
    while (it.next()) |raw| {
        const word = std.mem.trim(u8, raw, " ");
        if (word.len > 0 and std.ascii.findIgnoreCase(text, word) != null) return true;
    }
    return false;
}

/// Slack timestamps are fixed-width decimal strings, so compare by length
/// first, then bytes
pub fn tsLess(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return a.len < b.len;
    return std.mem.order(u8, a, b) == .lt;
}

fn findTs(items: []const Message, ts: []const u8) ?usize {
    for (items, 0..) |m, i| if (std.mem.eql(u8, m.ts, ts)) return i;
    return null;
}

test "history merges in order, echoes dedupe, unread tracks others" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    try s.apply(.{ .self = .{ .user_id = "U1", .team_name = "T" } });
    try s.apply(.{ .channels = &.{.{ .id = "C1", .name = "general", .kind = .channel }} });
    try s.apply(.{ .history = .{ .channel = "C1", .messages = &.{
        .{ .ts = "1700000002.000000", .user = "U2", .text = "two" },
        .{ .ts = "1700000001.000000", .user = "U2", .text = "one" },
    } } });
    const c = s.channel("C1").?;
    try std.testing.expectEqualStrings("one", c.messages.items[0].text);
    try std.testing.expect(!c.unread);
    try s.apply(.{ .message = .{ .channel = "C1", .message = .{ .ts = "1700000003.000000", .user = "U2", .text = "three" } } });
    try std.testing.expect(c.unread);
    // Our own message echoed twice appears once and doesn't flag unread
    try s.apply(.{ .marked = .{ .channel = "C1", .ts = "1700000003.000000" } });
    try std.testing.expect(!c.unread);
    for (0..2) |_| try s.apply(.{ .message = .{ .channel = "C1", .message = .{ .ts = "1700000004.000000", .user = "U1", .text = "mine" } } });
    try std.testing.expectEqual(@as(usize, 4), c.messages.items.len);
    try std.testing.expect(!c.unread);
}

test "edit, delete and bounded memory" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    try s.apply(.{ .channels = &.{.{ .id = "C1", .name = "g", .kind = .channel }} });
    const c = s.channel("C1").?;
    try s.apply(.{ .message = .{ .channel = "C1", .message = .{ .ts = "1700000001.000000", .user = null, .text = "a" } } });
    try s.apply(.{ .edited = .{ .channel = "C1", .ts = "1700000001.000000", .text = "b" } });
    try std.testing.expectEqualStrings("b", c.messages.items[0].text);
    try s.apply(.{ .deleted = .{ .channel = "C1", .ts = "1700000001.000000" } });
    try std.testing.expectEqual(@as(usize, 0), c.messages.items.len);
    var buf: [32]u8 = undefined;
    for (0..max_messages_per_channel + 50) |i| {
        const ts = try std.fmt.bufPrint(&buf, "{d}.000000", .{1700000100 + i});
        try s.apply(.{ .message = .{ .channel = "C1", .message = .{ .ts = ts, .user = null, .text = "x" } } });
    }
    try std.testing.expectEqual(@as(usize, max_messages_per_channel), c.messages.items.len);
}

test "DM name comes from the user" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    try s.apply(.{ .channels = &.{.{ .id = "D1", .name = "", .kind = .im, .user_id = "U9" }} });
    try s.apply(.{ .users = &.{.{ .id = "U9", .name = "grace" }} });
    try std.testing.expectEqualStrings("grace", s.channelName(s.channel("D1").?));
}

test "a bot author is named by its messages" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    try s.apply(.{ .channels = &.{.{ .id = "C1", .name = "sales", .kind = .channel }} });
    try s.apply(.{ .message = .{ .channel = "C1", .message = .{ .ts = "1700000001.000000", .user = "B1", .bot_name = "Sales Alerts", .text = "New Sales Alert!" } } });
    try std.testing.expectEqualStrings("Sales Alerts", s.userName("B1").?);
}

test "notices follow Slack's notification settings" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    try s.apply(.{ .self = .{ .user_id = "U1", .team_name = "Acme" } });
    try s.apply(.{ .users = &.{.{ .id = "U2", .name = "grace" }} });
    try s.apply(.{ .channels = &.{
        .{ .id = "C1", .name = "general", .kind = .channel },
        .{ .id = "C2", .name = "loud", .kind = .channel },
        .{ .id = "C3", .name = "muted", .kind = .channel },
        .{ .id = "C4", .name = "later", .kind = .channel },
        .{ .id = "D1", .name = "", .kind = .im, .user_id = "U2" },
    } });
    try s.apply(.{ .notify = .{ .keywords = "deploy, Outage", .channels = &.{
        .{ .id = "C2", .settings = .{ .desktop = .everything } },
        .{ .id = "C3", .settings = .{ .muted = true, .desktop = .everything } },
        .{ .id = "C4", .settings = .{ .muted = true, .muted_until = 1700000500 } },
    } } });
    const say = struct {
        fn at(st: *Store, ch: []const u8, ts: []const u8, user: []const u8, text: []const u8) !void {
            try st.apply(.{ .message = .{ .channel = ch, .message = .{ .ts = ts, .user = user, .text = text } } });
        }
    }.at;

    // Mentions only (the global default): plain channel talk is silent
    try say(&s, "C1", "1700000001.000000", "U2", "lunch?");
    try std.testing.expectEqual(@as(usize, 0), s.notices.items.len);
    try say(&s, "C1", "1700000002.000000", "U2", "hey <@U1> look");
    try say(&s, "C1", "1700000003.000000", "U2", "<!here> standup");
    try say(&s, "C1", "1700000004.000000", "U2", "Deploy is done");
    try say(&s, "C1", "1700000005.000000", "U1", "<@U1> my own message");
    try std.testing.expectEqual(@as(usize, 3), s.notices.items.len);
    try std.testing.expectEqualStrings("#general", s.notices.items[0].title);
    try std.testing.expectEqualStrings("Acme", s.notices.items[0].team);
    s.clearNotices();

    // A DM always notifies, with the person's name
    try say(&s, "D1", "1700000006.000000", "U2", "ping");
    try std.testing.expectEqual(@as(usize, 1), s.notices.items.len);
    try std.testing.expectEqualStrings("grace", s.notices.items[0].title);
    s.clearNotices();

    // Per-channel "everything" notifies; muted never does, until a temporary mute ends
    try say(&s, "C2", "1700000007.000000", "U2", "anything");
    try say(&s, "C3", "1700000008.000000", "U2", "<@U1> anything");
    try say(&s, "C4", "1700000009.000000", "U2", "<@U1> still muted");
    try say(&s, "C4", "1700000600.000000", "U2", "<@U1> mute is over");
    try std.testing.expectEqual(@as(usize, 2), s.notices.items.len);
    s.clearNotices();

    // @channel can be silenced per conversation; "nothing" silences even a mention
    try s.apply(.{ .notify = .{ .desktop = .nothing, .channels = &.{.{ .id = "C1", .settings = .{ .quiet_broadcast = true } }} } });
    try say(&s, "C1", "1700000010.000000", "U2", "<!channel> hi");
    try say(&s, "C2", "1700000011.000000", "U2", "hi");
    try std.testing.expectEqual(@as(usize, 0), s.notices.items.len);

    // Old history never notifies; system messages and our own DM neither
    try s.apply(.{ .notify = .{} });
    try s.apply(.{ .history = .{ .channel = "D1", .messages = &.{.{ .ts = "1600000000.000000", .user = "U2", .text = "old" }} } });
    try s.apply(.{ .message = .{ .channel = "D1", .message = .{ .ts = "1700000012.000000", .user = "U2", .subtype = "channel_join", .text = "joined" } } });
    try std.testing.expectEqual(@as(usize, 0), s.notices.items.len);
}

test "notify modes parse" {
    try std.testing.expectEqual(NotifyMode.everything, NotifyMode.parse("everything"));
    try std.testing.expectEqual(NotifyMode.mentions, NotifyMode.parse("mentions_dms"));
    try std.testing.expectEqual(NotifyMode.nothing, NotifyMode.parse("nothing"));
    try std.testing.expect(hasKeyword("a, Deploy ,", "the DEPLOY ran"));
    try std.testing.expect(!hasKeyword(" , ", "anything"));
}

test "unreads, mentions, teams and reset" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    try s.apply(.{ .teams = .{ .list = &.{ .{ .id = "T1", .name = "A", .url = "https://a.slack.com" }, .{ .id = "T2", .name = "B", .url = "https://b.slack.com" } }, .active = "T1" } });
    try std.testing.expectEqual(@as(usize, 2), s.teams.items.len);
    try s.apply(.{ .self = .{ .user_id = "U1", .team_name = "A" } });
    try s.apply(.{ .channels = &.{ .{ .id = "C1", .name = "g", .kind = .channel }, .{ .id = "D1", .name = "", .kind = .im, .user_id = "U2" } } });
    try s.apply(.{ .unreads = &.{ .{ .id = "C1", .has_unreads = true, .mentions = 2, .latest = "1700000500.000000" }, .{ .id = "D1", .has_unreads = false } } });
    try std.testing.expect(s.channel("C1").?.unread);
    try std.testing.expectEqual(@as(u32, 2), s.channel("C1").?.mentions);
    try std.testing.expectEqualStrings("1700000500.000000", s.channel("C1").?.activity);
    try s.apply(.{ .marked = .{ .channel = "C1", .ts = "1700000500.000000", .unread = 0, .mentions = 0 } });
    try std.testing.expect(!s.channel("C1").?.unread);
    try s.apply(.{ .message = .{ .channel = "C1", .message = .{ .ts = "1700000600.000000", .user = "U2", .text = "hey <@U1>" } } });
    try std.testing.expectEqual(@as(u32, 1), s.channel("C1").?.mentions);
    try s.apply(.{ .message = .{ .channel = "D1", .message = .{ .ts = "1700000601.000000", .user = "U2", .text = "dm" } } });
    try std.testing.expectEqual(@as(u32, 1), s.channel("D1").?.mentions);
    const epoch = s.epoch;
    try s.setActive("T2");
    try std.testing.expectEqual(epoch + 1, s.epoch);
    try std.testing.expectEqual(@as(usize, 0), s.channels.items.len);
    try std.testing.expectEqual(@as(usize, 2), s.teams.items.len);
    // The first workspace is parked, not lost, and updates reach it there
    var item: Item = .{ .arena = std.heap.ArenaAllocator.init(gpa), .update = .{ .message = .{ .channel = "C1", .message = .{ .ts = "1700000700.000100", .user = "U2", .text = "later" } } } };
    defer item.arena.deinit();
    item.setTeam("T1");
    try s.applyItem(&item);
    try std.testing.expectEqual(@as(usize, 0), s.channels.items.len);
    try s.setActive("T1");
    try std.testing.expectEqual(@as(usize, 2), s.channels.items.len);
    try std.testing.expectEqualStrings("later", s.channel("C1").?.messages.items[s.channel("C1").?.messages.items.len - 1].text);
    try std.testing.expectEqualStrings("U1", s.self_id);
    try s.apply(.{ .team_icon = .{ .team = "T2", .bytes = "png" } });
    try std.testing.expectEqualStrings("png", s.teams.items[1].icon);
    try s.apply(.{ .teams = .{ .list = &.{ .{ .id = "T1", .name = "A", .url = "https://a.slack.com" }, .{ .id = "T2", .name = "B", .url = "https://b.slack.com" } }, .active = "T2" } });
    // A refreshed list keeps the icons, and does not move the shown workspace
    try std.testing.expectEqualStrings("png", s.teams.items[1].icon);
    try std.testing.expectEqualStrings("T1", s.active_team);
    try s.apply(.{ .need_manual = "no session" });
    try std.testing.expectEqualStrings("no session", s.need_manual.?);
    try s.apply(.manual_done);
    try std.testing.expect(s.need_manual == null);
}

test "app update: shown across workspaces, replaced by the next phase" {
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    var item: Item = .{ .arena = .init(std.testing.allocator), .update = .{ .app_update = .{ .phase = .available, .version = "0.3.0" } } };
    item.setTeam("T1");
    defer item.deinit();
    try s.applyItem(&item);
    try std.testing.expectEqual(UpdatePhase.available, s.app_update.?.phase);
    try std.testing.expectEqualStrings("0.3.0", s.app_update.?.version);
    try s.apply(.{ .app_update = .{ .phase = .failed, .version = "0.3.0", .message = "no password" } });
    try std.testing.expectEqual(UpdatePhase.failed, s.app_update.?.phase);
    try std.testing.expectEqualStrings("no password", s.app_update.?.message);
}

test "reactions: history, live add and remove" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    try s.apply(.{ .self = .{ .user_id = "U1", .team_name = "T" } });
    try s.apply(.{ .channels = &.{.{ .id = "C1", .name = "g", .kind = .channel }} });
    try s.apply(.{ .history = .{ .channel = "C1", .messages = &.{.{ .ts = "1700000001.000000", .user = "U2", .text = "hi", .reactions = &.{.{ .name = "+1", .count = 2 }}, .reply_count = 3 }} } });
    const m = &s.channel("C1").?.messages.items[0];
    try std.testing.expectEqual(@as(u32, 3), m.reply_count);
    try s.apply(.{ .reaction = .{ .channel = "C1", .ts = "1700000001.000000", .name = "+1", .user = "U1", .added = true } });
    try std.testing.expectEqual(@as(u32, 3), m.reactions.items[0].count);
    try std.testing.expect(m.reactions.items[0].mine);
    try s.apply(.{ .reaction = .{ .channel = "C1", .ts = "1700000001.000000", .name = "tada", .user = "U2", .added = true } });
    try std.testing.expectEqual(@as(usize, 2), m.reactions.items.len);
    try s.apply(.{ .reaction = .{ .channel = "C1", .ts = "1700000001.000000", .name = "tada", .user = "U2", .added = false } });
    try std.testing.expectEqual(@as(usize, 1), m.reactions.items.len);
    try s.apply(.{ .reply_count = .{ .channel = "C1", .ts = "1700000001.000000", .count = 4 } });
    try std.testing.expectEqual(@as(u32, 4), m.reply_count);
}

test "threads: history then live reply" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    try s.apply(.{ .thread_history = .{ .channel = "C1", .thread_ts = "1700000001.000000", .messages = &.{
        .{ .ts = "1700000001.000000", .user = "U2", .text = "parent" },
        .{ .ts = "1700000002.000000", .user = "U3", .text = "r1" },
    } } });
    try std.testing.expectEqual(@as(usize, 2), s.thread.?.messages.items.len);
    try std.testing.expect(s.thread.?.loaded);
    try s.apply(.{ .thread_message = .{ .channel = "C1", .thread_ts = "1700000001.000000", .message = .{ .ts = "1700000003.000000", .user = "U2", .text = "r2" } } });
    try std.testing.expectEqual(@as(usize, 3), s.thread.?.messages.items.len);
    // A reply to some other thread is ignored
    try s.apply(.{ .thread_message = .{ .channel = "C1", .thread_ts = "1700000999.000000", .message = .{ .ts = "1700001000.000000", .user = "U2", .text = "x" } } });
    try std.testing.expectEqual(@as(usize, 3), s.thread.?.messages.items.len);
    s.closeThread();
    try std.testing.expect(s.thread == null);
}

test "typing expires, presence flips, older pages prepend" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    try s.apply(.{ .self = .{ .user_id = "U1", .team_name = "T" } });
    try s.apply(.{ .users = &.{.{ .id = "U2", .name = "grace" }} });
    try s.apply(.{ .channels = &.{.{ .id = "C1", .name = "g", .kind = .channel }} });
    try s.apply(.{ .typing = .{ .channel = "C1", .user = "U2", .at_ms = 1000 } });
    try s.apply(.{ .typing = .{ .channel = "C1", .user = "U1", .at_ms = 1000 } });
    var out: [4][]const u8 = undefined;
    const c = s.channel("C1").?;
    try std.testing.expectEqual(@as(usize, 1), s.typingNow(c, 2000, &out));
    try std.testing.expectEqualStrings("grace", out[0]);
    try std.testing.expectEqual(@as(usize, 0), s.typingNow(c, 1000 + typing_ms + 1, &out));

    try std.testing.expect(!s.isOnline("U2"));
    try s.apply(.{ .presence = .{ .users = &.{"U2"}, .active = true } });
    try std.testing.expect(s.isOnline("U2"));

    try s.apply(.{ .history = .{ .channel = "C1", .has_more = true, .messages = &.{.{ .ts = "1700000100.000000", .user = "U2", .text = "newer" }} } });
    try std.testing.expect(c.has_older);
    try s.apply(.{ .history = .{ .channel = "C1", .older = true, .has_more = false, .messages = &.{
        .{ .ts = "1700000050.000000", .user = "U2", .text = "older2" },
        .{ .ts = "1700000040.000000", .user = "U2", .text = "older1" },
    } } });
    try std.testing.expectEqual(@as(usize, 3), c.messages.items.len);
    try std.testing.expectEqual(@as(usize, 2), c.prepended);
    try std.testing.expectEqualStrings("older1", c.messages.items[0].text);
    try std.testing.expect(!c.has_older);
}

test "sidebar preference decides which conversations are listed" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    try s.apply(.{ .channels = &.{
        .{ .id = "D1", .name = "", .kind = .im, .user_id = "U2" },
        .{ .id = "D2", .name = "", .kind = .im, .user_id = "U3", .dormant = true },
        .{ .id = "D3", .name = "", .kind = .im, .user_id = "U4" },
    } });
    s.channel("D3").?.listed = false;
    try std.testing.expect(s.shownInSidebar(s.channel("D1").?));
    try std.testing.expect(!s.shownInSidebar(s.channel("D2").?));
    try std.testing.expect(!s.shownInSidebar(s.channel("D3").?));
    try s.apply(.{ .sidebar_mode = .all });
    try std.testing.expect(s.shownInSidebar(s.channel("D2").?));
    try s.apply(.{ .sidebar_mode = .unread });
    try std.testing.expect(!s.shownInSidebar(s.channel("D1").?));
    s.channel("D1").?.unread = true;
    try std.testing.expect(s.shownInSidebar(s.channel("D1").?));
    try std.testing.expectEqual(SidebarMode.active, SidebarMode.parse("hide_inactive_channels"));
    try std.testing.expectEqual(SidebarMode.all, SidebarMode.parse(""));
}

test "a refetched message gains the files the cached copy lacked, and previews can be cleared" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    try s.apply(.{ .channels = &.{.{ .id = "C1", .name = "general", .kind = .channel }} });
    const ts = "1700000001.000100";
    try s.apply(.{ .history = .{ .channel = "C1", .messages = &.{.{ .ts = ts, .user = null, .text = "pic" }}, .has_more = false } });
    const c = s.channel("C1").?;
    try std.testing.expectEqual(@as(usize, 0), c.messages.items[0].files.len);
    const rev = c.rev;
    const files = [_]FileInfo{.{ .id = "F1", .name = "a.png", .thumb = "https://files.slack.com/a.png", .thumb_w = 10, .thumb_h = 10 }};
    try s.apply(.{ .history = .{ .channel = "C1", .messages = &.{.{ .ts = ts, .user = null, .text = "pic", .files = &files }}, .has_more = false } });
    try std.testing.expectEqual(@as(usize, 1), c.messages.items[0].files.len);
    try std.testing.expectEqualStrings("a.png", c.messages.items[0].files[0].name);
    try std.testing.expect(c.rev != rev);

    try s.apply(.{ .file_image = .{ .id = "F1", .bytes = "png" } });
    try std.testing.expectEqualStrings("png", s.fileImage("F1").?);
    s.clearImages();
    try std.testing.expect(s.fileImage("F1") == null);
}
