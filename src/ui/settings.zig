//! User settings kept between runs, one set per workspace:
//! `<config dir>/settings/<team id>.json`. `<config dir>/settings.json`
//! (what earlier versions wrote) is what a workspace without a file starts from.
const std = @import("std");

pub const interface_min = 85;
pub const interface_max = 125;
pub const chat_min = 12;
pub const chat_max = 22;
/// Height of a sidebar row in points; the three presets of Settings
pub const row_min = 28;
pub const row_max = 56;
pub const row_compact = 32;
pub const row_comfortable = 40;
pub const row_cozy = 48;

/// Which colors: the system's light or dark choice, or one forced
pub const Appearance = enum { system, light, dark };

pub const Settings = struct {
    /// Light or dark; `system` follows the desktop
    appearance: Appearance = .system,
    /// Id of the color theme; empty is the default
    theme: []const u8 = "",
    /// Font family of the interface; empty is the system's
    ui_font: []const u8 = "",
    /// Font family of message text; empty is the interface's
    chat_font: []const u8 = "",
    /// Interface zoom in percent
    interface_size: u16 = 100,
    /// Message text size in points
    chat_size: u16 = 15,
    /// Height of the sidebar's rows in points: the spacing between conversations
    sidebar_row: u16 = row_comfortable,

    /// The same settings with every value in range
    pub fn clamped(s: Settings) Settings {
        var out = s;
        out.interface_size = std.math.clamp(s.interface_size, interface_min, interface_max);
        out.chat_size = std.math.clamp(s.chat_size, chat_min, chat_max);
        out.sidebar_row = std.math.clamp(s.sidebar_row, row_min, row_max);
        return out;
    }
};

fn read(arena: std.mem.Allocator, io: std.Io, path: []const u8) ?Settings {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 14)) catch return null;
    const parsed = std.json.parseFromSliceLeaky(Settings, arena, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    return parsed.clamped();
}

fn write(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8, settings: Settings) void {
    std.Io.Dir.cwd().createDirPath(io, dir) catch return;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    std.json.Stringify.value(settings, .{ .whitespace = .indent_2 }, &aw.writer) catch return;
    const path = std.fs.path.join(gpa, &.{ dir, name }) catch return;
    defer gpa.free(path);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() }) catch {};
}

/// A team id names a file, so only letters and digits are allowed
fn safeId(id: []const u8) bool {
    if (id.len == 0 or id.len > 32) return false;
    for (id) |ch| if (!std.ascii.isAlphanumeric(ch)) return false;
    return true;
}

fn teamFile(buf: []u8, id: []const u8) ?[]const u8 {
    if (!safeId(id)) return null;
    return std.fmt.bufPrint(buf, "{s}.json", .{id}) catch null;
}

/// The shared file's settings, or defaults when it is missing or unreadable; strings live in `arena`
pub fn load(arena: std.mem.Allocator, io: std.Io, dir: []const u8) Settings {
    const path = std.fs.path.join(arena, &.{ dir, "settings.json" }) catch return .{};
    return read(arena, io, path) orelse .{};
}

/// A workspace's settings: its own file, else the shared file's, else defaults
pub fn loadTeam(arena: std.mem.Allocator, io: std.Io, dir: []const u8, team_id: []const u8) Settings {
    var buf: [48]u8 = undefined;
    if (teamFile(&buf, team_id)) |file| {
        const path = std.fs.path.join(arena, &.{ dir, "settings", file }) catch return load(arena, io, dir);
        if (read(arena, io, path)) |own| return own;
    }
    return load(arena, io, dir);
}

/// Saves a workspace's settings to its own file (the shared file for an id that is no file name)
pub fn saveTeam(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, team_id: []const u8, settings: Settings) void {
    var buf: [48]u8 = undefined;
    const file = teamFile(&buf, team_id) orelse return write(gpa, io, dir, "settings.json", settings);
    const sub = std.fs.path.join(gpa, &.{ dir, "settings" }) catch return;
    defer gpa.free(sub);
    write(gpa, io, sub, file, settings);
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
    try std.testing.expectEqual(Appearance.system, load(arena, io, dir).appearance);
    saveTeam(gpa, io, dir, "", .{ .appearance = .dark, .theme = "ocean", .ui_font = "Inter", .chat_font = "Noto Serif", .interface_size = 110, .chat_size = 99, .sidebar_row = 5 });
    const got = load(arena, io, dir);
    try std.testing.expectEqual(@as(u16, row_min), got.sidebar_row);
    try std.testing.expectEqual(Appearance.dark, got.appearance);
    try std.testing.expectEqualStrings("ocean", got.theme);
    try std.testing.expectEqualStrings("Inter", got.ui_font);
    try std.testing.expectEqualStrings("Noto Serif", got.chat_font);
    try std.testing.expectEqual(@as(u16, 110), got.interface_size);
    try std.testing.expectEqual(@as(u16, chat_max), got.chat_size);
}

test "each workspace keeps its own settings" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/lax", .{tmp.sub_path});

    // No file at all: defaults. Then the shared file is what a new workspace starts from
    try std.testing.expectEqualStrings("", loadTeam(arena, io, dir, "T1").theme);
    saveTeam(gpa, io, dir, "", .{ .theme = "forest" });
    try std.testing.expectEqualStrings("forest", loadTeam(arena, io, dir, "T1").theme);

    saveTeam(gpa, io, dir, "T1", .{ .theme = "ocean", .sidebar_row = row_cozy });
    saveTeam(gpa, io, dir, "T2", .{ .theme = "rose" });
    try std.testing.expectEqualStrings("ocean", loadTeam(arena, io, dir, "T1").theme);
    try std.testing.expectEqual(@as(u16, row_cozy), loadTeam(arena, io, dir, "T1").sidebar_row);
    try std.testing.expectEqualStrings("rose", loadTeam(arena, io, dir, "T2").theme);
    try std.testing.expectEqualStrings("forest", loadTeam(arena, io, dir, "T3").theme);
    // An id that is not a file name never reaches outside the config dir
    saveTeam(gpa, io, dir, "../x", .{ .theme = "graphite" });
    try std.testing.expectEqualStrings("graphite", load(arena, io, dir).theme);
}
