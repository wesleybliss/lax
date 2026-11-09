//! Pictures kept on disk so they are not downloaded again:
//! `<cache dir>/images/<hash of the URL>`. A picture's URL names its bytes
//! (a profile picture's changes with the picture), so no expiry check is
//! needed on read. Every time one is stored, whatever is older than
//! `max_age_days` is deleted.
const std = @import("std");

const sub_dir = "images";
pub const max_age_days = 30;
const max_age_ns: i96 = @as(i96, max_age_days) * 24 * 60 * 60 * std.time.ns_per_s;

fn file_mode() std.Io.File.Permissions {
    return if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(0o600) else .default_file;
}

fn dir_mode() std.Io.File.Permissions {
    return if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(0o700) else .default_file;
}

/// The file name for `url`: its SHA-256, hex (32 characters of it)
fn keyName(buf: *[32]u8, url: []const u8) []const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
    return std.fmt.bufPrint(buf, "{x}", .{digest[0..16]}) catch unreachable;
}

/// The picture cached for `url`, or null. Owned by `arena`.
pub fn get(arena: std.mem.Allocator, io: std.Io, dir: []const u8, url: []const u8, limit: usize) ?[]u8 {
    var key: [32]u8 = undefined;
    const path = std.fs.path.join(arena, &.{ dir, sub_dir, keyName(&key, url) }) catch return null;
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(limit)) catch null;
}

/// Keeps `bytes` as the picture for `url`, then deletes what is too old
pub fn put(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, url: []const u8, bytes: []const u8) void {
    const images = std.fs.path.join(gpa, &.{ dir, sub_dir }) catch return;
    defer gpa.free(images);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, images, dir_mode()) catch return;
    var key: [32]u8 = undefined;
    const name = keyName(&key, url);
    const path = std.fs.path.join(gpa, &.{ images, name }) catch return;
    defer gpa.free(path);
    // A temp file renamed over the old one: a crash never leaves half a picture
    const tmp = std.fmt.allocPrint(gpa, "{s}.tmp", .{path}) catch return;
    defer gpa.free(tmp);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = bytes, .flags = .{ .permissions = file_mode() } }) catch return;
    std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io) catch return;
    sweep(io, images, std.Io.Timestamp.now(io, .real));
}

/// Deletes the files in `images_dir` last written more than `max_age_days`
/// before `now`. Best effort: what cannot be read or deleted stays.
pub fn sweep(io: std.Io, images_dir: []const u8, now: std.Io.Timestamp) void {
    var d = std.Io.Dir.cwd().openDir(io, images_dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const st = d.statFile(io, entry.name, .{}) catch continue;
        if (now.nanoseconds - st.mtime.nanoseconds <= max_age_ns) continue;
        d.deleteFile(io, entry.name) catch {};
    }
}

test "a stored picture is read back, other URLs miss" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/lax", .{tmp.sub_path});

    try std.testing.expect(get(arena, io, dir, "https://files.slack.com/a.png", 1 << 20) == null);
    put(gpa, io, dir, "https://files.slack.com/a.png", "png-bytes");
    try std.testing.expectEqualStrings("png-bytes", get(arena, io, dir, "https://files.slack.com/a.png", 1 << 20).?);
    try std.testing.expect(get(arena, io, dir, "https://files.slack.com/b.png", 1 << 20) == null);
    // Stored again, replaced
    put(gpa, io, dir, "https://files.slack.com/a.png", "new");
    try std.testing.expectEqualStrings("new", get(arena, io, dir, "https://files.slack.com/a.png", 1 << 20).?);
}

test "storing a picture deletes those older than 30 days, and only those" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/lax", .{tmp.sub_path});
    const images = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, sub_dir });

    put(gpa, io, dir, "https://x/old.png", "old");
    put(gpa, io, dir, "https://x/new.png", "new");
    const now = std.Io.Timestamp.now(io, .real);
    const day: i96 = 24 * 60 * 60 * std.time.ns_per_s;

    // 29 days on: both stay
    sweep(io, images, .{ .nanoseconds = now.nanoseconds + 29 * day });
    try std.testing.expect(get(arena, io, dir, "https://x/old.png", 1 << 20) != null);
    try std.testing.expect(get(arena, io, dir, "https://x/new.png", 1 << 20) != null);

    // Age one picture to 31 days; the other is fresh
    var key: [32]u8 = undefined;
    var d = try std.Io.Dir.cwd().openDir(io, images, .{});
    defer d.close(io);
    try d.setTimestamps(io, keyName(&key, "https://x/old.png"), .{
        .access_timestamp = .{ .new = .{ .nanoseconds = now.nanoseconds - 31 * day } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = now.nanoseconds - 31 * day } },
    });
    put(gpa, io, dir, "https://x/third.png", "third");
    try std.testing.expect(get(arena, io, dir, "https://x/old.png", 1 << 20) == null);
    try std.testing.expect(get(arena, io, dir, "https://x/new.png", 1 << 20) != null);
    try std.testing.expect(get(arena, io, dir, "https://x/third.png", 1 << 20) != null);
}
