//! The emoji you reacted with last, newest first, kept in
//! `<config dir>/recent_emoji` (one shortcode per line). The hover toolbar
//! shows the first three, topped up with Slack's own defaults.
const std = @import("std");

pub const max = 8;
const name_max = 40;
const file_name = "recent_emoji";

/// What fills the toolbar before there is history
pub const defaults = [_][]const u8{ "+1", "eyes", "raised_hands" };

pub const Recents = struct {
    names: [max][name_max]u8 = undefined,
    lens: [max]u8 = @splat(0),
    n: usize = 0,

    pub fn get(r: *const Recents, i: usize) []const u8 {
        return r.names[i][0..r.lens[i]];
    }

    /// `name` becomes the newest; an older copy of it goes. Skin tones are dropped.
    pub fn push(r: *Recents, name: []const u8) void {
        const base = if (std.mem.indexOf(u8, name, "::")) |i| name[0..i] else name;
        if (base.len == 0 or base.len > name_max) return;
        var at: usize = r.n;
        for (0..r.n) |i| if (std.mem.eql(u8, r.get(i), base)) {
            at = i;
            break;
        };
        if (at == r.n) {
            if (r.n < max) r.n += 1 else at = max - 1;
        }
        // Everything newer than the slot moves down one
        var i = at;
        while (i > 0) : (i -= 1) {
            r.names[i] = r.names[i - 1];
            r.lens[i] = r.lens[i - 1];
        }
        @memcpy(r.names[0][0..base.len], base);
        r.lens[0] = @intCast(base.len);
    }

    /// The first `out.len` to show: the history, then defaults not already in it
    pub fn top(r: *const Recents, out: [][]const u8) usize {
        var k: usize = 0;
        for (0..r.n) |i| {
            if (k == out.len) return k;
            out[k] = r.get(i);
            k += 1;
        }
        for (defaults) |d| {
            if (k == out.len) return k;
            const seen = for (out[0..k]) |o| {
                if (std.mem.eql(u8, o, d)) break true;
            } else false;
            if (seen) continue;
            out[k] = d;
            k += 1;
        }
        return k;
    }

    pub fn load(r: *Recents, arena: std.mem.Allocator, io: std.Io, dir: []const u8) void {
        const path = std.fs.path.join(arena, &.{ dir, file_name }) catch return;
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 10)) catch return;
        // Oldest first, so pushing leaves the newest on top
        var lines: [max][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.tokenizeAny(u8, data, "\r\n");
        while (it.next()) |line| {
            if (count == max) break;
            lines[count] = line;
            count += 1;
        }
        r.* = .{};
        while (count > 0) {
            count -= 1;
            r.push(lines[count]);
        }
    }

    pub fn save(r: *const Recents, gpa: std.mem.Allocator, io: std.Io, dir: []const u8) void {
        std.Io.Dir.cwd().createDirPath(io, dir) catch return;
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        for (0..r.n) |i| aw.writer.print("{s}\n", .{r.get(i)}) catch return;
        const path = std.fs.path.join(gpa, &.{ dir, file_name }) catch return;
        defer gpa.free(path);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() }) catch {};
    }
};

test "newest first, repeats move up, the list is bounded, defaults top it up" {
    var r: Recents = .{};
    var out: [3][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), r.top(&out));
    try std.testing.expectEqualStrings("+1", out[0]);
    try std.testing.expectEqualStrings("raised_hands", out[2]);

    r.push("tada");
    try std.testing.expectEqual(@as(usize, 3), r.top(&out));
    try std.testing.expectEqualStrings("tada", out[0]);
    try std.testing.expectEqualStrings("+1", out[1]);
    try std.testing.expectEqualStrings("eyes", out[2]);

    r.push("eyes");
    r.push("tada");
    try std.testing.expectEqual(@as(usize, 2), r.n);
    _ = r.top(&out);
    try std.testing.expectEqualStrings("tada", out[0]);
    try std.testing.expectEqualStrings("eyes", out[1]);
    try std.testing.expectEqualStrings("+1", out[2]);

    r.push("+1::skin-tone-3");
    try std.testing.expectEqualStrings("+1", r.get(0));

    for ([_][]const u8{ "a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8", "a9" }) |n| r.push(n);
    try std.testing.expectEqual(@as(usize, max), r.n);
    try std.testing.expectEqualStrings("a9", r.get(0));
    try std.testing.expectEqualStrings("a2", r.get(max - 1));
}

test "recents round trip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/lax", .{tmp.sub_path});

    var none: Recents = .{};
    none.load(arena, io, dir);
    try std.testing.expectEqual(@as(usize, 0), none.n);

    var r: Recents = .{};
    r.push("fire");
    r.push("tada");
    r.save(gpa, io, dir);
    var back: Recents = .{};
    back.load(arena, io, dir);
    try std.testing.expectEqual(@as(usize, 2), back.n);
    try std.testing.expectEqualStrings("tada", back.get(0));
    try std.testing.expectEqualStrings("fire", back.get(1));
}
