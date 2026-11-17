//! The menu a right-click on a link in a message opens. This holds which
//! URL it is for and whether it is open, draws it, and says what was chosen;
//! the caller acts on that.
const std = @import("std");
const nanoui = @import("nanoui");
const kit = nanoui.kit;
const ui = nanoui.ui;

const menu_w: f32 = 200;

pub const Choice = enum { open, copy };

pub const Menu = struct {
    gpa: std.mem.Allocator,
    /// Owned: the message text it came from is rebuilt every frame
    url: []u8 = &.{},
    anchor: ?ui.Rect = null,
    open: bool = false,

    pub fn init(gpa: std.mem.Allocator) Menu {
        return .{ .gpa = gpa };
    }

    pub fn deinit(m: *Menu) void {
        m.gpa.free(m.url);
    }

    pub fn closeAll(m: *Menu) void {
        m.open = false;
    }

    pub fn anyOpen(m: *const Menu) bool {
        return m.open;
    }

    /// Opens the menu for `url`, at the pointer
    pub fn show(m: *Menu, url: []const u8, x: f32, y: f32) void {
        const copy = m.gpa.dupe(u8, url) catch return;
        m.gpa.free(m.url);
        m.url = copy;
        m.anchor = .{ .x = x, .y = y, .w = 1, .h = 1 };
        m.open = true;
    }

    /// Draws the menu if it is open (last in the frame, over everything)
    pub fn draw(m: *Menu, c: *ui.Context, can_open: bool) ?Choice {
        if (!m.open) return null;
        var items: [2]kit.MenuItem = undefined;
        var choices: [2]Choice = undefined;
        var n: usize = 0;
        if (can_open) {
            items[n] = .{ .label = "Open link" };
            choices[n] = .open;
            n += 1;
        }
        items[n] = .{ .label = "Copy link" };
        choices[n] = .copy;
        n += 1;
        const idx = kit.menu(c, "link-menu", &m.open, m.anchor, items[0..n], .{ .placement = .bottom_start, .width = menu_w }) orelse return null;
        return choices[idx];
    }
};
