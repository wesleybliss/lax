//! The menu a right-click on a sidebar row opens, and the two dialogs it
//! can lead to (a new section's name, leaving a channel). This holds which
//! conversation it is for and what is open, draws it, and says what was
//! chosen; the caller acts on that.
const std = @import("std");
const nanoui = @import("nanoui");
const kit = nanoui.kit;
const store = @import("store");
const ui = nanoui.ui;
const theme = @import("theme.zig");

const menu_w: f32 = 250;
const max_items = 20;

pub const Choice = union(enum) {
    copy_name,
    copy_link,
    /// The conversation's id, from the details dialog
    copy_id,
    star,
    unstar,
    /// The name of the section to make
    new_section: []const u8,
    close,
    leave,
    notify_all,
    notify_mentions,
    mute,
    unmute,
    /// The details dialog was opened: load them
    details,
    /// The query to search the conversation for, in Slack's syntax
    search: []const u8,
};

/// What the menu needs to know about its conversation
pub const Info = struct {
    store: *const store.Store,
    /// Draws one search result
    results: ResultDrawer,
    /// The conversation's id, and the user it is with (a DM)
    id: []const u8,
    user_id: ?[]const u8,
    kind: store.Kind,
    name: []const u8,
    starred: bool,
    muted: bool,
    mode: store.NotifyMode,
};

/// How the caller draws one found message in the search dialog
pub const ResultDrawer = struct {
    ctx: *anyopaque,
    draw: *const fn (ctx: *anyopaque, c: *ui.Context, entry: *const store.FeedEntry) void,
};

/// The entries, in the order they are listed
const Entry = enum { details, search, copy_name, copy_link, star, new_section, notify_all, notify_mentions, mute, close, leave };

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

pub const Menu = struct {
    id_buf: [32]u8 = undefined,
    id_len: u8 = 0,
    anchor: ?ui.Rect = null,
    open: bool = false,
    section_open: bool = false,
    leave_open: bool = false,
    details_open: bool = false,
    search_open: bool = false,
    name: ui.TextBuffer = .{},
    query: ui.TextBuffer = .{},
    /// The query last sent, as Slack gets it (it names the conversation too)
    asked_buf: [256]u8 = undefined,
    asked_len: u8 = 0,

    pub fn deinit(m: *Menu) void {
        m.name.deinit();
        m.query.deinit();
    }

    fn asked(m: *const Menu) []const u8 {
        return m.asked_buf[0..m.asked_len];
    }

    /// The conversation it is for
    pub fn channel(m: *const Menu) []const u8 {
        return m.id_buf[0..m.id_len];
    }

    pub fn anyOpen(m: *const Menu) bool {
        return m.open or m.section_open or m.leave_open or m.details_open or m.search_open;
    }

    pub fn closeAll(m: *Menu) void {
        m.open = false;
        m.section_open = false;
        m.leave_open = false;
        m.details_open = false;
        m.search_open = false;
    }

    /// Opens the menu for a conversation, at the pointer
    pub fn show(m: *Menu, channel_id: []const u8, x: f32, y: f32) void {
        m.closeAll();
        m.id_len = @intCast(@min(channel_id.len, m.id_buf.len));
        @memcpy(m.id_buf[0..m.id_len], channel_id[0..m.id_len]);
        m.anchor = .{ .x = x, .y = y, .w = 1, .h = 1 };
        m.open = true;
    }

    /// Draws whatever is open (last in the frame, over everything)
    pub fn draw(m: *Menu, c: *ui.Context, info: Info) ?Choice {
        var chosen: ?Choice = null;
        if (m.list(c, info)) |choice| chosen = choice;
        if (m.sectionDialog(c)) |name| chosen = .{ .new_section = name };
        if (m.leaveDialog(c, info)) chosen = .leave;
        if (m.detailsDialog(c, info)) |choice| chosen = choice;
        if (m.searchDialog(c, info)) |q| chosen = .{ .search = q };
        return chosen;
    }

    fn isChannel(info: Info) bool {
        return info.kind == .channel or info.kind == .private;
    }

    fn list(m: *Menu, c: *ui.Context, info: Info) ?Choice {
        const noun: []const u8 = if (isChannel(info)) "channel" else "conversation";
        var items: [max_items]kit.MenuItem = undefined;
        var entries: [max_items]?Entry = undefined;
        var n: usize = 0;
        const add = struct {
            fn one(its: *[max_items]kit.MenuItem, es: *[max_items]?Entry, count: *usize, item: kit.MenuItem, entry: ?Entry) void {
                its[count.*] = item;
                es[count.*] = entry;
                count.* += 1;
            }
        }.one;

        add(&items, &entries, &n, .{ .label = "Conversation details", .disabled = true }, null);
        add(&items, &entries, &n, .{ .label = "View conversation details" }, .details);
        add(&items, &entries, &n, .{ .label = "Search in conversation" }, .search);
        add(&items, &entries, &n, .{ .separator = true }, null);
        add(&items, &entries, &n, .{ .label = "Copy name" }, .copy_name);
        add(&items, &entries, &n, .{ .label = "Copy link" }, .copy_link);
        add(&items, &entries, &n, .{ .label = c.print("{s} {s}", .{ if (info.starred) "Unstar" else "Star", noun }) }, .star);
        add(&items, &entries, &n, .{ .label = "Move to new section" }, .new_section);
        add(&items, &entries, &n, .{ .separator = true }, null);
        if (isChannel(info)) {
            add(&items, &entries, &n, .{ .label = "Notify you about…", .disabled = true }, null);
            add(&items, &entries, &n, .{ .label = "All new posts", .checked = !info.muted and info.mode == .everything }, .notify_all);
            add(&items, &entries, &n, .{ .label = "Just mentions", .checked = !info.muted and info.mode != .everything }, .notify_mentions);
            add(&items, &entries, &n, .{ .label = "Mute channel", .checked = info.muted }, .mute);
            add(&items, &entries, &n, .{ .separator = true }, null);
            add(&items, &entries, &n, .{ .label = "Leave channel", .danger = true }, .leave);
        } else {
            add(&items, &entries, &n, .{ .label = "Close conversation", .danger = true }, .close);
        }

        const idx = kit.menu(c, "channel-menu", &m.open, m.anchor, items[0..n], .{ .placement = .bottom_start, .width = menu_w }) orelse return null;
        const entry = entries[idx] orelse return null;
        return switch (entry) {
            .details => blk: {
                m.details_open = true;
                break :blk .details;
            },
            .search => blk: {
                m.query.clear();
                m.query.focus();
                m.asked_len = 0;
                m.search_open = true;
                break :blk null;
            },
            .copy_name => .copy_name,
            .copy_link => .copy_link,
            .star => if (info.starred) .unstar else .star,
            .new_section => blk: {
                m.name.clear();
                m.name.focus();
                m.section_open = true;
                break :blk null;
            },
            .notify_all => .notify_all,
            .notify_mentions => .notify_mentions,
            .mute => if (info.muted) .unmute else .mute,
            .close => .close,
            .leave => blk: {
                m.leave_open = true;
                break :blk null;
            },
        };
    }

    /// The name typed for a new section, once OK is pressed with one
    fn sectionDialog(m: *Menu, c: *ui.Context) ?[]const u8 {
        const d = kit.dialog(c, "new-section", &m.section_open, .{
            .title = "Move to new section",
            .description = "Name the section this conversation goes in.",
            .ok = "Create",
            .width = 420,
        }) orelse return null;
        _ = ui.textField(c, &m.name, .{ .caret_color = theme.caretColor(c.theme.dark), .placeholder = "Section name", .width = .fill, .size = 14 });
        if (d.end() != .ok) return null;
        const name = std.mem.trim(u8, m.name.text(), " ");
        return if (name.len > 0) name else null;
    }

    fn leaveDialog(m: *Menu, c: *ui.Context, info: Info) bool {
        const d = kit.dialog(c, "leave-channel", &m.leave_open, .{
            .title = c.print("Leave #{s}?", .{info.name}),
            .description = if (info.kind == .private)
                "This is a private channel: you can only join it again if someone invites you."
            else
                "You can join it again later from the channel list.",
            .ok = "Leave channel",
            .ok_variant = .danger,
            .width = 420,
        }) orelse return false;
        return d.end() == .ok;
    }

    /// What is known of the conversation, once Slack has said it
    fn detailsDialog(m: *Menu, c: *ui.Context, info: Info) ?Choice {
        const d = kit.dialog(c, "conversation-details", &m.details_open, .{
            .title = if (isChannel(info)) c.print("#{s}", .{info.name}) else info.name,
            .ok = "",
            .cancel = "Close",
            .width = 460,
        }) orelse return null;
        defer _ = d.end();
        var chosen: ?Choice = null;
        {
            const row = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer row.end();
            const words = ui.div(c).column().grow().gap(2);
            ui.text(c, "ID", .{ .size = 12, .weight = .semibold, .color = c.theme.muted });
            ui.text(c, info.id, .{ .size = 14 });
            words.end();
            if (kit.button(c, "Copy", .{ .size = .sm, .variant = .outline }).clicked) chosen = .copy_id;
        }
        const held = info.store.details;
        const loaded = held != null and std.mem.eql(u8, held.?.channel, info.id);
        if (!loaded) {
            ui.text(c, "Loading…", .{ .size = 13, .color = c.theme.muted });
            return chosen;
        }
        const x = held.?;
        if (info.kind == .im) {
            detailRow(c, "Title", x.topic);
            detailRow(c, "Status", info.store.statusText(info.user_id orelse ""));
            detailRow(c, "Time zone", x.timezone);
            return chosen;
        }
        detailRow(c, "Topic", x.topic);
        detailRow(c, "Description", x.purpose);
        if (x.members > 0) detailRow(c, "Members", c.print("{d}", .{x.members}));
        if (x.created > 0) {
            const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(x.created) };
            const day = epoch.getEpochDay().calculateYearDay();
            const month = day.calculateMonthDay();
            const by = if (x.creator.len > 0) info.store.userName(x.creator) orelse "" else "";
            detailRow(c, "Created", c.print("{s} {d}, {d}{s}{s}", .{
                months[month.month.numeric() - 1],
                month.day_index + 1,
                day.year,
                if (by.len > 0) " by " else "",
                by,
            }));
        }
        return chosen;
    }

    fn detailRow(c: *ui.Context, label: []const u8, value: []const u8) void {
        if (value.len == 0) return;
        const row = ui.div(c).column().wFull().gap(2);
        defer row.end();
        ui.text(c, label, .{ .size = 12, .weight = .semibold, .color = c.theme.muted });
        ui.text(c, value, .{ .size = 14, .wrap = true });
    }

    /// The text to search for, in Slack's syntax, once it is sent; the dialog stays up for the results
    fn searchDialog(m: *Menu, c: *ui.Context, info: Info) ?[]const u8 {
        const d = kit.dialog(c, "conversation-search", &m.search_open, .{
            .title = c.print("Search {s}{s}", .{ if (isChannel(info)) "#" else "", info.name }),
            .ok = "",
            .cancel = "",
            .width = 520,
        }) orelse return null;
        defer _ = d.end();
        var sent: ?[]const u8 = null;
        {
            const row = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer row.end();
            const res = ui.textField(c, &m.query, .{ .caret_color = theme.caretColor(c.theme.dark), .placeholder = "Search messages", .width = .fill, .size = 14 });
            const go = kit.button(c, "Search", .{});
            const text = std.mem.trim(u8, m.query.text(), " ");
            if ((go.clicked or res.submitted) and text.len > 0) sent = m.scoped(c, info, text);
        }
        const found = &info.store.found;
        if (m.asked().len == 0) return sent;
        if (!found.feed.loaded or !std.mem.eql(u8, found.query, m.asked())) {
            ui.text(c, "Searching…", .{ .size = 13, .color = c.theme.muted });
            return sent;
        }
        if (found.feed.entries.items.len == 0) {
            ui.text(c, "Nothing found", .{ .size = 13, .color = c.theme.muted });
            return sent;
        }
        const scroller = ui.div(c).column().wFull().maxH(360).scrollY().gap(10);
        defer scroller.end();
        for (found.feed.entries.items) |*e| {
            const card = ui.div(c).column().wFull().gap(2);
            defer card.end();
            info.results.draw(info.results.ctx, c, e);
        }
        return sent;
    }

    /// `text` limited to this conversation, remembered as what the answer is matched to
    fn scoped(m: *Menu, c: *ui.Context, info: Info, text: []const u8) ?[]const u8 {
        const query = if (info.user_id) |uid|
            c.print("in:<@{s}> {s}", .{ uid, text })
        else
            c.print("in:<#{s}> {s}", .{ info.id, text });
        if (query.len > m.asked_buf.len) return null;
        @memcpy(m.asked_buf[0..query.len], query);
        m.asked_len = @intCast(query.len);
        return query;
    }
};
