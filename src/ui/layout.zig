//! Window and sidebar sizes kept between runs: `<config dir>/layout.json`.
//! Non-secret, separate from the network side's `state.json`.
const std = @import("std");

pub const Layout = struct {
    sidebar: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn eql(a: Layout, b: Layout) bool {
        return @abs(a.sidebar - b.sidebar) < 1 and @abs(a.width - b.width) < 1 and @abs(a.height - b.height) < 1;
    }

    /// Whether the window size is one worth restoring
    pub fn hasWindow(l: Layout) bool {
        return l.width >= 400 and l.height >= 300 and l.width <= 10000 and l.height <= 10000;
    }
};

/// Defaults when the file is missing or unreadable
pub fn load(arena: std.mem.Allocator, io: std.Io, dir: []const u8) Layout {
    const path = std.fs.path.join(arena, &.{ dir, "layout.json" }) catch return .{};
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 12)) catch return .{};
    return std.json.parseFromSliceLeaky(Layout, arena, data, .{ .ignore_unknown_fields = true }) catch .{};
}

pub fn save(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, layout: Layout) void {
    std.Io.Dir.cwd().createDirPath(io, dir) catch return;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    std.json.Stringify.value(layout, .{ .whitespace = .indent_2 }, &aw.writer) catch return;
    const path = std.fs.path.join(gpa, &.{ dir, "layout.json" }) catch return;
    defer gpa.free(path);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() }) catch {};
}

test "layout round trip, missing file defaults" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/lax", .{tmp.sub_path});

    try std.testing.expect(!load(arena, io, dir).hasWindow());
    save(gpa, io, dir, .{ .sidebar = 300, .width = 1280, .height = 800 });
    const got = load(arena, io, dir);
    try std.testing.expect(got.eql(.{ .sidebar = 300, .width = 1280, .height = 800 }));
    try std.testing.expect(got.hasWindow());
}
