//! User settings kept between runs: `<config dir>/settings.json`.
const std = @import("std");

pub const interface_min = 85;
pub const interface_max = 125;
pub const chat_min = 12;
pub const chat_max = 22;

pub const Settings = struct {
    /// Font family of the interface; empty is the system's
    ui_font: []const u8 = "",
    /// Font family of message text; empty is the interface's
    chat_font: []const u8 = "",
    /// Interface zoom in percent
    interface_size: u16 = 100,
    /// Message text size in points
    chat_size: u16 = 15,

    /// The same settings with every value in range
    pub fn clamped(s: Settings) Settings {
        var out = s;
        out.interface_size = std.math.clamp(s.interface_size, interface_min, interface_max);
        out.chat_size = std.math.clamp(s.chat_size, chat_min, chat_max);
        return out;
    }
};

/// Defaults when the file is missing or unreadable; strings live in `arena`
pub fn load(arena: std.mem.Allocator, io: std.Io, dir: []const u8) Settings {
    const path = std.fs.path.join(arena, &.{ dir, "settings.json" }) catch return .{};
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 14)) catch return .{};
    const parsed = std.json.parseFromSliceLeaky(Settings, arena, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return .{};
    return parsed.clamped();
}

pub fn save(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, settings: Settings) void {
    std.Io.Dir.cwd().createDirPath(io, dir) catch return;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    std.json.Stringify.value(settings, .{ .whitespace = .indent_2 }, &aw.writer) catch return;
    const path = std.fs.path.join(gpa, &.{ dir, "settings.json" }) catch return;
    defer gpa.free(path);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() }) catch {};
}

test "settings round trip, clamping, defaults" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/lax", .{tmp.sub_path});

    try std.testing.expectEqual(@as(u16, 15), load(arena, io, dir).chat_size);
    save(gpa, io, dir, .{ .ui_font = "Inter", .chat_font = "Noto Serif", .interface_size = 110, .chat_size = 99 });
    const got = load(arena, io, dir);
    try std.testing.expectEqualStrings("Inter", got.ui_font);
    try std.testing.expectEqualStrings("Noto Serif", got.chat_font);
    try std.testing.expectEqual(@as(u16, 110), got.interface_size);
    try std.testing.expectEqual(@as(u16, chat_max), got.chat_size);
}
