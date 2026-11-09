//! UI spike: a bottom-anchored, variable-height message list over synthetic
//! data, plus a multiline composer. Real data comes later via `store/`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const synthetic = @import("synthetic.zig");
const var_list = @import("var_list.zig");

const pad_x: f32 = 14;
const pad_y: f32 = 3;
const body_style: ui.TextStyle = .{ .size = 14, .wrap = true };
const head_style: ui.TextStyle = .{ .size = 13, .weight = .semibold };
const stamp_style: ui.TextStyle = .{ .size = 11 };
const group_secs = 5 * 60;

pub const State = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    messages: std.ArrayList(synthetic.Message) = .empty,
    list: var_list.VarList,
    input: ui.TextBuffer = .{},
    frame: u32 = 0,

    pub fn init(s: *State, gpa: std.mem.Allocator, count: usize) !void {
        s.* = .{ .gpa = gpa, .arena = .init(gpa), .list = .{ .gpa = gpa } };
        const msgs = try synthetic.generate(s.arena.allocator(), count, 42);
        try s.messages.appendSlice(gpa, msgs);
    }

    pub fn deinit(s: *State) void {
        s.list.deinit();
        s.messages.deinit(s.gpa);
        s.input.deinit();
        s.arena.deinit();
    }

    fn source(s: *State) var_list.Source {
        return .{ .ptr = s, .count = s.messages.items.len, .estimate = estimate, .measure = measure };
    }

    fn hasHeader(s: *const State, i: usize) bool {
        if (i == 0) return true;
        const prev = s.messages.items[i - 1];
        const cur = s.messages.items[i];
        return prev.author != cur.author or cur.ts - prev.ts > group_secs;
    }

    fn estimate(ptr: *anyopaque, i: usize, width: f32) f32 {
        const s: *State = @ptrCast(@alignCast(ptr));
        const chars_per_line = @max(8, (width - 2 * pad_x) / (body_style.size * 0.52));
        var lines: f32 = 0;
        var it = std.mem.splitScalar(u8, s.messages.items[i].text, '\n');
        while (it.next()) |p| lines += @max(1, @ceil(@as(f32, @floatFromInt(p.len)) / chars_per_line));
        return 2 * pad_y + lines * body_style.size * 1.25 + if (s.hasHeader(i)) @as(f32, 18) else 0;
    }

    fn measure(ptr: *anyopaque, c: *ui.Context, i: usize, width: f32) f32 {
        const s: *State = @ptrCast(@alignCast(ptr));
        const body_lh = c.text.font(body_style).lineHeight();
        var lines: usize = 0;
        var it = std.mem.splitScalar(u8, s.messages.items[i].text, '\n');
        while (it.next()) |p| lines += @max(1, c.text.wrap(p, body_style, width - 2 * pad_x).len);
        var h = 2 * pad_y + @as(f32, @floatFromInt(lines)) * body_lh;
        if (s.hasHeader(i)) h += c.text.font(head_style).lineHeight() + header_gap;
        return h;
    }

    const header_gap: f32 = 2;

    fn send(s: *State, text: []const u8) void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;
        const dup = s.arena.allocator().dupe(u8, trimmed) catch return;
        const last_ts = if (s.messages.items.len > 0) s.messages.items[s.messages.items.len - 1].ts else 0;
        s.messages.append(s.gpa, .{ .author = 0, .ts = last_ts + 30, .text = dup }) catch return;
        s.list.stickToEnd();
    }

    pub fn view(s: *State, c: *ui.Context) void {
        s.frame +%= 1;
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        s.topBar(c);
        ui.divider(c);
        s.drawList(c);
        ui.divider(c);
        const bar = ui.div(c).row().wFull().px(12).py(10);
        defer bar.end();
        const res = ui.textArea(c, &s.input, .{ .caret_color = theme.caretColor(c.theme.dark), .placeholder = "Message #general", .bare = false, .max_lines = 8 });
        if (res.submitted) {
            s.send(s.input.text());
            s.input.clear();
        }
    }

    fn topBar(s: *State, c: *ui.Context) void {
        const bar = ui.div(c).row().itemsCenter().gap(12).px(12).py(8);
        defer bar.end();
        ui.text(c, "# general", .{ .weight = .semibold });
        ui.spacer(c);
        ui.textf(c, .{ .color = c.theme.muted, .size = 12 }, "{d} messages · {d} rows built", .{ s.messages.items.len, s.list.built });
    }

    fn drawList(s: *State, c: *ui.Context) void {
        var rows = s.list.begin(c, s.source(), .{}) catch return;
        while (rows.next()) |i| s.drawRow(c, i);
        rows.end();
    }

    fn drawRow(s: *State, c: *ui.Context, i: usize) void {
        const m = s.messages.items[i];
        const row = ui.div(c).column().px(pad_x).py(pad_y).h(s.list.height(i)).clip();
        defer row.end();
        if (s.hasHeader(i)) {
            const head = ui.div(c).row().itemsCenter().gap(8);
            defer head.end();
            ui.text(c, synthetic.authors[m.author], head_style);
            ui.textf(c, .{ .color = c.theme.muted, .size = stamp_style.size }, "{d:0>2}:{d:0>2}", .{ (m.ts / 3600) % 24, (m.ts / 60) % 60 });
            ui.spacer(c);
        }
        var it = std.mem.splitScalar(u8, m.text, '\n');
        while (it.next()) |p| ui.text(c, if (p.len == 0) " " else p, body_style);
    }
};
