//! The real UI: sidebar of conversations, message list for the selected one,
//! composer. Reads the store; talks to the network side through `Actions`.
const std = @import("std");
const nanoui = @import("nanoui");
const kit = nanoui.kit;
const slack = @import("slack");
const store = @import("store");
const ui = nanoui.ui;
const var_list = @import("var_list.zig");
const theme = @import("theme.zig");
const open_url = @import("open_url.zig");
const composer_mod = @import("composer.zig");
const layout_mod = @import("layout.zig");
const settings_mod = @import("settings.zig");

const mrkdwn = slack.mrkdwn;

// Sizing, loosely Material You: roomy rows, 40dp navigation items, 15px text
const row_px: f32 = 20;
const avatar_size: f32 = 36;
const avatar_gap: f32 = 12;
const first_top: f32 = 12;
const cont_top: f32 = 2;
const row_bottom: f32 = 2;
const sidebar_default: f32 = 272;
const sidebar_min: f32 = 200;
const sidebar_max: f32 = 520;
/// A layout change is saved once it has not moved for this long
const layout_settle_default_ms = 600;
const handle_w: f32 = 6;
const composer_lines: u8 = 2;
const composer_tall_lines: u8 = 10;
/// DMs quiet for longer than this fold away behind "Show older"
const rail_w: f32 = 76;
const nav_h: f32 = 40;

const time_style: ui.TextStyle = .{ .size = 12 };
const group_secs = 5 * 60;
const reaction_row_h: f32 = 32;
const reply_row_h: f32 = 28;
const thread_w: f32 = 400;
const typing_h: f32 = 24;
/// Outgoing typing events are sent at most this often
const typing_send_ms = 3000;
const quick_reactions = [_][]const u8{ "+1", "heart", "tada" };

/// What the UI asks of the network side
pub const Actions = struct {
    ctx: *anyopaque,
    open: *const fn (ctx: *anyopaque, channel: []const u8) void,
    send: *const fn (ctx: *anyopaque, channel: []const u8, text: []const u8, thread_ts: ?[]const u8) void,
    older: *const fn (ctx: *anyopaque, channel: []const u8, before: []const u8) void,
    open_thread: *const fn (ctx: *anyopaque, channel: []const u8, ts: []const u8) void,
    react: *const fn (ctx: *anyopaque, channel: []const u8, ts: []const u8, name: []const u8, add: bool) void,
    typing: *const fn (ctx: *anyopaque, channel: []const u8) void,
    mark: *const fn (ctx: *anyopaque, channel: []const u8, ts: []const u8) void,
    switch_team: *const fn (ctx: *anyopaque, team_id: []const u8) void,
    manual: *const fn (ctx: *anyopaque, url: []const u8, token: []const u8, cookie: []const u8) void,
    /// Away (`true`) or automatic presence
    set_presence: *const fn (ctx: *anyopaque, away: bool) void,
};

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(t: *const i64, out: *Tm) ?*Tm;

fn tsSeconds(ts: []const u8) i64 {
    const dot = std.mem.indexOfScalar(u8, ts, '.') orelse ts.len;
    return std.fmt.parseInt(i64, ts[0..dot], 10) catch 0;
}

fn lineHeight(c: *ui.Context, style: ui.TextStyle) f32 {
    return if (style.line_height > 0) style.line_height * c.text.zoom else c.text.font(style).lineHeight();
}

/// First character of a name, uppercased if ASCII. Lives in the frame's
/// arena: nanoui reads text after the widget call returns.
fn initialOf(c: *ui.Context, name: []const u8) []const u8 {
    if (name.len == 0) return "?";
    const n = @min(std.unicode.utf8ByteSequenceLength(name[0]) catch 1, name.len);
    const out = c.alloc().dupe(u8, name[0..n]) catch return "?";
    if (n == 1) out[0] = std.ascii.toUpper(out[0]);
    return out;
}

/// The sidebar's top rows; each opens a page of its own
const TopView = enum {
    none,
    threads,
    huddles,
    drafts,
    saved,

    fn label(v: TopView) []const u8 {
        return switch (v) {
            .none => "",
            .threads => "Threads",
            .huddles => "Huddles",
            .drafts => "Drafts & sent",
            .saved => "Saved",
        };
    }

    fn glyph(v: TopView) []const u8 {
        return switch (v) {
            .none => "",
            .threads => "💬",
            .huddles => "🎧",
            .drafts => "📝",
            .saved => "🔖",
        };
    }
};

const LinkSpan = struct { start: u32, end: u32, target: []const u8 };

pub const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    store: *store.Store,
    actions: Actions,
    /// Channel to open first, if it exists (for development)
    preferred: ?[]const u8 = null,
    window: ?*nanoui.Window = null,
    selected: ?[]u8 = null,
    cur: ?*store.Channel = null,
    list: var_list.VarList,
    list_rev: u32 = 0,
    main_composer: composer_mod.Composer,
    marked_ts: []u8 = &.{},
    pending_select: ?[]const u8 = null,
    pal: theme.Palette = undefined,
    /// The store's epoch this state was built for
    epoch: u32 = 0,
    pending_team: ?[]const u8 = null,
    close_thread: bool = false,
    sidebar_px: f32 = sidebar_default,
    resizing: bool = false,
    /// Where the layout is saved (null: nowhere), what is on disk, and
    /// when the layout last changed (0: it matches the disk)
    layout_dir: ?[]const u8 = null,
    /// Where the last known state of each workspace is kept (null: nowhere)
    cache_dir: ?[]const u8 = null,
    layout_saved: layout_mod.Layout = .{},
    layout_dirty_ms: i64 = 0,
    layout_settle_ms: i64 = layout_settle_default_ms,
    window_size: [2]f32 = .{ 0, 0 },
    /// Show the DMs / channels the sidebar preference hides
    show_hidden_dms: bool = false,
    show_hidden_chans: bool = false,
    show_hidden_apps: bool = false,
    /// The message box is tall (10 lines) instead of 2
    composer_expanded: bool = false,
    settings: settings_mod.Settings = .{},
    /// Owns the strings of `settings`
    settings_arena: std.heap.ArenaAllocator,
    settings_open: bool = false,
    /// A page from the sidebar's top rows, in place of the conversation
    top_view: TopView = .none,
    /// The font pickers' popovers: interface, chat
    font_open: [2]bool = .{ false, false },
    /// Installed font families, found the first time Settings opens
    font_names: ?[]const []const u8 = null,
    user_menu_open: bool = false,
    self_away: bool = false,
    /// The fonts and zoom handed to nanoui last frame
    applied_ui_font: []const u8 = "",
    applied_chat_font: []const u8 = "",
    applied_zoom: u16 = 100,
    manual_url: ui.TextBuffer = .{},
    manual_token: ui.TextBuffer = .{},
    manual_cookie: ui.TextBuffer = .{},
    manual_busy: bool = false,
    /// An older page was requested and has not arrived
    older_pending: bool = false,
    thread_composer: composer_mod.Composer,
    last_typing_ms: i64 = 0,
    /// Message the pointer is over (ts), for its toolbar
    hover_ts: [32]u8 = undefined,
    hover_len: usize = 0,
    /// Opens a link; replaced in tests
    opener: *const fn (gpa: std.mem.Allocator, io: std.Io, url: []const u8) void = open_url.open,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, st: *store.Store, actions: Actions) State {
        return .{ .gpa = gpa, .io = io, .store = st, .actions = actions, .list = .{ .gpa = gpa }, .main_composer = .init(gpa), .thread_composer = .init(gpa), .settings_arena = .init(gpa) };
    }

    pub fn deinit(s: *State) void {
        s.list.deinit();
        s.main_composer.deinit();
        s.manual_url.deinit();
        s.manual_token.deinit();
        s.manual_cookie.deinit();
        s.thread_composer.deinit();
        s.settings_arena.deinit();
        if (s.font_names) |names| {
            for (names) |n| s.gpa.free(n);
            s.gpa.free(names);
        }
        if (s.selected) |sel| s.gpa.free(sel);
        s.gpa.free(s.marked_ts);
    }

    // Selection and read state

    pub fn select(s: *State, id: []const u8) void {
        if (s.selected) |old| {
            if (std.mem.eql(u8, old, id)) return;
            s.gpa.free(old);
        }
        s.selected = s.gpa.dupe(u8, id) catch null;
        s.store.rememberSelected(id);
        s.gpa.free(s.marked_ts);
        s.marked_ts = &.{};
        s.list.reset();
        s.list.stickToEnd();
        s.list_rev = 0;
        s.older_pending = false;
        s.store.closeThread();
        if (s.store.channel(id)) |c| c.unread = false;
        s.actions.open(s.actions.ctx, id);
        s.main_composer.clear();
    }

    /// Call after the store changed, on the UI thread: marks what the user
    /// is looking at as read
    pub fn afterUpdates(s: *State) void {
        const id = s.selected orelse return;
        const c = s.store.channel(id) orelse return;
        if (c.latest.len == 0 or std.mem.eql(u8, c.latest, s.marked_ts)) return;
        if (s.window) |w| if (!w.isFocused()) return;
        c.unread = false;
        const dup = s.gpa.dupe(u8, c.latest) catch return;
        s.gpa.free(s.marked_ts);
        s.marked_ts = dup;
        s.actions.mark(s.actions.ctx, id, c.latest);
    }

    // Message list source

    fn source(s: *State) var_list.Source {
        const n = if (s.cur) |c| c.messages.items.len else 0;
        return .{ .ptr = s, .count = n, .estimate = estimate, .measure = measure };
    }

    fn resolver(s: *State) mrkdwn.Resolver {
        return .{ .ctx = s.store, .user = resolveUser, .channel = resolveChannel };
    }

    fn resolveUser(ctx: *const anyopaque, id: []const u8) ?[]const u8 {
        const st: *const store.Store = @ptrCast(@alignCast(ctx));
        return st.userName(id);
    }

    fn resolveChannel(ctx: *const anyopaque, id: []const u8) ?[]const u8 {
        const st: *store.Store = @constCast(@ptrCast(@alignCast(ctx)));
        const c = st.channel(id) orelse return null;
        return c.name;
    }

    fn hasHeader(s: *const State, i: usize) bool {
        return hasHeaderIn(s.cur.?.messages.items, i);
    }

    fn hasHeaderIn(msgs: []const store.Message, i: usize) bool {
        if (i == 0) return true;
        const prev = msgs[i - 1];
        const cur = msgs[i];
        const same_author = if (prev.user) |a| (if (cur.user) |b| std.mem.eql(u8, a, b) else false) else cur.user == null;
        return !same_author or tsSeconds(cur.ts) - tsSeconds(prev.ts) > group_secs;
    }

    /// Height of what sits under a message's text: reactions, reply link
    fn extraHeight(m: *const store.Message, in_thread: bool) f32 {
        var h: f32 = 0;
        if (m.reactions.items.len > 0) h += reaction_row_h;
        if (!in_thread and m.reply_count > 0) h += reply_row_h;
        return h;
    }

    /// Width the message text wraps to, in a list `width` wide
    fn contentWidth(width: f32) f32 {
        return @max(40, width - 2 * row_px - avatar_size - avatar_gap);
    }

    fn estimate(ptr: *anyopaque, i: usize, width: f32) f32 {
        const s: *State = @ptrCast(@alignCast(ptr));
        const zoom = s.zoomFactor();
        const chars_per_line = @max(8, contentWidth(width) / (s.bodyStyle().size * zoom * 0.5));
        var lines: f32 = 0;
        var it = std.mem.splitScalar(u8, s.cur.?.messages.items[i].text, '\n');
        while (it.next()) |p| lines += @max(1, @ceil(@as(f32, @floatFromInt(p.len)) / chars_per_line));
        const head = s.hasHeader(i);
        return (if (head) first_top + s.nameStyle().line_height * zoom else cont_top) + lines * s.bodyStyle().line_height * zoom + extraHeight(&s.cur.?.messages.items[i], false) + row_bottom;
    }

    fn measure(ptr: *anyopaque, c: *ui.Context, i: usize, width: f32) f32 {
        const s: *State = @ptrCast(@alignCast(ptr));
        const m = s.cur.?.messages.items[i];
        const r = mrkdwn.render(c.alloc(), m.text, s.resolver()) catch mrkdwn.Rendered{ .text = m.text, .runs = &.{} };
        var lines: usize = 0;
        var it = std.mem.splitScalar(u8, r.text, '\n');
        const w = contentWidth(width);
        while (it.next()) |p| lines += @max(1, c.text.wrap(if (p.len == 0) " " else p, s.bodyStyle(), w).len);
        const head = s.hasHeader(i);
        return (if (head) first_top + lineHeight(c, s.nameStyle()) else cont_top) + @as(f32, @floatFromInt(lines)) * lineHeight(c, s.bodyStyle()) + extraHeight(&m, false) + row_bottom;
    }

    // View

    pub fn view(s: *State, c: *ui.Context) void {
        s.pal = theme.apply(c);
        s.applyFonts(c);
        s.trackLayout(c);
        if (s.epoch != s.store.epoch) s.forgetWorkspace();
        if (s.store.need_manual) |reason| return s.manualScreen(c, reason);
        s.manual_busy = false;
        s.pickInitial();
        s.cur = if (s.selected) |id| s.store.channel(id) else null;
        if (s.cur) |cur| if (cur.rev != s.list_rev) {
            s.list_rev = cur.rev;
            s.list.reset();
        };
        // An older page arrived: keep the reader where they were
        if (s.cur) |cur| if (cur.prepended > 0) {
            const n = cur.prepended;
            cur.prepended = 0;
            s.older_pending = false;
            if (s.list.width > 0 and s.list.heights.items.len > 0) {
                const shift = s.list.prepend(s.source(), n) catch 0;
                s.list.shiftScroll(c, shift);
            } else s.list.reset();
        };

        const root = ui.div(c).row().sizeFull();
        defer root.end();
        s.rail(c);
        s.sidebar(c);
        s.resizeHandle(c);
        if (s.settings_open) {
            s.settingsPage(c);
        } else if (s.top_view != .none) {
            s.topPage(c);
        } else s.main(c);
        if (!s.settings_open and s.top_view == .none and s.store.thread != null) {
            ui.div(c).w(1).hFull().bg(c.theme.border).end();
            s.threadPanel(c);
        }

        if (s.pending_select) |id| {
            s.pending_select = null;
            s.top_view = .none;
            s.select(id);
        }
        if (s.close_thread) {
            s.close_thread = false;
            s.store.closeThread();
        }
        if (s.pending_team) |id| {
            s.pending_team = null;
            // Show the workspace now (its cached data, or a spinner); the
            // network side catches up and can be redirected at any time
            if (s.cache_dir) |dir| store.cache.save(s.gpa, s.io, dir, s.store);
            s.store.setActive(id) catch {};
            // A workspace not visited this run opens with its last known state
            if (s.store.channels.items.len == 0) if (s.cache_dir) |dir| {
                var arena = std.heap.ArenaAllocator.init(s.gpa);
                defer arena.deinit();
                _ = store.cache.loadTeam(arena.allocator(), s.io, dir, s.store, id);
            };
            s.actions.switch_team(s.actions.ctx, id);
        }
        s.afterUpdates();
    }

    /// A different workspace is loading: nothing selected before applies
    fn forgetWorkspace(s: *State) void {
        s.epoch = s.store.epoch;
        if (s.selected) |sel| s.gpa.free(sel);
        s.selected = null;
        s.gpa.free(s.marked_ts);
        s.marked_ts = &.{};
        s.cur = null;
        s.list.reset();
        s.list_rev = 0;
        s.main_composer.clear();
        // The command-line channel only makes sense for the first workspace
        s.preferred = null;
    }

    /// Workspace switcher, like a Material navigation rail
    fn rail(s: *State, c: *ui.Context) void {
        const col = ui.div(c).column().w(rail_w).hFull().itemsCenter().gap(12).pt(16).pb(16).bg(s.pal.container_high);
        defer col.end();
        for (s.store.teams.items) |team| {
            const active = std.mem.eql(u8, team.id, s.store.active_team);
            var tile = ui.div(c).w(52).h(52).center().rounded(16).control();
            tile = tile.bg(if (active) s.pal.secondary_container else c.theme.surface_hover.alpha(0));
            tile = tile.hover(if (active) s.pal.secondary_container else c.theme.surface_hover);
            defer tile.end();
            const it = tile.interaction();
            if (!active and it.clicked) s.pending_team = team.id;
            const drawn = team.icon.len > 0 and ui.image(c, .{ .key = team.id, .bytes = team.icon, .max_width = 40, .max_height = 40, .radius = 10, .scale = 1 });
            if (!drawn) ui.text(c, initialOf(c, team.name), .{ .size = 20, .weight = .bold, .color = if (active) s.pal.on_primary_container else c.theme.muted });
            kit.tooltip(c, it, team.name, .{ .placement = .right, .delay = 0.3 });
        }
        ui.spacer(c);
        s.userTile(c);
    }

    /// Your avatar at the bottom of the rail; opens the account menu
    fn userTile(s: *State, c: *ui.Context) void {
        const name = s.store.userName(s.store.self_id) orelse "";
        const tile = ui.div(c).w(52).h(52).center().roundedFull().circular().control();
        defer tile.end();
        const it = tile.interaction();
        if (it.clicked) s.user_menu_open = !s.user_menu_open;
        s.avatar(c, name, s.store.self_id, 40, 18);
        if (it.rect) |r| {
            // The presence dot on the avatar's corner
            const dot = ui.div(c).fixed().offset(r.x + r.w - 17, r.y + r.h - 17).layer(3).w(12).h(12).roundedFull().circular().bg(if (s.self_away) s.pal.container_high else c.theme.success).border(s.pal.container_high).borderW(2);
            dot.end();
        }
        if (name.len > 0) kit.tooltip(c, it, name, .{ .placement = .right, .delay = 0.3 });
        s.userMenu(c, it.rect, name);
    }

    fn avatar(s: *State, c: *ui.Context, name: []const u8, id: []const u8, size: f32, text_size: f32) void {
        const av = ui.div(c).w(size).h(size).roundedFull().circular().bg(theme.avatarColor(s.pal, if (id.len > 0) id else name)).center();
        defer av.end();
        ui.text(c, initialOf(c, name), .{ .size = text_size, .weight = .semibold, .color = ui.Color.white });
    }

    fn userMenu(s: *State, c: *ui.Context, anchor: ?ui.Rect, name: []const u8) void {
        const p = kit.popover(c, "user-menu", &s.user_menu_open, anchor, .{ .placement = .right, .width = 280, .padding = 8, .gap = 10 }) orelse return;
        defer p.end();
        {
            const head = ui.div(c).row().wFull().itemsCenter().gap(12).px(8).py(8);
            defer head.end();
            s.avatar(c, name, s.store.self_id, 44, 20);
            const col = ui.div(c).column().gap(2);
            defer col.end();
            ui.text(c, if (name.len > 0) name else "You", .{ .size = 16, .weight = .bold });
            ui.text(c, if (s.self_away) "Away" else "Active", .{ .size = 13, .color = c.theme.muted });
        }
        if (s.menuRow(c, if (s.self_away) "Set yourself as active" else "Set yourself as away", "")) {
            s.self_away = !s.self_away;
            s.actions.set_presence(s.actions.ctx, s.self_away);
            s.user_menu_open = false;
        }
        ui.divider(c);
        if (s.menuRow(c, "Profile", "")) {
            s.openTeamPage(c, "team/", s.store.self_id);
            s.user_menu_open = false;
        }
        if (s.menuRow(c, "Settings", "")) {
            s.settings_open = true;
            s.user_menu_open = false;
        }
        if (s.menuRow(c, "Account settings", "↗")) {
            s.openTeamPage(c, "account/settings", "");
            s.user_menu_open = false;
        }
        ui.divider(c);
        if (s.menuRow(c, "Exit Lax", "")) {
            if (s.window) |w| w.close();
        }
    }

    fn menuRow(s: *State, c: *ui.Context, label: []const u8, trailing: []const u8) bool {
        ui.key(c, label);
        const row = ui.div(c).row().wFull().h(36).px(8).itemsCenter().rounded(8).control().hover(c.theme.surface_hover);
        defer row.end();
        ui.text(c, label, .{ .size = 14, .color = c.theme.text });
        ui.spacer(c);
        if (trailing.len > 0) ui.text(c, trailing, .{ .size = 14, .color = s.pal.link });
        return row.clicked();
    }

    /// Opens a page of the active workspace's web app in the browser
    fn openTeamPage(s: *State, c: *ui.Context, path: []const u8, tail: []const u8) void {
        for (s.store.teams.items) |t| if (std.mem.eql(u8, t.id, s.store.active_team)) {
            const base = std.mem.trimEnd(u8, t.url, "/");
            s.opener(s.gpa, s.io, c.print("{s}/{s}{s}", .{ base, path, tail }));
            return;
        };
    }

    /// Shown when no session could be read: paste a token and cookie
    fn manualScreen(s: *State, c: *ui.Context, reason: []const u8) void {
        const root = ui.div(c).column().sizeFull().center().bg(c.theme.background);
        defer root.end();
        const card = ui.div(c).column().w(560).gap(14).p(28).rounded(24).bg(s.pal.container);
        defer card.end();
        ui.text(c, "Sign in to Slack", .{ .size = 22, .weight = .bold });
        ui.text(c, reason, .{ .size = 14, .color = c.theme.danger, .wrap = true });
        ui.text(c, "Lax uses the same session as Slack in your browser. Open your workspace at app.slack.com, then open developer tools (F12):", .{ .size = 13, .color = c.theme.muted, .wrap = true });
        ui.text(c, "1. Application (or Storage) > Cookies: copy the value of the \"d\" cookie. It starts with xoxd-", .{ .size = 13, .color = c.theme.muted, .wrap = true });
        ui.text(c, "2. Application > Local Storage > app.slack.com > localConfig_v2: find your workspace's \"token\". It starts with xoxc-", .{ .size = 13, .color = c.theme.muted, .wrap = true });
        ui.text(c, "Both stay on this computer, in your system keyring. This is unsupported by Slack.", .{ .size = 13, .color = c.theme.muted, .wrap = true });

        const wide: ui.Length = .{ .px = 504 };
        ui.text(c, "Workspace address", .{ .size = 13, .weight = .semibold });
        _ = ui.textField(c, &s.manual_url, .{ .placeholder = "https://yourteam.slack.com", .width = wide, .size = 15 });
        ui.text(c, "Token (xoxc-…)", .{ .size = 13, .weight = .semibold });
        _ = ui.textField(c, &s.manual_token, .{ .placeholder = "xoxc-…", .width = wide, .size = 15, .password = true });
        ui.text(c, "Cookie d (xoxd-…)", .{ .size = 13, .weight = .semibold });
        const res = ui.textField(c, &s.manual_cookie, .{ .placeholder = "xoxd-…", .width = wide, .size = 15, .password = true });

        const ready = s.manual_url.text().len > 0 and s.manual_token.text().len > 0 and s.manual_cookie.text().len > 0;
        const go = ui.button(c, if (s.manual_busy) "Checking…" else "Connect", .{ .variant = .primary, .disabled = !ready or s.manual_busy, .size = 15 });
        if ((go.clicked or res.submitted) and ready and !s.manual_busy) {
            s.manual_busy = true;
            s.actions.manual(s.actions.ctx, s.manual_url.text(), s.manual_token.text(), s.manual_cookie.text());
        }
    }

    // Settings

    /// Message text: the chat font and size, unzoomed (the interface zoom applies on top)
    fn bodyStyle(s: *const State) ui.TextStyle {
        const size: f32 = @floatFromInt(s.settings.chat_size);
        return .{ .size = size, .wrap = true, .line_height = @round(size * 22.0 / 15.0), .alt = true };
    }

    fn nameStyle(s: *const State) ui.TextStyle {
        var st = s.bodyStyle();
        st.wrap = false;
        st.weight = .semibold;
        return st;
    }

    fn zoomFactor(s: *const State) f32 {
        return @as(f32, @floatFromInt(s.settings.interface_size)) / 100;
    }

    /// Takes settings (strings are copied)
    pub fn applySettings(s: *State, new: settings_mod.Settings) void {
        const a = s.settings_arena.allocator();
        var next = new.clamped();
        next.ui_font = a.dupe(u8, new.ui_font) catch "";
        next.chat_font = a.dupe(u8, new.chat_font) catch "";
        s.settings = next;
    }

    fn saveSettings(s: *State) void {
        if (s.layout_dir) |dir| settings_mod.save(s.gpa, s.io, dir, s.settings);
    }

    /// Hands the chosen fonts and zoom to nanoui; they take effect next frame
    fn applyFonts(s: *State, c: *ui.Context) void {
        const ui_font: ?[]const u8 = if (s.settings.ui_font.len > 0) s.settings.ui_font else null;
        const chat_font: ?[]const u8 = if (s.settings.chat_font.len > 0) s.settings.chat_font else null;
        if (!std.mem.eql(u8, s.applied_ui_font, s.settings.ui_font) or !std.mem.eql(u8, s.applied_chat_font, s.settings.chat_font)) {
            c.family_override = ui_font;
            c.alt_override = chat_font;
            s.applied_ui_font = s.settings.ui_font;
            s.applied_chat_font = s.settings.chat_font;
            s.list.reset();
            c.changed = true;
        }
        if (s.applied_zoom != s.settings.interface_size) {
            s.applied_zoom = s.settings.interface_size;
            c.setZoom(s.zoomFactor());
            s.list.reset();
            c.changed = true;
        }
    }

    /// Installed font families, sorted (empty where nanoui can't list them)
    fn loadFontNames(s: *State, c: *ui.Context) []const []const u8 {
        if (s.font_names) |n| return n;
        var names: std.ArrayList([]const u8) = .empty;
        if (comptime @hasField(@TypeOf(c.text.*), "db")) {
            c.text.db.scan();
            for (c.text.db.faces.items) |*f| {
                const name = f.style.name();
                if (name.len == 0 or name[0] == '.') continue;
                var seen = false;
                for (names.items) |n| if (std.ascii.eqlIgnoreCase(n, name)) {
                    seen = true;
                    break;
                };
                if (seen) continue;
                const copy = s.gpa.dupe(u8, name) catch continue;
                names.append(s.gpa, copy) catch s.gpa.free(copy);
            }
            std.mem.sort([]const u8, names.items, {}, struct {
                fn less(_: void, x: []const u8, y: []const u8) bool {
                    return std.ascii.lessThanIgnoreCase(x, y);
                }
            }.less);
        }
        s.font_names = names.toOwnedSlice(s.gpa) catch &.{};
        return s.font_names.?;
    }

    fn settingsPage(s: *State, c: *ui.Context) void {
        const page = ui.div(c).column().grow().hFull().bg(c.theme.background);
        defer page.end();
        {
            const head = ui.div(c).row().itemsCenter().wFull().h(64).px(24);
            defer head.end();
            ui.text(c, "Settings", .{ .size = 18, .weight = .bold });
            ui.spacer(c);
            const close = ui.div(c).w(32).h(32).center().roundedFull().circular().control().hover(c.theme.surface_hover);
            defer close.end();
            if (close.clicked() or (!s.font_open[0] and !s.font_open[1] and c.shortcut(.{ .key = ui.Shortcut.escape }))) s.settings_open = false;
            ui.text(c, "✕", .{ .size = 14, .color = c.theme.muted });
        }
        ui.divider(c);
        const body = ui.div(c).column().wFull().grow().scrollY().px(32).py(24).gap(16);
        defer body.end();
        var changed = false;

        ui.text(c, "Interface", .{ .size = 16, .weight = .bold });
        {
            const row = s.settingRow(c, "Font");
            defer row.end();
            if (s.fontPicker(c, 0, s.settings.ui_font, "System default")) |name| {
                s.settings.ui_font = s.settings_arena.allocator().dupe(u8, name) catch "";
                changed = true;
            }
        }
        {
            const row = s.settingRow(c, "Size");
            defer row.end();
            var pct: f64 = @floatFromInt(s.settings.interface_size);
            if (kit.numberInput(c, &pct, .{ .min = settings_mod.interface_min, .max = settings_mod.interface_max, .step = 5, .width = 160 })) {
                s.settings.interface_size = @intFromFloat(pct);
                changed = true;
            }
            ui.text(c, "%", .{ .size = 13, .color = c.theme.muted });
        }

        ui.div(c).h(8).end();
        ui.text(c, "Chat", .{ .size = 16, .weight = .bold });
        {
            const row = s.settingRow(c, "Font");
            defer row.end();
            if (s.fontPicker(c, 1, s.settings.chat_font, "Same as interface")) |name| {
                s.settings.chat_font = s.settings_arena.allocator().dupe(u8, name) catch "";
                changed = true;
            }
        }
        {
            const row = s.settingRow(c, "Text size");
            defer row.end();
            var pt: f64 = @floatFromInt(s.settings.chat_size);
            if (kit.numberInput(c, &pt, .{ .min = settings_mod.chat_min, .max = settings_mod.chat_max, .step = 1, .width = 160 })) {
                s.settings.chat_size = @intFromFloat(pt);
                changed = true;
            }
            ui.text(c, "pt", .{ .size = 13, .color = c.theme.muted });
        }

        ui.div(c).h(8).end();
        ui.text(c, "Preview", .{ .size = 16, .weight = .bold });
        {
            const card = ui.div(c).column().wFull().gap(4).p(16).rounded(16).bg(s.pal.container);
            defer card.end();
            ui.text(c, "Grace", s.nameStyle());
            ui.text(c, "The quick brown fox jumps over the lazy dog. 0123456789", s.bodyStyle());
        }
        if (changed) {
            s.settings = s.settings.clamped();
            s.saveSettings();
        }
    }

    /// A row with its label; the caller adds the control and ends the row
    fn settingRow(_: *State, c: *ui.Context, label: []const u8) ui.Div {
        const row = ui.div(c).row().itemsCenter().gap(16).wFull().h(44);
        const lab = ui.div(c).w(120);
        ui.text(c, label, .{ .size = 14, .color = c.theme.muted });
        lab.end();
        return row;
    }

    /// A button showing the current family; opens a scrolling list. Returns
    /// the family picked ("" for the default entry).
    fn fontPicker(s: *State, c: *ui.Context, which: usize, current: []const u8, default_label: []const u8) ?[]const u8 {
        var chosen: ?[]const u8 = null;
        const btn = ui.div(c).row().w(280).h(40).px(14).gap(6).itemsCenter().rounded(12).bg(s.pal.container_high).border(c.theme.border).borderW(1).control();
        const it = btn.interaction();
        {
            defer btn.end();
            ui.text(c, if (current.len == 0) default_label else current, .{ .size = 14, .truncate = .ellipsis });
            ui.spacer(c);
            ui.text(c, "▾", .{ .size = 12, .color = c.theme.muted });
        }
        if (it.clicked) s.font_open[which] = !s.font_open[which];
        const names = if (s.font_open[which]) s.loadFontNames(c) else &[_][]const u8{};
        const p = kit.popover(c, if (which == 0) "font-ui" else "font-chat", &s.font_open[which], it.rect, .{ .placement = .bottom_start, .width = 280, .padding = 6 }) orelse return null;
        defer p.end();
        const list = ui.div(c).column().wFull().h(320).scrollY();
        defer list.end();
        if (s.fontRow(c, 0, default_label, current.len == 0)) chosen = "";
        for (names, 1..) |name, i| {
            if (s.fontRow(c, i, name, std.ascii.eqlIgnoreCase(name, current))) chosen = name;
        }
        if (chosen != null) s.font_open[which] = false;
        return chosen;
    }

    fn fontRow(s: *State, c: *ui.Context, i: usize, label: []const u8, selected: bool) bool {
        ui.key(c, c.print("font-{d}", .{i}));
        var row = ui.div(c).row().wFull().h(32).px(10).itemsCenter().rounded(8).control();
        if (selected) row = row.bg(s.pal.secondary_container);
        row = row.hover(if (selected) s.pal.secondary_container else c.theme.surface_hover);
        defer row.end();
        ui.text(c, label, .{ .size = 14, .truncate = .ellipsis });
        return row.clicked();
    }

    /// Remembers the window and sidebar sizes: saved once they stop changing
    fn trackLayout(s: *State, c: *ui.Context) void {
        const dir = s.layout_dir orelse return;
        // The window's own size (the view's is smaller by the title bar), the
        // same measure the next run opens with
        if (s.window) |w| {
            const size = w.contentSize();
            s.window_size = .{ @floatCast(size[0]), @floatCast(size[1]) };
        } else s.window_size = .{ c.size.w, c.size.h };
        const now = store.nowMs(s.io);
        if (s.layout().eql(s.layout_saved)) {
            s.layout_dirty_ms = 0;
            return;
        }
        if (s.layout_dirty_ms == 0) s.layout_dirty_ms = now;
        if (s.resizing or now - s.layout_dirty_ms < s.layout_settle_ms) {
            // No input may follow, so ask for another frame to check again
            if (s.window) |w| w.redraw();
            return;
        }
        s.saveLayout(dir);
    }

    /// Applies a saved sidebar width (ignored when out of range)
    pub fn restoreSidebar(s: *State, px: f32) void {
        if (px >= sidebar_min and px <= sidebar_max) s.sidebar_px = px;
    }

    fn layout(s: *const State) layout_mod.Layout {
        return .{ .sidebar = s.sidebar_px, .width = s.window_size[0], .height = s.window_size[1] };
    }

    fn saveLayout(s: *State, dir: []const u8) void {
        const now = s.layout();
        if (!now.hasWindow()) return;
        layout_mod.save(s.gpa, s.io, dir, now);
        s.layout_saved = now;
        s.layout_dirty_ms = 0;
    }

    /// Call as the app exits: writes a layout that changed in the last moments
    pub fn flushLayout(s: *State) void {
        const dir = s.layout_dir orelse return;
        if (!s.layout().eql(s.layout_saved)) s.saveLayout(dir);
    }

    fn pickInitial(s: *State) void {
        if (s.selected != null) return;
        if (s.preferred) |p| if (s.store.channel(p) != null) return s.select(p);
        if (s.store.last_selected.len > 0) if (s.store.channel(s.store.last_selected) != null) {
            const id = s.gpa.dupe(u8, s.store.last_selected) catch return;
            defer s.gpa.free(id);
            return s.select(id);
        };
        var best: ?*store.Channel = null;
        for (s.store.channels.items) |*c| {
            if (c.kind != .channel) continue;
            if (best == null or std.mem.lessThan(u8, c.name, best.?.name)) best = c;
        }
        if (best) |b| s.select(b.id);
    }

    fn sidebar(s: *State, c: *ui.Context) void {
        const col = ui.div(c).column().w(s.sidebar_px).hFull().bg(s.pal.container);
        defer col.end();
        {
            const head = ui.div(c).row().itemsCenter().wFull().h(64).px(24);
            defer head.end();
            ui.text(c, s.activeTeamName(), .{ .weight = .bold, .size = 18 });
        }
        const scroller = ui.div(c).column().wFull().grow().scrollY().px(12).pb(12);
        defer scroller.end();

        s.topRows(c);

        const st = s.store;
        var lists: [6]std.ArrayList(*store.Channel) = @splat(.empty);
        const starred = &lists[0];
        const above = &lists[1];
        const chans = &lists[2];
        const dms = &lists[3];
        const below = &lists[4];
        const apps = &lists[5];
        for (st.channels.items) |*ch| {
            const list = switch (ch.place) {
                .starred => starred,
                .above => above,
                .below => below,
                .none => if (ch.kind == .channel or ch.kind == .private) chans else if (st.isApp(ch)) apps else dms,
            };
            list.append(c.alloc(), ch) catch {};
        }
        const Ctx = struct {
            st: *store.Store,
            fn byName(x: @This(), a: *store.Channel, b: *store.Channel) bool {
                return std.ascii.lessThanIgnoreCase(x.st.channelName(a), x.st.channelName(b));
            }
            fn bySection(x: @This(), a: *store.Channel, b: *store.Channel) bool {
                if (a.section_rank != b.section_rank) return a.section_rank < b.section_rank;
                return byName(x, a, b);
            }
            fn byActivity(x: @This(), a: *store.Channel, b: *store.Channel) bool {
                const ta = if (a.activity.len > 0) a.activity else a.latest;
                const tb = if (b.activity.len > 0) b.activity else b.latest;
                if (!std.mem.eql(u8, ta, tb)) return store.tsLess(tb, ta);
                return byName(x, a, b);
            }
        };
        const ctx: Ctx = .{ .st = st };
        std.mem.sort(*store.Channel, starred.items, ctx, Ctx.byName);
        std.mem.sort(*store.Channel, above.items, ctx, Ctx.bySection);
        std.mem.sort(*store.Channel, chans.items, ctx, Ctx.byName);
        std.mem.sort(*store.Channel, dms.items, ctx, Ctx.byActivity);
        std.mem.sort(*store.Channel, below.items, ctx, Ctx.bySection);
        std.mem.sort(*store.Channel, apps.items, ctx, Ctx.byActivity);

        // Slack's order: Starred, the user's own sections, Channels, Direct messages, Apps
        if (s.anyNamed(starred.items)) {
            s.sectionHeader(c, "Starred");
            _ = s.sectionRows(c, starred.items, true);
        }
        s.customSections(c, above.items);
        s.sectionHeader(c, "Channels");
        const hidden_chans = s.sectionRows(c, chans.items, s.show_hidden_chans);
        if (hidden_chans > 0 or s.show_hidden_chans) s.hiddenToggle(c, &s.show_hidden_chans, hidden_chans);
        s.sectionHeader(c, "Direct messages");
        const hidden_dms = s.sectionRows(c, dms.items, s.show_hidden_dms);
        if (hidden_dms > 0 or s.show_hidden_dms) s.hiddenToggle(c, &s.show_hidden_dms, hidden_dms);
        s.customSections(c, below.items);
        if (s.anyNamed(apps.items)) {
            s.sectionHeader(c, "Apps");
            const hidden_apps = s.sectionRows(c, apps.items, s.show_hidden_apps);
            if (hidden_apps > 0 or s.show_hidden_apps) s.hiddenToggle(c, &s.show_hidden_apps, hidden_apps);
        }
    }

    /// Threads, Huddles, Drafts & sent and Saved
    fn topRows(s: *State, c: *ui.Context) void {
        inline for (.{ TopView.threads, TopView.huddles, TopView.drafts, TopView.saved }) |v| {
            const active = s.top_view == v;
            var row = ui.div(c).row().itemsCenter().gap(12).wFull().h(nav_h).px(16).control().roundedFull().circular();
            if (active) row = row.bg(s.pal.secondary_container);
            row = row.hover(if (active) s.pal.secondary_container else c.theme.surface_hover);
            defer row.end();
            if (row.clicked()) {
                s.top_view = v;
                s.settings_open = false;
            }
            const icon = ui.div(c).w(20).h(nav_h).center();
            ui.text(c, v.glyph(), .{ .size = 15 });
            icon.end();
            ui.text(c, v.label(), .{ .size = 15, .weight = if (active) .semibold else .regular, .color = if (active) c.theme.text else c.theme.muted });
        }
    }

    /// The page behind a top row. None of them has its own view yet.
    fn topPage(s: *State, c: *ui.Context) void {
        const col = ui.div(c).column().grow().hFull().bg(c.theme.background);
        defer col.end();
        {
            const bar = ui.div(c).row().itemsCenter().wFull().h(64).px(24);
            defer bar.end();
            ui.text(c, s.top_view.label(), .{ .weight = .semibold, .size = 18 });
        }
        ui.divider(c);
        s.centered(c, "Coming soon");
    }

    fn anyNamed(s: *State, list: []const *store.Channel) bool {
        for (list) |ch| if (s.store.channelName(ch).len > 0) return true;
        return false;
    }

    /// The user's own sections: `list` is sorted by section, one header each
    fn customSections(s: *State, c: *ui.Context, list: []const *store.Channel) void {
        var from: usize = 0;
        while (from < list.len) {
            var to = from + 1;
            while (to < list.len and list[to].section_rank == list[from].section_rank) to += 1;
            const group = list[from..to];
            if (s.anyNamed(group)) {
                s.sectionHeader(c, if (group[0].section.len > 0) group[0].section else "Section");
                _ = s.sectionRows(c, group, true);
            }
            from = to;
        }
    }

    /// Rows a section lists under the sidebar preference; returns how many it hid
    fn sectionRows(s: *State, c: *ui.Context, list: []const *store.Channel, show_all: bool) usize {
        var hidden: usize = 0;
        for (list) |ch| {
            const is_sel = if (s.selected) |id| std.mem.eql(u8, id, ch.id) else false;
            // Names still loading: show nothing rather than an ID
            if (s.store.channelName(ch).len == 0) continue;
            if (!(is_sel or show_all or s.store.shownInSidebar(ch))) {
                hidden += 1;
                continue;
            }
            s.channelRow(c, ch);
        }
        return hidden;
    }

    /// "Show 6 hidden" / "Show fewer" under a section
    fn hiddenToggle(s: *State, c: *ui.Context, flag: *bool, hidden: usize) void {
        const row = ui.div(c).row().itemsCenter().wFull().h(32).px(16).roundedFull().circular().control().hover(c.theme.surface_hover);
        defer row.end();
        if (row.clicked()) flag.* = !flag.*;
        const label = if (flag.*) "Show fewer" else c.print("Show {d} hidden", .{hidden});
        ui.text(c, label, .{ .size = 13, .weight = .semibold, .color = s.pal.link });
    }

    /// A strip between the sidebar and the messages: drag to resize
    fn resizeHandle(s: *State, c: *ui.Context) void {
        const handle = ui.div(c).w(handle_w).hFull().bg(c.theme.background);
        defer handle.end();
        const it = handle.interaction();
        if (it.hovered or it.pressed) {
            c.cursor = .resize_left_right;
            c.wants_moves = true;
        }
        if (it.pressed) {
            s.resizing = true;
            s.sidebar_px = std.math.clamp(c.input.mouse.x - rail_w - handle_w / 2, sidebar_min, sidebar_max);
        } else s.resizing = false;
        const line = if (it.hovered or it.pressed) s.pal.link else c.theme.border;
        const w: f32 = if (it.hovered or it.pressed) 2 else 1;
        ui.div(c).absolute().offset(0, 0).w(w).hFull().bg(line).end();
    }

    /// The shown workspace's name, before auth.test has said it too
    fn activeTeamName(s: *State) []const u8 {
        if (s.store.team_name.len > 0) return s.store.team_name;
        for (s.store.teams.items) |t| if (std.mem.eql(u8, t.id, s.store.active_team)) return t.name;
        return "Lax";
    }

    fn sectionHeader(_: *State, c: *ui.Context, label: []const u8) void {
        const h = ui.div(c).row().wFull().px(16).pt(20).pb(8);
        defer h.end();
        ui.text(c, label, .{ .size = 13, .weight = .semibold, .color = c.theme.muted });
    }

    fn channelRow(s: *State, c: *ui.Context, ch: *store.Channel) void {
        const is_sel = s.top_view == .none and (if (s.selected) |id| std.mem.eql(u8, id, ch.id) else false);
        var row = ui.div(c).row().itemsCenter().gap(12).wFull().h(nav_h).px(16).control().roundedFull().circular();
        if (is_sel) row = row.bg(s.pal.secondary_container);
        row = row.hover(if (is_sel) s.pal.secondary_container else c.theme.surface_hover);
        defer row.end();
        if (row.clicked()) s.pending_select = ch.id;

        const name = s.store.channelName(ch);
        const prefix: []const u8 = switch (ch.kind) {
            .channel => "#",
            .private => "🔒",
            .im => "●",
            .mpim => "👥",
        };
        const tone = if (ch.unread or is_sel) c.theme.text else c.theme.muted;
        const icon = ui.div(c).w(20).h(nav_h).center();
        if (ch.kind == .im) {
            const online = if (ch.user_id) |u| s.store.isOnline(u) else false;
            const dot = ui.div(c).w(10).h(10).roundedFull().circular();
            if (online) _ = dot.bg(c.theme.success) else _ = dot.border(c.theme.muted).borderW(1.5);
            dot.end();
        } else ui.text(c, prefix, .{ .size = if (ch.kind == .channel) 17 else 13, .color = tone });
        icon.end();
        const weight: ui.Weight = if (ch.unread) .bold else if (is_sel) .semibold else .regular;
        ui.text(c, if (name.len == 0) ch.id else name, .{ .size = 15, .weight = weight, .color = tone, .truncate = .ellipsis });
        ui.spacer(c);
        if (ch.mentions > 0) {
            const badge = ui.div(c).h(20).px(7).center().roundedFull().circular().bg(c.theme.accent);
            ui.textf(c, .{ .size = 12, .weight = .bold, .color = c.theme.accent_text }, "{d}", .{ch.mentions});
            badge.end();
        } else if (ch.unread) ui.div(c).w(8).h(8).roundedFull().circular().bg(c.theme.accent).end();
    }

    fn main(s: *State, c: *ui.Context) void {
        const col = ui.div(c).column().grow().hFull().bg(c.theme.background);
        defer col.end();
        s.topBar(c);
        ui.divider(c);
        if (s.cur) |cur| {
            if (cur.messages.items.len == 0 and !cur.history_loaded) {
                s.loading(c);
            } else if (cur.messages.items.len == 0) {
                s.centered(c, "No messages yet");
            } else s.drawList(c);
        } else if (s.store.channels.items.len == 0) {
            s.loading(c);
        } else s.centered(c, "Select a conversation");
        s.typingLine(c);
        s.composer(c);
    }

    fn loading(_: *State, c: *ui.Context) void {
        const box = ui.div(c).column().grow().wFull().center();
        defer box.end();
        kit.spinner(c, .{ .size = 28, .color = c.theme.muted });
    }

    fn centered(_: *State, c: *ui.Context, msg: []const u8) void {
        const box = ui.div(c).column().grow().wFull().center();
        defer box.end();
        ui.text(c, msg, .{ .color = c.theme.muted, .size = 15 });
    }

    fn topBar(s: *State, c: *ui.Context) void {
        const bar = ui.div(c).row().itemsCenter().gap(12).wFull().h(64).px(24);
        defer bar.end();
        if (s.cur) |cur| {
            const name = s.store.channelName(cur);
            ui.textf(c, .{ .weight = .semibold, .size = 18 }, "{s}{s}", .{ if (cur.kind == .channel or cur.kind == .private) "# " else "", name });
        }
        ui.spacer(c);
        const st = s.store;
        const color = switch (st.connection) {
            .online => c.theme.success,
            .connecting => c.theme.muted,
            .offline => c.theme.danger,
        };
        ui.div(c).w(8).h(8).roundedFull().circular().bg(color).end();
        if (st.status.len > 0) ui.text(c, st.status, .{ .size = 13, .color = c.theme.muted });
    }

    fn drawList(s: *State, c: *ui.Context) void {
        var rows = s.list.begin(c, s.source(), .{ .padding = .{ .top = 8, .bottom = 12 } }) catch return;
        while (rows.next()) |i| s.drawRow(c, i);
        rows.end();
        // Near the top with more on the server: ask for the page before
        const cur = s.cur.?;
        if (cur.has_older and !s.older_pending and s.list.top_index < 8 and cur.messages.items.len > 0) {
            s.older_pending = true;
            s.actions.older(s.actions.ctx, cur.id, cur.messages.items[0].ts);
        }
    }

    fn drawRow(s: *State, c: *ui.Context, i: usize) void {
        const cur = s.cur.?;
        s.drawMessage(c, &cur.messages.items[i], hasHeaderIn(cur.messages.items, i), s.list.height(i), cur.id, false);
    }

    /// One message: avatar, name and time, text, reactions, reply link, and
    /// a toolbar while the pointer is over it
    fn drawMessage(s: *State, c: *ui.Context, m: *const store.Message, head: bool, height: ?f32, channel_id: []const u8, in_thread: bool) void {
        var row = ui.div(c).row().wFull().px(row_px).pt(if (head) first_top else cont_top).pb(row_bottom).gap(avatar_gap).clip();
        if (height) |h| row = row.h(h);
        defer row.end();
        const row_it = row.interaction();
        const hovered = row_it.hovered;
        // The row only watches the pointer (for its toolbar): its own padding is not a button
        if (c.hot == row_it.id) c.cursor_hand = false;

        const author = if (m.user) |u| (s.store.userName(u) orelse u) else "unknown";
        if (head) {
            const av = ui.div(c).w(avatar_size).h(avatar_size).roundedFull().circular().bg(theme.avatarColor(s.pal, m.user orelse author)).center();
            ui.text(c, initialOf(c, author), .{ .size = 15, .weight = .semibold, .color = ui.Color.white });
            av.end();
        } else {
            ui.div(c).w(avatar_size).h(1).end();
        }

        {
            const col = ui.div(c).column().grow();
            defer col.end();
            if (head) {
                const line = ui.div(c).row().itemsCenter().gap(8);
                defer line.end();
                ui.text(c, author, s.nameStyle());
                var tm: Tm = undefined;
                const secs = tsSeconds(m.ts);
                if (localtime_r(&secs, &tm) != null) {
                    ui.textf(c, .{ .color = c.theme.muted, .size = time_style.size }, "{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(tm.hour)), @as(u32, @intCast(tm.min)) });
                }
            }
            const r = mrkdwn.render(c.alloc(), m.text, s.resolver()) catch mrkdwn.Rendered{ .text = m.text, .runs = &.{} };
            var start: usize = 0;
            while (true) {
                const nl = std.mem.indexOfScalarPos(u8, r.text, start, '\n') orelse r.text.len;
                s.drawParagraph(c, r, start, nl);
                if (nl >= r.text.len) break;
                start = nl + 1;
            }
            if (m.reactions.items.len > 0) s.reactionRow(c, m, channel_id);
            if (!in_thread and m.reply_count > 0) s.replyLink(c, m, channel_id);
        }

        if (hovered) if (row_it.rect) |rect| s.toolbar(c, rect, m, channel_id, in_thread);
    }

    fn reactionRow(s: *State, c: *ui.Context, m: *const store.Message, channel_id: []const u8) void {
        const line = ui.div(c).row().itemsCenter().gap(6).h(reaction_row_h).pt(4);
        defer line.end();
        for (m.reactions.items) |r| {
            var buf: [48]u8 = undefined;
            const label = if (slack.emoji.forReaction(&buf, r.name)) |glyph| c.print("{s} {d}", .{ glyph, r.count }) else c.print(":{s}: {d}", .{ r.name, r.count });
            var pill = ui.div(c).row().itemsCenter().h(26).px(10).roundedFull().circular().control();
            pill = pill.bg(if (r.mine) s.pal.primary_container else s.pal.container_high);
            if (r.mine) pill = pill.border(s.pal.link).borderW(1);
            pill = pill.hover(if (r.mine) s.pal.primary_container else c.theme.surface_hover);
            defer pill.end();
            if (pill.clicked()) s.actions.react(s.actions.ctx, channel_id, m.ts, r.name, !r.mine);
            ui.text(c, label, .{ .size = 13, .color = if (r.mine) s.pal.on_primary_container else c.theme.text });
        }
    }

    fn replyLink(s: *State, c: *ui.Context, m: *const store.Message, channel_id: []const u8) void {
        const line = ui.div(c).row().itemsCenter().h(reply_row_h).control();
        defer line.end();
        if (line.clicked()) s.openThread(channel_id, m.ts);
        ui.text(c, c.print("{d} {s}", .{ m.reply_count, if (m.reply_count == 1) "reply" else "replies" }), .{ .size = 13, .weight = .semibold, .color = s.pal.link });
    }

    fn openThread(s: *State, channel_id: []const u8, ts: []const u8) void {
        s.store.showThread(channel_id, ts) catch return;
        s.thread_composer.clear();
        s.actions.open_thread(s.actions.ctx, channel_id, ts);
    }

    /// Quick reactions and Reply, on a layer over the messages at the row's
    /// top right (a row clips what it holds, and a short row is shorter than
    /// the bar)
    fn toolbar(s: *State, c: *ui.Context, rect: ui.Rect, m: *const store.Message, channel_id: []const u8, in_thread: bool) void {
        const bar_w: f32 = 28 * quick_reactions.len + (if (in_thread) @as(f32, 0) else 64) + 12;
        const x = @max(rect.x, rect.x + rect.w - bar_w - 16);
        const y = @max(4, rect.y - 12);
        const bar = ui.div(c).row().fixed().offset(x, y).layer(20).w(bar_w).h(32).itemsCenter().justifyCenter().gap(2).rounded(16).bg(s.pal.container_high).border(c.theme.border).borderW(1).shadow(.{ .color = c.theme.border.alpha(0.6), .blur = 8, .y = 2 });
        defer bar.end();
        for (quick_reactions) |name| {
            const glyph = slack.emoji.lookup(name) orelse continue;
            const btn = ui.div(c).w(28).h(28).center().roundedFull().circular().control().hover(c.theme.surface_hover);
            defer btn.end();
            if (btn.clicked()) s.actions.react(s.actions.ctx, channel_id, m.ts, name, !hasMine(m, name));
            ui.text(c, glyph, .{ .size = 16 });
        }
        if (!in_thread) {
            const btn = ui.div(c).h(28).px(10).center().roundedFull().circular().control().hover(c.theme.surface_hover);
            defer btn.end();
            if (btn.clicked()) s.openThread(channel_id, m.ts);
            ui.text(c, "Reply", .{ .size = 13, .weight = .semibold, .color = s.pal.link });
        }
    }

    fn hasMine(m: *const store.Message, name: []const u8) bool {
        for (m.reactions.items) |r| if (std.mem.eql(u8, r.name, name)) return r.mine;
        return false;
    }

    fn threadPanel(s: *State, c: *ui.Context) void {
        const t = &s.store.thread.?;
        const col = ui.div(c).column().w(thread_w).hFull().bg(c.theme.background);
        defer col.end();
        {
            const head = ui.div(c).row().itemsCenter().wFull().h(64).px(20);
            defer head.end();
            ui.text(c, "Thread", .{ .size = 18, .weight = .semibold });
            ui.spacer(c);
            const close = ui.div(c).w(32).h(32).center().roundedFull().circular().control().hover(c.theme.surface_hover);
            defer close.end();
            if (close.clicked()) s.close_thread = true;
            ui.text(c, "✕", .{ .size = 14, .color = c.theme.muted });
        }
        ui.divider(c);
        if (!t.loaded) {
            s.loading(c);
        } else {
            _ = c.open(.{ .direction = .column, .width = .fill, .grow = 1, .scroll = true, .follow_end = true, .selectable = true, .padding = .{ .top = 8, .bottom = 12 } }, null);
            for (t.messages.items, 0..) |*m, i| s.drawMessage(c, m, hasHeaderIn(t.messages.items, i), null, t.channel, true);
            c.end();
        }
        const bar = ui.div(c).row().wFull().px(16).py(12);
        defer bar.end();
        const res = s.thread_composer.view(c, s.store, s.pal, .{ .placeholder = "Reply…", .max_lines = 6 });
        if (res.submitted) |text| {
            s.actions.send(s.actions.ctx, t.channel, text, t.ts);
            s.thread_composer.clear();
        }
    }

    fn drawParagraph(s: *State, c: *ui.Context, r: mrkdwn.Rendered, start: usize, end: usize) void {
        const text = if (end == start) " " else r.text[start..end];
        var spans: std.ArrayList(ui.Span) = .empty;
        var links: std.ArrayList(LinkSpan) = .empty;
        const t = c.theme;
        for (r.runs) |run| {
            if (run.end <= start or run.start >= end) continue;
            const a: u32 = @intCast(@max(run.start, start) - start);
            const b: u32 = @intCast(@min(run.end, end) - start);
            const span: ui.Span = switch (run.style) {
                .bold => .{ .start = a, .end = b, .weight = .bold },
                .italic => .{ .start = a, .end = b, .italic = true },
                .strike => .{ .start = a, .end = b, .strike = true },
                .code => .{ .start = a, .end = b, .mono = true, .background = s.pal.container_high, .color = t.danger },
                .code_block => .{ .start = a, .end = b, .mono = true, .background = s.pal.container_high },
                .link => blk: {
                    links.append(c.alloc(), .{ .start = a, .end = b, .target = run.target }) catch {};
                    break :blk .{ .start = a, .end = b, .color = s.pal.link, .underline = true };
                },
                .mention => .{ .start = a, .end = b, .color = s.pal.link, .weight = .semibold, .background = s.pal.primary_container.alpha(0.5) },
                .quote => .{ .start = a, .end = b, .color = t.muted },
            };
            spans.append(c.alloc(), span) catch {};
        }
        const idx = c.leaf(.{ .width = .fill }, .{ .text = .{ .str = text, .style = s.bodyStyle(), .color = t.text, .spans = spans.items } }, null);
        if (links.items.len > 0) s.linkInteraction(c, idx, text, links.items);
    }

    /// Hand cursor over links, and a click opens them. The text leaf has no
    /// notion of links, so find them from the wrapped lines.
    fn linkInteraction(s: *State, c: *ui.Context, idx: u32, text: []const u8, links: []const LinkSpan) void {
        // Moves must draw frames so the cursor follows the pointer
        c.wants_moves = true;
        const it = c.interact(idx, .{});
        const rect = it.rect orelse return;
        const m = c.input.mouse;
        if (!rect.contains(m)) return;
        const lh = lineHeight(c, s.bodyStyle());
        // The text system's lines are its cache's: copy before measuring again
        const wrapped = c.text.wrap(text, s.bodyStyle(), rect.w);
        const lines = c.alloc().dupe(@TypeOf(wrapped[0]), wrapped) catch return;
        for (lines, 0..) |line, li| {
            const y0 = rect.y + @as(f32, @floatFromInt(li)) * lh;
            if (m.y < y0 or m.y >= y0 + lh) continue;
            for (links) |l| {
                const a = @max(l.start, line.start);
                const b = @min(l.end, line.end);
                if (a >= b) continue;
                const x0 = rect.x + c.text.caretX(text[line.start..line.end], s.bodyStyle(), a - line.start);
                const x1 = rect.x + c.text.caretX(text[line.start..line.end], s.bodyStyle(), b - line.start);
                if (m.x >= x0 and m.x < x1) {
                    c.cursor = .hand;
                    if (it.clicked) s.opener(s.gpa, s.io, l.target);
                    return;
                }
            }
        }
    }

    fn composer(s: *State, c: *ui.Context) void {
        const bar = ui.div(c).row().wFull().px(20).pb(16);
        defer bar.end();
        const placeholder = if (s.cur) |cur| c.print("Message {s}{s}", .{ if (cur.kind == .channel or cur.kind == .private) "#" else "", s.store.channelName(cur) }) else "Message";
        const lines: u8 = if (s.composer_expanded) composer_tall_lines else composer_lines;
        const res = s.main_composer.view(c, s.store, s.pal, .{ .placeholder = placeholder, .min_lines = lines, .max_lines = lines });
        if (res.rect) |rect| s.expandToggle(c, rect);
        if (res.changed and s.main_composer.text().len > 0) s.signalTyping();
        if (res.submitted) |text| {
            if (s.selected) |id| {
                s.actions.send(s.actions.ctx, id, text, null);
                s.list.stickToEnd();
            }
            s.main_composer.clear();
        }
    }

    /// A small button on the message box's top border: 2 lines or 10
    fn expandToggle(s: *State, c: *ui.Context, rect: ui.Rect) void {
        const w: f32 = 32;
        const h: f32 = 20;
        const btn = ui.div(c).fixed().offset(rect.x + rect.w - w - 14, rect.y - h / 2).layer(20).w(w).h(h).center().roundedFull().circular().control().bg(s.pal.container_high).border(c.theme.border).borderW(1).hover(c.theme.surface_hover);
        defer btn.end();
        if (btn.clicked()) s.composer_expanded = !s.composer_expanded;
        ui.text(c, if (s.composer_expanded) "▾" else "▴", .{ .size = 12, .color = c.theme.muted });
    }

    /// Tells Slack we are typing, at most every few seconds
    fn signalTyping(s: *State) void {
        const id = s.selected orelse return;
        const now = store.nowMs(s.io);
        if (now - s.last_typing_ms < typing_send_ms) return;
        s.last_typing_ms = now;
        s.actions.typing(s.actions.ctx, id);
    }

    /// "Grace is typing…" above the composer
    fn typingLine(s: *State, c: *ui.Context) void {
        const row = ui.div(c).row().wFull().h(typing_h).px(24).itemsCenter();
        defer row.end();
        const cur = s.cur orelse return;
        var names: [3][]const u8 = undefined;
        const n = s.store.typingNow(cur, store.nowMs(s.io), &names);
        if (n == 0) return;
        // Look again when the oldest indicator would expire
        c.frameIn(1.0);
        const text = switch (n) {
            1 => c.print("{s} is typing…", .{names[0]}),
            2 => c.print("{s} and {s} are typing…", .{ names[0], names[1] }),
            else => "Several people are typing…",
        };
        ui.text(c, text, .{ .size = 13, .color = c.theme.muted, .italic = true });
    }
};
