//! Redaction for anything that might reach a log. Tokens and cookies must
//! never be printed: wrap them in `Secret` and run free text through `scrub`.
const std = @import("std");

/// Formats as `<redacted>` no matter what. Use for tokens and cookies.
pub const Secret = struct {
    bytes: []const u8,

    pub fn format(_: Secret, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("<redacted>");
    }
};

fn isTokenByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        '%', '.', '_', '-', '+', '/', '=' => true,
        else => false,
    };
}

/// Replaces `xox?-...` runs and `token=`/`d=` values with a marker.
/// Caller owns the result.
pub fn scrub(gpa: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        const rest = text[i..];
        if (std.mem.startsWith(u8, rest, "xox") and rest.len > 4 and std.ascii.isAlphabetic(rest[3]) and rest[4] == '-') {
            var j: usize = 5;
            while (j < rest.len and isTokenByte(rest[j])) j += 1;
            try out.appendSlice(gpa, "xox-<redacted>");
            i += j;
            continue;
        }
        inline for (.{ "token=", "d=" }) |prefix| {
            if (std.mem.startsWith(u8, rest, prefix) and (i == 0 or !std.ascii.isAlphanumeric(text[i - 1]))) {
                var j: usize = prefix.len;
                while (j < rest.len and isTokenByte(rest[j])) j += 1;
                try out.appendSlice(gpa, prefix);
                try out.appendSlice(gpa, "<redacted>");
                i += j;
                break;
            }
        } else {
            try out.append(gpa, text[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

test "scrub removes tokens and cookie values" {
    const gpa = std.testing.allocator;
    const out = try scrub(gpa, "Cookie: d=xoxd-AbC%2Bdef; auth xoxc-123-456-abc ok token=xyz&x=1");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("Cookie: d=<redacted>; auth xox-<redacted> ok token=<redacted>&x=1", out);
}

test "Secret never formats its bytes" {
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{f}", .{Secret{ .bytes = "xoxc-secret" }});
    try std.testing.expectEqualStrings("<redacted>", s);
}
