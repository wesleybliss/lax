//! Small non-secret app state kept between runs: the last-used workspace.
//! `$XDG_CONFIG_HOME/lax/state.json` (or `~/.config/lax/state.json`).
const std = @import("std");

pub const State = struct {
    last_team: []const u8 = "",
};

/// Absolute path of the config directory, or null without a home
pub fn configDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) std.mem.Allocator.Error!?[]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |x| if (x.len > 0) return try std.fs.path.join(arena, &.{ x, "lax" });
    const home = env.get("HOME") orelse return null;
    return try std.fs.path.join(arena, &.{ home, ".config", "lax" });
}

/// Absolute path of the cache directory (`$XDG_CACHE_HOME/lax`), or null without a home
pub fn cacheDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) std.mem.Allocator.Error!?[]const u8 {
    if (env.get("XDG_CACHE_HOME")) |x| if (x.len > 0) return try std.fs.path.join(arena, &.{ x, "lax" });
    const home = env.get("HOME") orelse return null;
    return try std.fs.path.join(arena, &.{ home, ".cache", "lax" });
}

/// Reads the state; defaults when the file is missing or unreadable.
/// Strings live in `arena`.
pub fn load(arena: std.mem.Allocator, io: std.Io, dir: []const u8) State {
    const path = std.fs.path.join(arena, &.{ dir, "state.json" }) catch return .{};
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 16)) catch return .{};
    return std.json.parseFromSliceLeaky(State, arena, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch .{};
}

pub fn save(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, state: State) void {
    std.Io.Dir.cwd().createDirPath(io, dir) catch return;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    std.json.Stringify.value(state, .{ .whitespace = .indent_2 }, &aw.writer) catch return;
    const path = std.fs.path.join(gpa, &.{ dir, "state.json" }) catch return;
    defer gpa.free(path);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() }) catch {};
}

test "state round trip, missing file defaults" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/lax", .{tmp.sub_path});

    try std.testing.expectEqualStrings("", load(arena, io, dir).last_team);
    save(gpa, io, dir, .{ .last_team = "T0123456789" });
    try std.testing.expectEqualStrings("T0123456789", load(arena, io, dir).last_team);
}
