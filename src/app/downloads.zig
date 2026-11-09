//! Saving a file the user asked to download, into the system's downloads
//! folder (`~/Downloads`, or what `user-dirs.dirs` says on Linux).
const std = @import("std");
const builtin = @import("builtin");

/// Absolute path of the downloads folder, or null without a home. Owned by `arena`.
pub fn dir(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) std.mem.Allocator.Error!?[]const u8 {
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse return null;
    if (builtin.os.tag == .linux) {
        const config = if (env.get("XDG_CONFIG_HOME")) |x| (if (x.len > 0) try arena.dupe(u8, x) else null) else null;
        const base = config orelse try std.fs.path.join(arena, &.{ home, ".config" });
        const path = try std.fs.path.join(arena, &.{ base, "user-dirs.dirs" });
        if (std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 16))) |text| {
            if (try userDir(arena, text, home)) |d| return d;
        } else |_| {}
    }
    return try std.fs.path.join(arena, &.{ home, "Downloads" });
}

/// `XDG_DOWNLOAD_DIR="$HOME/Files"` in the text of `user-dirs.dirs`, with `$HOME` filled in
fn userDir(arena: std.mem.Allocator, text: []const u8, home: []const u8) std.mem.Allocator.Error!?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const key = "XDG_DOWNLOAD_DIR=";
        if (!std.mem.startsWith(u8, line, key)) continue;
        const value = std.mem.trim(u8, line[key.len..], "\"");
        const expanded = if (std.mem.startsWith(u8, value, "$HOME")) try std.mem.concat(arena, u8, &.{ home, value["$HOME".len..] }) else value;
        // Only an absolute place (`XDG_DOWNLOAD_DIR="$HOME/"` means "none set")
        if (!std.fs.path.isAbsolute(expanded) or std.mem.eql(u8, expanded, home) or std.mem.eql(u8, expanded, "/")) return null;
        return try arena.dupe(u8, expanded);
    }
    return null;
}

/// A safe file name from what Slack calls the file: no folders, no control
/// characters, never empty. Owned by `arena`.
pub fn cleanName(arena: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const base = name[if (std.mem.lastIndexOfAny(u8, name, "/\\")) |i| i + 1 else 0..];
    for (base) |c| try out.append(arena, if (c < 0x20 or c == 0x7f or c == ':') '_' else c);
    const trimmed = std.mem.trim(u8, out.items, " .");
    return if (trimmed.len == 0) "file" else trimmed;
}

pub const Saved = struct {
    /// Absolute path written
    path: []const u8,
};

/// Writes `bytes` into `folder` (made if missing) under `name`, or `name (1)`,
/// `name (2)`... when taken: nothing is ever overwritten.
pub fn save(arena: std.mem.Allocator, io: std.Io, folder: []const u8, name: []const u8, bytes: []const u8) !Saved {
    const clean = try cleanName(arena, name);
    try std.Io.Dir.cwd().createDirPath(io, folder);
    const ext = std.fs.path.extension(clean);
    const stem = clean[0 .. clean.len - ext.len];
    var n: u32 = 0;
    while (n < 1000) : (n += 1) {
        const file_name = if (n == 0) clean else try std.fmt.allocPrint(arena, "{s} ({d}){s}", .{ stem, n, ext });
        const path = try std.fs.path.join(arena, &.{ folder, file_name });
        const file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
        return .{ .path = path };
    }
    return error.PathAlreadyExists;
}

/// `path` with the home folder written `~`, for showing
pub fn tilde(arena: std.mem.Allocator, path: []const u8, home: ?[]const u8) []const u8 {
    const h = home orelse return path;
    if (h.len == 0 or !std.mem.startsWith(u8, path, h) or (path.len > h.len and path[h.len] != '/')) return path;
    return std.fmt.allocPrint(arena, "~{s}", .{path[h.len..]}) catch path;
}

test "user-dirs.dirs names the downloads folder" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const text = "# comment\nXDG_DESKTOP_DIR=\"$HOME/Desktop\"\nXDG_DOWNLOAD_DIR=\"$HOME/Files/In\"\n";
    try std.testing.expectEqualStrings("/home/a/Files/In", (try userDir(a.allocator(), text, "/home/a")).?);
    try std.testing.expectEqualStrings("/data/dl", (try userDir(a.allocator(), "XDG_DOWNLOAD_DIR=\"/data/dl\"", "/home/a")).?);
    // "$HOME" alone is how the desktop says there is none
    try std.testing.expect((try userDir(a.allocator(), "XDG_DOWNLOAD_DIR=\"$HOME\"", "/home/a")) == null);
    try std.testing.expect((try userDir(a.allocator(), "XDG_DESKTOP_DIR=\"$HOME/Desktop\"", "/home/a")) == null);
}

test "file names lose folders and odd characters" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const x = a.allocator();
    try std.testing.expectEqualStrings("passwd", try cleanName(x, "../../etc/passwd"));
    try std.testing.expectEqualStrings("a_b.png", try cleanName(x, "a:b.png"));
    try std.testing.expectEqualStrings("file", try cleanName(x, ".."));
    try std.testing.expectEqualStrings("file", try cleanName(x, ""));
    try std.testing.expectEqualStrings("lounge photo.png", try cleanName(x, "lounge photo.png"));
}

test "saving never overwrites" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const x = a.allocator();
    const folder = try std.fmt.allocPrint(x, ".zig-cache/tmp/{s}/dl", .{tmp.sub_path});
    const one = try save(x, io, folder, "pic.png", "one");
    const two = try save(x, io, folder, "pic.png", "two");
    const three = try save(x, io, folder, "pic.png", "three");
    try std.testing.expect(std.mem.endsWith(u8, one.path, "/dl/pic.png"));
    try std.testing.expect(std.mem.endsWith(u8, two.path, "/dl/pic (1).png"));
    try std.testing.expect(std.mem.endsWith(u8, three.path, "/dl/pic (2).png"));
    try std.testing.expectEqualStrings("one", try std.Io.Dir.cwd().readFileAlloc(io, one.path, x, .limited(100)));
    try std.testing.expectEqualStrings("two", try std.Io.Dir.cwd().readFileAlloc(io, two.path, x, .limited(100)));
}

test "paths show the home folder as ~" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const x = a.allocator();
    try std.testing.expectEqualStrings("~/Downloads/a.png", tilde(x, "/home/wes/Downloads/a.png", "/home/wes"));
    try std.testing.expectEqualStrings("/home/wesley/a.png", tilde(x, "/home/wesley/a.png", "/home/wes"));
    try std.testing.expectEqualStrings("/tmp/a.png", tilde(x, "/tmp/a.png", null));
}
