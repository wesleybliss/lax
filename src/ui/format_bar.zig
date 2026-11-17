//! The two rows of Slack's message box: the formatting buttons on top, and
//! below the text the attach, emoji and mention buttons with Send. They draw
//! and say what was clicked; `composer.zig` and the app act on it.
const std = @import("std");
const nanoui = @import("nanoui");
const kit = nanoui.kit;
const ui = nanoui.ui;
const format = @import("format.zig");

const button: f32 = 30;
const icon_size: f32 = 18;

pub const Action = union(enum) {
    attach,
    /// Show or hide the formatting row
    toggle_format,
    /// Where the emoji button is, for the picker to open by
    emoji: ui.Rect,
    mention,
    send,
};

const Mark = struct {
    kind: format.Kind,
    tip: []const u8,
    bytes: []const u8,
};

const marks = [_][]const Mark{
    &.{
        .{ .kind = .bold, .tip = "Bold", .bytes = @embedFile("icons/bold.svg") },
        .{ .kind = .italic, .tip = "Italic", .bytes = @embedFile("icons/italic.svg") },
        .{ .kind = .strike, .tip = "Strikethrough", .bytes = @embedFile("icons/strikethrough.svg") },
    },
    &.{
        .{ .kind = .link, .tip = "Link", .bytes = @embedFile("icons/link.svg") },
    },
    &.{
        .{ .kind = .numbers, .tip = "Numbered list", .bytes = @embedFile("icons/list-ordered.svg") },
        .{ .kind = .bullets, .tip = "Bulleted list", .bytes = @embedFile("icons/list.svg") },
    },
    &.{
        .{ .kind = .quote, .tip = "Quote", .bytes = @embedFile("icons/text-quote.svg") },
    },
    &.{
        .{ .kind = .code, .tip = "Code", .bytes = @embedFile("icons/code.svg") },
        .{ .kind = .code_block, .tip = "Code block", .bytes = @embedFile("icons/square-code.svg") },
    },
};

/// A square icon button with a tooltip; its place when clicked
fn iconButton(c: *ui.Context, key: []const u8, bytes: []const u8, tip: []const u8, tint: ui.Color, active: bool) ?ui.Rect {
    var btn = ui.div(c).w(button).h(button).center().rounded(6).control().hover(c.theme.surface_hover);
    if (active) btn = btn.bg(c.theme.surface_hover);
    defer btn.end();
    const it = btn.interaction();
    kit.tooltip(c, it, tip, .{});
    _ = ui.svg(c, .{ .key = key, .bytes = bytes, .size = icon_size, .color = tint });
    if (!btn.clicked()) return null;
    return it.rect orelse ui.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
}

/// The formatting row: what was clicked
pub fn top(c: *ui.Context) ?format.Kind {
    const row = ui.div(c).row().itemsCenter().wFull().px(12).py(6).gap(2).bg(c.theme.surface_hover.alpha(0.5));
    defer row.end();
    var clicked: ?format.Kind = null;
    for (marks, 0..) |group, g| {
        if (g > 0) separator(c);
        for (group) |m| {
            if (iconButton(c, m.tip, m.bytes, m.tip, c.theme.muted, false) != null) clicked = m.kind;
        }
    }
    return clicked;
}

fn separator(c: *ui.Context) void {
    const gap = ui.div(c).w(9).h(20).center();
    defer gap.end();
    const line = ui.div(c).w(1).h(18).bg(c.theme.border);
    line.end();
}

pub const BottomOptions = struct {
    /// The formatting row is showing
    format_open: bool,
    /// There is something to send
    can_send: bool,
};

/// The row under the text: attach, formatting switch, emoji, mention, and Send
pub fn bottom(c: *ui.Context, opts: BottomOptions) ?Action {
    const row = ui.div(c).row().itemsCenter().wFull().px(12).pb(10).pt(2).gap(2);
    defer row.end();
    var action: ?Action = null;
    const muted = c.theme.muted;
    if (iconButton(c, "Attach files", @embedFile("icons/plus.svg"), "Attach files", muted, false) != null) action = .attach;
    if (iconButton(c, "Formatting", @embedFile("icons/case-sensitive.svg"), "Formatting", muted, opts.format_open) != null) action = .toggle_format;
    if (iconButton(c, "Emoji", @embedFile("icons/smile.svg"), "Emoji", muted, false)) |at| action = .{ .emoji = at };
    if (iconButton(c, "Mention", @embedFile("icons/at-sign.svg"), "Mention someone", muted, false) != null) action = .mention;
    ui.spacer(c);
    if (send(c, opts.can_send)) action = .send;
    return action;
}

fn send(c: *ui.Context, can_send: bool) bool {
    var btn = ui.div(c).w(36).h(button).center().rounded(6).control();
    btn = if (can_send) btn.bg(c.theme.accent) else btn.hover(c.theme.surface_hover);
    defer btn.end();
    const tint = if (can_send) ui.Color.white else c.theme.muted;
    _ = ui.svg(c, .{ .key = "Send", .bytes = @embedFile("icons/send.svg"), .size = icon_size, .color = tint });
    return btn.clicked() and can_send;
}
