//! The message box's formatting buttons: what each does to the text in
//! Slack's own markup (`*bold*`, `_italic_`, `~strike~`, `` `code` ``, `> quote`).
//! Pure edits on a text buffer: a selection in, the selection to show out.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const Kind = enum { bold, italic, strike, code, code_block, quote, bullets, numbers, link };

const bullet = "• ";
const quote = "> ";
const fence_open = "```\n";
const fence_close = "\n```";

/// What `kind` does to the bytes `sel` ([from, to)) of `b`; the selection afterwards.
/// `url` is what a link points at (null: a placeholder to type over).
pub fn apply(gpa: std.mem.Allocator, b: *ui.TextBuffer, sel: [2]usize, kind: Kind, url: ?[]const u8) [2]usize {
    const len = b.text().len;
    const from = @min(sel[0], sel[1], len);
    const to = @min(@max(sel[0], sel[1]), len);
    return switch (kind) {
        .bold => wrap(b, from, to, "*"),
        .italic => wrap(b, from, to, "_"),
        .strike => wrap(b, from, to, "~"),
        .code => wrap(b, from, to, "`"),
        .code_block => fence(b, from, to),
        .quote, .bullets, .numbers => lines(gpa, b, from, to, kind),
        .link => link(gpa, b, from, to, url),
    };
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\n' or ch == '\t' or ch == '\r';
}

/// Markers around the selection, or off again if they are already there.
/// Spaces at the selection's edges stay outside: Slack wants the marker
/// right against the word.
fn wrap(b: *ui.TextBuffer, from: usize, to: usize, marker: []const u8) [2]usize {
    const t = b.text();
    var lo = from;
    var hi = to;
    while (lo < hi and isSpace(t[lo])) lo += 1;
    while (hi > lo and isSpace(t[hi - 1])) hi -= 1;
    const n = marker.len;
    if (lo >= n and hi + n <= t.len and std.mem.eql(u8, t[lo - n .. lo], marker) and std.mem.eql(u8, t[hi .. hi + n], marker)) {
        b.remove(hi, hi + n);
        b.remove(lo - n, lo);
        return .{ lo - n, hi - n };
    }
    _ = b.insert(hi, marker);
    _ = b.insert(lo, marker);
    return .{ lo + n, hi + n };
}

/// A fenced block around the selection (or an empty one to type in), or removed
fn fence(b: *ui.TextBuffer, from: usize, to: usize) [2]usize {
    const t = b.text();
    const o = fence_open.len;
    const e = fence_close.len;
    if (from >= o and to + e <= t.len and std.mem.eql(u8, t[from - o .. from], fence_open) and std.mem.eql(u8, t[to .. to + e], fence_close)) {
        b.remove(to, to + e);
        b.remove(from - o, from);
        return .{ from - o, to - o };
    }
    _ = b.insert(to, fence_close);
    _ = b.insert(from, fence_open);
    return .{ from + o, to + o };
}

fn lineStart(t: []const u8, at: usize) usize {
    var i = at;
    while (i > 0 and t[i - 1] != '\n') i -= 1;
    return i;
}

fn lineEnd(t: []const u8, at: usize) usize {
    var i = at;
    while (i < t.len and t[i] != '\n') i += 1;
    return i;
}

/// Length of the list or quote marker `kind` starts `line` with, 0 if none
fn markerLen(line: []const u8, kind: Kind) usize {
    switch (kind) {
        .quote => return if (std.mem.startsWith(u8, line, quote)) quote.len else 0,
        .bullets => return if (std.mem.startsWith(u8, line, bullet)) bullet.len else 0,
        .numbers => {
            var i: usize = 0;
            while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
            if (i == 0 or !std.mem.startsWith(u8, line[i..], ". ")) return 0;
            return i + 2;
        },
        else => return 0,
    }
}

/// A marker at the start of every line the selection touches; off again
/// when all of them have it
fn lines(gpa: std.mem.Allocator, b: *ui.TextBuffer, from: usize, to: usize, kind: Kind) [2]usize {
    const t = b.text();
    const start = lineStart(t, from);
    // A selection ending right after a line break leaves the next line alone
    const end = lineEnd(t, if (to > from and t[to - 1] == '\n') to - 1 else to);
    const block = t[start..end];
    var all_marked = true;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, block, '\n');
    while (it.next()) |line| {
        count += 1;
        if (line.len > 0 and markerLen(line, kind) == 0) all_marked = false;
    }
    if (count == 1 and block.len == 0) all_marked = false;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var number: usize = 1;
    it = std.mem.splitScalar(u8, block, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) out.append(gpa, '\n') catch return .{ from, to };
        first = false;
        const bare = line[markerLen(line, kind)..];
        if (all_marked) {
            out.appendSlice(gpa, bare) catch return .{ from, to };
            continue;
        }
        // Blank lines in a longer block stay blank
        if (line.len == 0 and count > 1) continue;
        switch (kind) {
            .quote => out.appendSlice(gpa, quote) catch return .{ from, to },
            .bullets => out.appendSlice(gpa, bullet) catch return .{ from, to },
            else => {
                var num: [24]u8 = undefined;
                const label = std.fmt.bufPrint(&num, "{d}. ", .{number}) catch unreachable;
                out.appendSlice(gpa, label) catch return .{ from, to };
                number += 1;
            },
        }
        out.appendSlice(gpa, bare) catch return .{ from, to };
    }
    const n = b.replace(start, end, out.items);
    return .{ start + n, start + n };
}

/// `<url|text>` around the selection. With no url the address is a
/// placeholder, selected to type over; with one, the text is.
fn link(gpa: std.mem.Allocator, b: *ui.TextBuffer, from: usize, to: usize, url: ?[]const u8) [2]usize {
    const placeholder = "https://";
    const address = url orelse placeholder;
    const label = if (to > from) gpa.dupe(u8, b.text()[from..to]) catch return .{ from, to } else gpa.dupe(u8, if (url == null) "link" else address) catch return .{ from, to };
    defer gpa.free(label);
    const full = std.fmt.allocPrint(gpa, "<{s}|{s}>", .{ address, label }) catch return .{ from, to };
    defer gpa.free(full);
    if (b.replace(from, to, full) == 0) return .{ from, to };
    if (url == null) return .{ from + 1, from + 1 + address.len };
    return .{ from + 2 + address.len, from + 2 + address.len + label.len };
}

fn check(kind: Kind, text: []const u8, sel: [2]usize, url: ?[]const u8, want_text: []const u8, want_sel: [2]usize) !void {
    const gpa = std.testing.allocator;
    var b: ui.TextBuffer = .{};
    defer b.deinit();
    b.set(text);
    const got = apply(gpa, &b, sel, kind, url);
    try std.testing.expectEqualStrings(want_text, b.text());
    try std.testing.expectEqual(want_sel, got);
}

test "inline marks wrap the selection and come off again" {
    try check(.bold, "say hello now", .{ 4, 9 }, null, "say *hello* now", .{ 5, 10 });
    try check(.bold, "say *hello* now", .{ 5, 10 }, null, "say hello now", .{ 4, 9 });
    try check(.italic, "x", .{ 1, 1 }, null, "x__", .{ 2, 2 });
    try check(.strike, "a b", .{ 0, 3 }, null, "~a b~", .{ 1, 4 });
    // Spaces at the edges stay outside the marks
    try check(.code, "a  hi  b", .{ 1, 7 }, null, "a  `hi`  b", .{ 4, 6 });
}

test "code block fences the selection" {
    try check(.code_block, "ls -la", .{ 0, 6 }, null, "```\nls -la\n```", .{ 4, 10 });
    try check(.code_block, "```\nls -la\n```", .{ 4, 10 }, null, "ls -la", .{ 0, 6 });
    try check(.code_block, "", .{ 0, 0 }, null, "```\n\n```", .{ 4, 4 });
}

test "quote and lists mark every line they touch" {
    try check(.quote, "one\ntwo", .{ 0, 7 }, null, "> one\n> two", .{ 11, 11 });
    try check(.quote, "> one\n> two", .{ 0, 11 }, null, "one\ntwo", .{ 7, 7 });
    try check(.bullets, "a\n\nb", .{ 0, 4 }, null, "• a\n\n• b", .{ 12, 12 });
    try check(.numbers, "a\nb\nc", .{ 0, 5 }, null, "1. a\n2. b\n3. c", .{ 14, 14 });
    try check(.numbers, "1. a\n2. b", .{ 0, 9 }, null, "a\nb", .{ 3, 3 });
    // Only the lines touched; a mixed block gets the marker on all
    try check(.bullets, "x\ny\nz", .{ 2, 3 }, null, "x\n• y\nz", .{ 7, 7 });
    try check(.bullets, "• a\nb", .{ 0, 7 }, null, "• a\n• b", .{ 11, 11 });
    try check(.bullets, "", .{ 0, 0 }, null, "• ", .{ 4, 4 });
}

test "link wraps the selection, or leaves an address to type over" {
    try check(.link, "see docs now", .{ 4, 8 }, "https://x.dev", "see <https://x.dev|docs> now", .{ 19, 23 });
    try check(.link, "see docs now", .{ 4, 8 }, null, "see <https://|docs> now", .{ 5, 13 });
    try check(.link, "", .{ 0, 0 }, null, "<https://|link>", .{ 1, 9 });
}
