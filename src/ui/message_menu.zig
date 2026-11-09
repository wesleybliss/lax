//! What a message's hover toolbar opens: the emoji picker, the overflow
//! menu, the forward list and the delete confirmation. This holds which one
//! is open and for what message, draws it, and says what was chosen; the
//! caller acts on that.
const std = @import("std");
const nanoui = @import("nanoui");
const kit = nanoui.kit;
const slack = @import("slack");
const store = @import("store");
const ui = nanoui.ui;
const theme = @import("theme.zig");

const cols = 8;
const cell: f32 = 36;
const picker_rows_h: f32 = 252;
const picker_w: f32 = cols * cell + 30;
const forward_w: f32 = 320;
const forward_row_h: f32 = 34;
const forward_max_rows = 120;
const picker_hits_max = 240;

/// The message a popup is for, held by value: the list may change under it
pub const Target = struct {
    channel_buf: [32]u8 = undefined,
    channel_len: u8 = 0,
    ts_buf: [32]u8 = undefined,
    ts_len: u8 = 0,
    in_thread: bool = false,

    pub fn make(channel_id: []const u8, message_ts: []const u8, in_thread: bool) Target {
        var t: Target = .{ .in_thread = in_thread };
        t.channel_len = @intCast(@min(channel_id.len, t.channel_buf.len));
        @memcpy(t.channel_buf[0..t.channel_len], channel_id[0..t.channel_len]);
        t.ts_len = @intCast(@min(message_ts.len, t.ts_buf.len));
        @memcpy(t.ts_buf[0..t.ts_len], message_ts[0..t.ts_len]);
        return t;
    }

    pub fn channel(t: *const Target) []const u8 {
        return t.channel_buf[0..t.channel_len];
    }

    pub fn ts(t: *const Target) []const u8 {
        return t.ts_buf[0..t.ts_len];
    }

    pub fn is(t: *const Target, channel_id: []const u8, message_ts: []const u8, in_thread: bool) bool {
        return t.in_thread == in_thread and std.mem.eql(u8, t.channel(), channel_id) and std.mem.eql(u8, t.ts(), message_ts);
    }
};

pub const Which = enum { picker, menu, forward, confirm_delete };

/// The overflow menu's entries
pub const Action = enum { edit, mark_unread, save, copy_link, copy_text, delete };

pub const Choice = union(enum) {
    /// An emoji's shortcode, from the picker
    react: []const u8,
    /// A conversation id, from the forward list
    forward: []const u8,
    action: Action,
    confirm_delete,
};

/// What the popups need to know about their message
pub const Info = struct {
    /// Written by us: it can be edited and deleted
    own: bool,
    /// The start of its text, for the delete confirmation
    preview: []const u8,
};

pub const Menu = struct {
    gpa: std.mem.Allocator,
    target: Target = .{},
    anchor: ?ui.Rect = null,
    picker_open: bool = false,
    menu_open: bool = false,
    forward_open: bool = false,
    delete_open: bool = false,
    query: ui.TextBuffer = .{},
    forward_query: ui.TextBuffer = .{},
    /// Indexes into `slack.emoji.entries`, one per glyph (found on first use)
    unique: []u16 = &.{},

    pub fn init(gpa: std.mem.Allocator) Menu {
        return .{ .gpa = gpa };
    }

    pub fn deinit(m: *Menu) void {
        m.query.deinit();
        m.forward_query.deinit();
        m.gpa.free(m.unique);
    }

    /// Opens one popup for `target`, by `anchor` (the button), and closes the others
    pub fn show(m: *Menu, which: Which, target: Target, anchor: ?ui.Rect) void {
        m.closeAll();
        m.target = target;
        m.anchor = anchor;
        switch (which) {
            .picker => {
                m.picker_open = true;
                m.query.clear();
                m.query.focus();
            },
            .menu => m.menu_open = true,
            .forward => {
                m.forward_open = true;
                m.forward_query.clear();
                m.forward_query.focus();
            },
            .confirm_delete => m.delete_open = true,
        }
    }

    pub fn closeAll(m: *Menu) void {
        m.picker_open = false;
        m.menu_open = false;
        m.forward_open = false;
        m.delete_open = false;
    }

    pub fn isOpen(m: *const Menu, which: Which, target: Target) bool {
        const open = switch (which) {
            .picker => m.picker_open,
            .menu => m.menu_open,
            .forward => m.forward_open,
            .confirm_delete => m.delete_open,
        };
        return open and m.target.is(target.channel(), target.ts(), target.in_thread);
    }

    pub fn anyOpen(m: *const Menu) bool {
        return m.picker_open or m.menu_open or m.forward_open or m.delete_open;
    }

    /// A popup by the toolbar is open for this message: its toolbar stays
    /// up while the pointer is in the popup
    pub fn holdsToolbar(m: *const Menu, channel_id: []const u8, message_ts: []const u8, in_thread: bool) bool {
        return (m.picker_open or m.menu_open or m.forward_open) and m.target.is(channel_id, message_ts, in_thread);
    }

    /// Draws whatever is open (last in the frame, over everything)
    pub fn draw(m: *Menu, c: *ui.Context, st: *const store.Store, pal: theme.Palette, info: Info) ?Choice {
        var chosen: ?Choice = null;
        if (m.picker(c)) |name| chosen = .{ .react = name };
        if (m.overflow(c, info)) |a| chosen = .{ .action = a };
        if (m.forwardList(c, st)) |id| chosen = .{ .forward = id };
        if (m.confirm(c, pal, info)) chosen = .confirm_delete;
        return chosen;
    }

    // Emoji picker

    fn ensureUnique(m: *Menu) void {
        if (m.unique.len > 0) return;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(m.gpa);
        var out: std.ArrayList(u16) = .empty;
        // Faces and gestures lead, as in Slack's picker; the rest stay alphabetical
        for ([_]bool{ true, false }) |faces| {
            seen.clearRetainingCapacity();
            for (slack.emoji.entries, 0..) |e, i| {
                if (isFace(e.glyph) != faces) continue;
                const fresh = seen.getOrPut(m.gpa, e.glyph) catch return;
                if (fresh.found_existing) continue;
                out.append(m.gpa, @intCast(i)) catch return;
            }
        }
        m.unique = out.toOwnedSlice(m.gpa) catch &.{};
    }

    /// The emoji to show for `query`: everything, one per glyph, or the
    /// names that contain it
    fn pickerHits(m: *Menu, arena: std.mem.Allocator, query: []const u8) []const u16 {
        if (query.len == 0) return m.unique;
        var out: std.ArrayList(u16) = .empty;
        for (slack.emoji.entries, 0..) |e, i| {
            if (out.items.len >= picker_hits_max) break;
            if (!containsIgnoreCase(e.name, query)) continue;
            // An alias of one already listed
            const dup = for (out.items) |j| {
                if (std.mem.eql(u8, slack.emoji.entries[j].glyph, e.glyph)) break true;
            } else false;
            if (dup) continue;
            out.append(arena, @intCast(i)) catch break;
        }
        return out.items;
    }

    fn picker(m: *Menu, c: *ui.Context) ?[]const u8 {
        if (m.picker_open) m.ensureUnique();
        const p = kit.popover(c, "emoji-picker", &m.picker_open, m.anchor, .{ .placement = .bottom_end, .width = picker_w, .padding = 8, .gap = 6 }) orelse return null;
        defer p.end();
        _ = ui.textField(c, &m.query, .{ .caret_color = theme.caretColor(c.theme.dark), .placeholder = "Search emoji", .width = .fill, .size = 14 });
        const hits = m.pickerHits(c.alloc(), std.mem.trim(u8, m.query.text(), " :"));
        var chosen: ?[]const u8 = null;
        var hovered: ?[]const u8 = null;
        if (hits.len == 0) {
            const box = ui.div(c).wFull().h(picker_rows_h).center();
            defer box.end();
            ui.text(c, "No emoji found", .{ .size = 14, .color = c.theme.muted });
        } else {
            var rows = ui.list(c, .{ .count = (hits.len + cols - 1) / cols, .row_height = cell, .height = .{ .px = picker_rows_h } });
            while (rows.next()) |r| {
                const row = ui.div(c).row().wFull().h(cell);
                defer row.end();
                for (0..cols) |k| {
                    const at = r * cols + k;
                    if (at >= hits.len) break;
                    const e = slack.emoji.entries[hits[at]];
                    ui.key(c, c.print("e{d}", .{k}));
                    const btn = ui.div(c).w(cell).h(cell).center().rounded(8).control().hover(c.theme.surface_hover);
                    defer btn.end();
                    const it = btn.interaction();
                    if (it.hovered) hovered = e.name;
                    if (it.clicked) chosen = e.name;
                    ui.text(c, e.glyph, .{ .size = 22 });
                }
            }
            rows.end();
        }
        const foot = ui.div(c).row().wFull().h(22).px(6).itemsCenter();
        defer foot.end();
        if (hovered) |name| ui.text(c, c.print(":{s}:", .{name}), .{ .size = 13, .color = c.theme.muted, .truncate = .ellipsis });
        if (chosen != null) m.picker_open = false;
        return chosen;
    }

    // Overflow menu

    fn overflow(m: *Menu, c: *ui.Context, info: Info) ?Action {
        var items: [9]kit.MenuItem = undefined;
        var actions: [9]?Action = undefined;
        var n: usize = 0;
        const add = struct {
            fn one(its: *[9]kit.MenuItem, acts: *[9]?Action, count: *usize, item: kit.MenuItem, action: ?Action) void {
                its[count.*] = item;
                acts[count.*] = action;
                count.* += 1;
            }
        }.one;
        if (info.own) {
            add(&items, &actions, &n, .{ .label = "Edit message" }, .edit);
            add(&items, &actions, &n, .{ .separator = true }, null);
        }
        if (!m.target.in_thread) add(&items, &actions, &n, .{ .label = "Mark unread" }, .mark_unread);
        add(&items, &actions, &n, .{ .label = "Add to saved" }, .save);
        add(&items, &actions, &n, .{ .separator = true }, null);
        add(&items, &actions, &n, .{ .label = "Copy link" }, .copy_link);
        add(&items, &actions, &n, .{ .label = "Copy message" }, .copy_text);
        if (info.own) {
            add(&items, &actions, &n, .{ .separator = true }, null);
            add(&items, &actions, &n, .{ .label = "Delete message…", .danger = true }, .delete);
        }
        const idx = kit.menu(c, "message-menu", &m.menu_open, m.anchor, items[0..n], .{ .placement = .bottom_end, .width = 240 }) orelse return null;
        return actions[idx];
    }

    // Forward

    const Dest = struct { id: []const u8, label: []const u8, sort: []const u8 };

    fn destLess(_: void, a: Dest, b: Dest) bool {
        return std.ascii.lessThanIgnoreCase(a.sort, b.sort);
    }

    fn forwardList(m: *Menu, c: *ui.Context, st: *const store.Store) ?[]const u8 {
        const p = kit.popover(c, "forward-to", &m.forward_open, m.anchor, .{ .placement = .bottom_end, .width = forward_w, .padding = 8, .gap = 6 }) orelse return null;
        defer p.end();
        ui.text(c, "Forward message to…", .{ .size = 13, .weight = .semibold, .color = c.theme.muted });
        _ = ui.textField(c, &m.forward_query, .{ .caret_color = theme.caretColor(c.theme.dark), .placeholder = "Search conversations", .width = .fill, .size = 14 });
        const query = std.mem.trim(u8, m.forward_query.text(), " #");
        var dests: std.ArrayList(Dest) = .empty;
        for (st.channels.items) |*ch| {
            if (ch.kind == .im or ch.kind == .mpim) {
                if (!ch.listed or st.isApp(ch)) continue;
            }
            const name = st.channelName(ch);
            if (name.len == 0 or !containsIgnoreCase(name, query)) continue;
            const label = switch (ch.kind) {
                .channel => c.print("# {s}", .{name}),
                .private => c.print("🔒 {s}", .{name}),
                .im, .mpim => name,
            };
            dests.append(c.alloc(), .{ .id = ch.id, .label = label, .sort = name }) catch break;
        }
        std.mem.sort(Dest, dests.items, {}, destLess);
        var chosen: ?[]const u8 = null;
        const list = ui.div(c).column().wFull().h(@min(8, @as(f32, @floatFromInt(@max(1, dests.items.len)))) * forward_row_h).scrollY();
        defer list.end();
        if (dests.items.len == 0) ui.text(c, "No conversations found", .{ .size = 14, .color = c.theme.muted });
        for (dests.items[0..@min(dests.items.len, forward_max_rows)], 0..) |d, i| {
            ui.key(c, c.print("dest-{d}", .{i}));
            const row = ui.div(c).row().wFull().h(forward_row_h).px(10).itemsCenter().rounded(8).control().hover(c.theme.surface_hover);
            defer row.end();
            if (row.clicked()) chosen = d.id;
            ui.text(c, d.label, .{ .size = 14, .truncate = .ellipsis });
        }
        if (chosen != null) m.forward_open = false;
        return chosen;
    }

    // Delete confirmation

    fn confirm(m: *Menu, c: *ui.Context, pal: theme.Palette, info: Info) bool {
        const d = kit.dialog(c, "delete-message", &m.delete_open, .{
            .title = "Delete message",
            .description = "Are you sure you want to delete this message? This can't be undone.",
            .ok = "Delete",
            .ok_variant = .danger,
            .width = 420,
        }) orelse return false;
        {
            const quote = ui.div(c).wFull().px(12).py(8).rounded(8).bg(pal.container_high).border(c.theme.border).borderW(1).clip();
            defer quote.end();
            const text = if (info.preview.len > 160) info.preview[0..160] else info.preview;
            ui.text(c, text, .{ .size = 14, .color = c.theme.muted, .wrap = true });
        }
        return d.end() == .ok;
    }
};

/// The smileys and people: 😀 to 🙏, and the 🤐 to 🤯 faces
fn isFace(glyph: []const u8) bool {
    const cp = std.unicode.utf8Decode(glyph[0..(std.unicode.utf8ByteSequenceLength(glyph[0]) catch return false)]) catch return false;
    return (cp >= 0x1F600 and cp <= 0x1F64F) or (cp >= 0x1F910 and cp <= 0x1F92F);
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (hay.len < needle.len) return false;
    for (0..hay.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
    }
    return false;
}

test "a target holds its message by value" {
    const t = Target.make("C123", "1700000000.000100", true);
    try std.testing.expect(t.is("C123", "1700000000.000100", true));
    try std.testing.expect(!t.is("C123", "1700000000.000100", false));
    try std.testing.expect(!t.is("C124", "1700000000.000100", true));
}
