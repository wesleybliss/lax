//! Opens a link in the user's browser. Only web and mail links, and the
//! URL is passed as an argument, never through a shell string.
const std = @import("std");
const builtin = @import("builtin");

pub fn isOpenable(url: []const u8) bool {
    inline for (.{ "https://", "http://", "mailto:" }) |scheme| {
        if (std.ascii.startsWithIgnoreCase(url, scheme)) return true;
    }
    return false;
}

pub fn open(gpa: std.mem.Allocator, io: std.Io, url: []const u8) void {
    if (!isOpenable(url)) return;
    // `sh -c '... &' _ URL` backgrounds the opener so nothing is left to reap
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .windows => &.{ "cmd", "/c", "start", "", url },
        else => &.{ "sh", "-c", "xdg-open \"$1\" >/dev/null 2>&1 &", "lax-open", url },
    };
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch return;
    gpa.free(result.stdout);
    gpa.free(result.stderr);
}

test "only web and mail links open" {
    try std.testing.expect(isOpenable("https://example.com"));
    try std.testing.expect(isOpenable("HTTP://example.com"));
    try std.testing.expect(isOpenable("mailto:a@b.c"));
    try std.testing.expect(!isOpenable("file:///etc/passwd"));
    try std.testing.expect(!isOpenable("javascript:alert(1)"));
    try std.testing.expect(!isOpenable("-oProxyCommand=x"));
}
