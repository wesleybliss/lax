//! A message composer with completion: `@name`, `#channel` and `:emoji:`
//! suggestions above the text area. Picking a mention records a mapping so
//! the text sent has Slack's `<@U123>` form.
const std = @import("std");
const nanoui = @import("nanoui");
const slack = @import("slack");
const store = @import("store");
const ui = nanoui.ui;
const theme = @import("theme.zig");

const max_items = 8;
const item_h: f32 = 38;

pub const Kind = enum { user, channel, emoji };

const Token = struct {
    kind: Kind,
    /// Byte offset of the trigger character
    start: usize,
    query: []const u8,
};

const Candidate = struct {
    /// What the list shows
    label: []const u8,
    /// Typed over the token when picked
    insert: []const u8,
    /// Slack's form of a mention, replacing `insert` when sending
    token: ?[]const u8 = null,
    glyph: ?[]const u8 = null,
};

const Mention = struct { shown: []u8, token: []u8 };

pub const Result = struct {
    changed: bool = false,
    /// The text to send, mentions expanded (in the frame's arena)
    submitted: ?[]const u8 = null,
    /// Where the text box is (as of this frame), for what sits on its border
    rect: ?ui.Rect = null,
};

pub const Options = struct {
    placeholder: []const u8,
    min_lines: u8 = 1,
    max_lines: u16 = 8,
    size: f32 = 15,
    /// Enter submits an empty box too (files are waiting to be sent)
    allow_empty: bool = false,
};

pub const Composer = struct {
    gpa: std.mem.Allocator,
    buf: ui.TextBuffer = .{},
    /// Caret as of the last frame
    caret: usize = 0,
    /// Selected suggestion
    index: usize = 0,
    last_query_len: usize = 0,
    /// Trigger position the user dismissed with Escape, plus one
    dismissed: usize = 0,
    mentions: std.ArrayList(Mention) = .empty,

    pub fn init(gpa: std.mem.Allocator) Composer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(k: *Composer) void {
        k.buf.deinit();
        k.freeMentions();
        k.mentions.deinit(k.gpa);
    }

    fn freeMentions(k: *Composer) void {
        for (k.mentions.items) |m| {
            k.gpa.free(m.shown);
            k.gpa.free(m.token);
        }
        k.mentions.clearRetainingCapacity();
    }

    pub fn clear(k: *Composer) void {
        k.buf.clear();
        k.freeMentions();
        k.index = 0;
        k.caret = 0;
        k.dismissed = 0;
    }

    pub fn text(k: *const Composer) []const u8 {
        return k.buf.text();
    }

    fn isSpace(ch: u8) bool {
        return ch == ' ' or ch == '\n' or ch == '\t' or ch == '\r';
    }

    /// The `@`, `#` or `:` word the caret is at the end of, if any
    fn detect(t: []const u8, caret: usize) ?Token {
        if (caret > t.len) return null;
        var i = caret;
        while (i > 0 and caret - i <= 40) : (i -= 1) {
            const ch = t[i - 1];
            if (isSpace(ch)) return null;
            const kind: Kind = switch (ch) {
                '@' => .user,
                '#' => .channel,
                ':' => .emoji,
                else => continue,
            };
            // Only at the start of a word: not in `a@b` or `10:30`
            if (i - 1 != 0 and !isSpace(t[i - 2])) return null;
            const query = t[i..caret];
            if (kind == .emoji and (query.len < 2 or std.mem.indexOfScalar(u8, query, ':') != null)) return null;
            return .{ .kind = kind, .start = i - 1, .query = query };
        }
        return null;
    }

    fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (hay.len < needle.len) return false;
        for (0..hay.len - needle.len + 1) |i| {
            if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
        }
        return false;
    }

    const Ranked = struct {
        c: Candidate,
        prefix: bool,
    };

    fn rankLess(_: void, a: Ranked, b: Ranked) bool {
        if (a.prefix != b.prefix) return a.prefix;
        return std.ascii.lessThanIgnoreCase(a.c.label, b.c.label);
    }

    fn candidates(arena: std.mem.Allocator, st: *store.Store, tok: Token) []const Candidate {
        var out: std.ArrayList(Ranked) = .empty;
        switch (tok.kind) {
            .user => {
                inline for (.{ "here", "channel" }) |special| {
                    if (std.ascii.startsWithIgnoreCase(special, tok.query)) out.append(arena, .{ .prefix = true, .c = .{
                        .label = "@" ++ special,
                        .insert = "@" ++ special ++ " ",
                        .token = "<!" ++ special ++ ">",
                    } }) catch {};
                }
                var it = st.users.valueIterator();
                while (it.next()) |u| {
                    if (!containsIgnoreCase(u.name, tok.query)) continue;
                    const label = std.fmt.allocPrint(arena, "@{s}", .{u.name}) catch continue;
                    out.append(arena, .{ .prefix = std.ascii.startsWithIgnoreCase(u.name, tok.query), .c = .{
                        .label = label,
                        .insert = std.fmt.allocPrint(arena, "@{s} ", .{u.name}) catch continue,
                        .token = std.fmt.allocPrint(arena, "<@{s}>", .{u.id}) catch continue,
                    } }) catch {};
                }
            },
            .channel => {
                for (st.channels.items) |ch| {
                    if (ch.kind != .channel and ch.kind != .private) continue;
                    if (!containsIgnoreCase(ch.name, tok.query)) continue;
                    out.append(arena, .{ .prefix = std.ascii.startsWithIgnoreCase(ch.name, tok.query), .c = .{
                        .label = std.fmt.allocPrint(arena, "#{s}", .{ch.name}) catch continue,
                        .insert = std.fmt.allocPrint(arena, "#{s} ", .{ch.name}) catch continue,
                        .token = std.fmt.allocPrint(arena, "<#{s}>", .{ch.id}) catch continue,
                    } }) catch {};
                }
            },
            .emoji => {
                var found: [max_items]slack.emoji.Entry = undefined;
                const n = slack.emoji.search(tok.query, &found);
                for (found[0..n]) |e| out.append(arena, .{ .prefix = true, .c = .{
                    .label = std.fmt.allocPrint(arena, ":{s}:", .{e.name}) catch continue,
                    .insert = std.fmt.allocPrint(arena, ":{s}: ", .{e.name}) catch continue,
                    .glyph = e.glyph,
                } }) catch {};
            },
        }
        // Emoji are already in alphabetical, prefix-only order
        if (tok.kind != .emoji) std.mem.sort(Ranked, out.items, {}, rankLess);
        const n = @min(out.items.len, max_items);
        const list = arena.alloc(Candidate, n) catch return &.{};
        for (list, out.items[0..n]) |*dst, src| dst.* = src.c;
        return list;
    }

    fn accept(k: *Composer, tok: Token, cand: Candidate) void {
        const end = tok.start + 1 + tok.query.len;
        const n = k.buf.replace(tok.start, end, cand.insert);
        k.buf.want_caret = tok.start + n;
        k.caret = tok.start + n;
        if (cand.token) |token| {
            const shown = std.mem.trimEnd(u8, cand.insert, " ");
            const s = k.gpa.dupe(u8, shown) catch return;
            const t = k.gpa.dupe(u8, token) catch {
                k.gpa.free(s);
                return;
            };
            k.mentions.append(k.gpa, .{ .shown = s, .token = t }) catch {
                k.gpa.free(s);
                k.gpa.free(t);
            };
        }
        k.index = 0;
    }

    /// The text with picked mentions in Slack's form
    fn expand(k: *const Composer, arena: std.mem.Allocator, input: []const u8) []const u8 {
        var out: []const u8 = input;
        for (k.mentions.items) |m| {
            out = std.mem.replaceOwned(u8, arena, out, m.shown, m.token) catch return out;
        }
        return out;
    }

    /// Suggestions (if any) and the text area. `submit_ok` false holds
    /// Enter back (a send in flight).
    pub fn view(k: *Composer, c: *ui.Context, st: *store.Store, pal: theme.Palette, opts: Options) Result {
        const col = ui.div(c).column().wFull();
        defer col.end();

        const arena = c.alloc();
        var tok = detect(k.buf.text(), k.caret);
        if (tok) |t| {
            if (k.dismissed != 0 and k.dismissed == t.start + 1) tok = null else if (k.dismissed != 0 and k.dismissed != t.start + 1) k.dismissed = 0;
        } else k.dismissed = 0;
        var items: []const Candidate = &.{};
        if (tok) |t| {
            items = candidates(arena, st, t);
            if (t.query.len != k.last_query_len) k.index = 0;
            k.last_query_len = t.query.len;
        }
        if (k.index >= items.len) k.index = 0;

        // Keys first, so the text area never sees the ones we take
        if (items.len > 0) {
            if (c.input.key) |key| {
                var taken = true;
                switch (key) {
                    .up => k.index = if (k.index == 0) items.len - 1 else k.index - 1,
                    .down => k.index = (k.index + 1) % items.len,
                    .enter, .tab => k.accept(tok.?, items[k.index]),
                    .escape => k.dismissed = tok.?.start + 1,
                    else => taken = false,
                }
                if (taken) {
                    c.input.key = null;
                    c.changed = true;
                }
            }
        }

        if (items.len > 0 and k.dismissed == 0) k.popup(c, pal, tok.?, items);

        const box = ui.div(c).wFull();
        defer box.end();
        const box_it = box.interaction();
        if (box_it.hovered) c.cursor = .text;
        const res = ui.textArea(c, &k.buf, .{
            .placeholder = opts.placeholder,
            .bare = false,
            .min_lines = opts.min_lines,
            .max_lines = @intCast(opts.max_lines),
            .size = opts.size,
            .submit_on_return = items.len == 0 or k.dismissed != 0,
        });
        k.caret = res.caret;
        var out: Result = .{ .changed = res.changed, .rect = box_it.rect };
        if (res.submitted) {
            const trimmed = std.mem.trim(u8, k.buf.text(), " \t\r\n");
            if (trimmed.len > 0) out.submitted = k.expand(arena, trimmed) else if (opts.allow_empty) out.submitted = "";
        }
        return out;
    }

    fn popup(k: *Composer, c: *ui.Context, pal: theme.Palette, tok: Token, items: []const Candidate) void {
        const card = ui.div(c).column().wFull().p(6).rounded(16).bg(pal.container_high).border(c.theme.border).borderW(1);
        defer card.end();
        var picked: ?usize = null;
        for (items, 0..) |cand, i| {
            var row = ui.div(c).row().itemsCenter().gap(12).wFull().h(item_h).px(12).control().rounded(10);
            if (i == k.index) row = row.bg(pal.secondary_container);
            row = row.hover(if (i == k.index) pal.secondary_container else c.theme.surface_hover);
            defer row.end();
            if (row.clicked()) picked = i;
            if (cand.glyph) |g| {
                const slot = ui.div(c).w(24).h(item_h).center();
                ui.text(c, g, .{ .size = 18 });
                slot.end();
            }
            ui.text(c, cand.label, .{ .size = 15, .weight = if (i == k.index) .semibold else .regular });
        }
        if (picked) |i| k.accept(tok, items[i]);
    }
};

test "detect finds the word being completed" {
    const t = Composer.detect("hello @gr", 9).?;
    try std.testing.expectEqual(Kind.user, t.kind);
    try std.testing.expectEqualStrings("gr", t.query);
    try std.testing.expectEqual(@as(usize, 6), t.start);
    try std.testing.expect(Composer.detect("mail a@b", 8) == null);
    try std.testing.expect(Composer.detect("at 10:30", 8) == null);
    try std.testing.expect(Composer.detect("hi :s", 5) == null); // one letter is too short
    try std.testing.expect(Composer.detect(":sm", 3) != null);
    try std.testing.expect(Composer.detect(":smile: ", 8) == null);
    try std.testing.expect(Composer.detect("#gen", 4).?.kind == .channel);
    try std.testing.expect(Composer.detect("done ", 5) == null);
}
