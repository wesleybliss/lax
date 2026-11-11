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
const max_items = 16;

pub const Choice = union(enum) {
    copy_name,
    copy_link,
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
};

/// What the menu needs to know about its conversation
pub const Info = struct {
    kind: store.Kind,
    name: []const u8,
    starred: bool,
    muted: bool,
    mode: store.NotifyMode,
};

/// The entries, in the order they are listed
const Entry = enum { copy_name, copy_link, star, new_section, notify_all, notify_mentions, mute, close, leave };

pub const Menu = struct {
    id_buf: [32]u8 = undefined,
    id_len: u8 = 0,
    anchor: ?ui.Rect = null,
    open: bool = false,
    section_open: bool = false,
    leave_open: bool = false,
    name: ui.TextBuffer = .{},

    pub fn deinit(m: *Menu) void {
        m.name.deinit();
    }

    /// The conversation it is for
    pub fn channel(m: *const Menu) []const u8 {
        return m.id_buf[0..m.id_len];
    }

    pub fn anyOpen(m: *const Menu) bool {
        return m.open or m.section_open or m.leave_open;
    }

    pub fn closeAll(m: *Menu) void {
        m.open = false;
        m.section_open = false;
        m.leave_open = false;
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
};
