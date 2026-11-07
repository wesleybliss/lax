//! Files dropped on the window, waiting to go with the next message: kept as
//! paths, shown as chips above the message box. Nothing is read until sent.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");

/// Slack takes ten files in one message
pub const max_files = 10;
/// Chips shown before "+N more"
const max_chips = 4;
const chip_h: f32 = 30;

pub const Pending = struct {
    gpa: std.mem.Allocator,
    /// Absolute paths, owned
    items: std.ArrayList([]u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Pending {
        return .{ .gpa = gpa };
    }

    pub fn deinit(p: *Pending) void {
        p.clear();
        p.items.deinit(p.gpa);
    }

    pub fn clear(p: *Pending) void {
        for (p.items.items) |path| p.gpa.free(path);
        p.items.clearRetainingCapacity();
    }

    pub fn isEmpty(p: *const Pending) bool {
        return p.items.items.len == 0;
    }

    pub fn paths(p: *const Pending) []const []u8 {
        return p.items.items;
    }

    /// What a drop brought: the files (`file://` URLs) not already waiting,
    /// up to Slack's limit. Links to the web and text are not files.
    pub fn addUrls(p: *Pending, urls: []const []const u8) void {
        for (urls) |url| {
            if (p.items.items.len >= max_files) return;
            const path = urlToPath(p.gpa, url) orelse continue;
            if (p.has(path)) {
                p.gpa.free(path);
                continue;
            }
            p.items.append(p.gpa, path) catch p.gpa.free(path);
        }
    }

    fn has(p: *const Pending, path: []const u8) bool {
        for (p.items.items) |have| if (std.mem.eql(u8, have, path)) return true;
        return false;
    }

    fn removeAt(p: *Pending, i: usize) void {
        p.gpa.free(p.items.orderedRemove(i));
    }

    /// The chips, with a ✕ on each; nothing is drawn while empty.
    pub fn view(p: *Pending, c: *ui.Context, pal: theme.Palette) void {
        if (p.isEmpty()) return;
        const row = ui.div(c).row().itemsCenter().gap(8).wFull().px(20).pb(8);
        defer row.end();
        var remove: ?usize = null;
        for (p.items.items[0..@min(p.items.items.len, max_chips)], 0..) |path, i| {
            const chip = ui.div(c).row().itemsCenter().gap(6).h(chip_h).maxW(220).pl(12).pr(4).roundedFull().circular().bg(pal.container_high).border(c.theme.border).borderW(1);
            defer chip.end();
            ui.text(c, "📎", .{ .size = 13 });
            ui.text(c, c.alloc().dupe(u8, std.fs.path.basename(path)) catch "file", .{ .size = 13, .truncate = .ellipsis });
            const x = ui.div(c).w(22).h(22).center().roundedFull().circular().control().hover(c.theme.surface_hover);
            defer x.end();
            if (x.clicked()) remove = i;
            ui.text(c, "✕", .{ .size = 11, .color = c.theme.muted });
        }
        if (p.items.items.len > max_chips) ui.text(c, c.print("+{d} more", .{p.items.items.len - max_chips}), .{ .size = 13, .color = c.theme.muted });
        if (remove) |i| p.removeAt(i);
    }
};

/// A file URL as a path (`file:///home/a%20b.png` is `/home/a b.png`), or
/// null for anything else. Owned by the caller.
pub fn urlToPath(gpa: std.mem.Allocator, url: []const u8) ?[]u8 {
    const prefix = "file://";
    if (!std.ascii.startsWithIgnoreCase(url, prefix)) return null;
    var rest = url[prefix.len..];
    // An authority is empty or this machine: `file://localhost/x`
    if (rest.len == 0 or rest[0] != '/') {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        if (!std.ascii.eqlIgnoreCase(rest[0..slash], "localhost")) return null;
        rest = rest[slash..];
    }
    // Any query or fragment is not part of the name
    if (std.mem.indexOfAny(u8, rest, "?#")) |end| rest = rest[0..end];
    var out = gpa.alloc(u8, rest.len) catch return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (n += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            if (std.fmt.parseInt(u8, rest[i + 1 ..][0..2], 16)) |byte| {
                out[n] = byte;
                i += 3;
                continue;
            } else |_| {}
        }
        out[n] = rest[i];
        i += 1;
    }
    if (n == 0 or std.mem.indexOfScalar(u8, out[0..n], 0) != null) {
        gpa.free(out);
        return null;
    }
    return gpa.realloc(out, n) catch out[0..n];
}

test "file URLs become paths" {
    const gpa = std.testing.allocator;
    const a = urlToPath(gpa, "file:///home/wes/My%20Pictures/a%23b.png").?;
    defer gpa.free(a);
    try std.testing.expectEqualStrings("/home/wes/My Pictures/a#b.png", a);
    const b = urlToPath(gpa, "file://localhost/tmp/x.txt").?;
    defer gpa.free(b);
    try std.testing.expectEqualStrings("/tmp/x.txt", b);
    const e = urlToPath(gpa, "file:///tmp/%E4%B8%AD.txt").?;
    defer gpa.free(e);
    try std.testing.expectEqualStrings("/tmp/中.txt", e);
    // A stray percent sign is kept
    const f = urlToPath(gpa, "file:///tmp/100%.txt").?;
    defer gpa.free(f);
    try std.testing.expectEqualStrings("/tmp/100%.txt", f);
    try std.testing.expect(urlToPath(gpa, "https://example.com/a.png") == null);
    try std.testing.expect(urlToPath(gpa, "file://other-host/a") == null);
    try std.testing.expect(urlToPath(gpa, "file:///a%00b") == null);
}

test "adding urls skips repeats, links and the eleventh file" {
    const gpa = std.testing.allocator;
    var p: Pending = .init(gpa);
    defer p.deinit();
    p.addUrls(&.{ "file:///a.png", "https://example.com/b.png", "file:///a.png" });
    try std.testing.expectEqual(@as(usize, 1), p.items.items.len);
    var many: [12][]const u8 = undefined;
    var bufs: [12][24]u8 = undefined;
    for (&many, &bufs, 0..) |*m, *buf, i| m.* = std.fmt.bufPrint(buf, "file:///f{d}.txt", .{i}) catch unreachable;
    p.addUrls(&many);
    try std.testing.expectEqual(@as(usize, max_files), p.items.items.len);
}
