//! Desktop notifications. Text goes to the notifier as arguments (or, on
//! Windows, inside an encoded script), never through a shell string.
const std = @import("std");
const builtin = @import("builtin");
const store = @import("store");
const mrkdwn = @import("slack").mrkdwn;

/// Longest body shown, in bytes
const max_body = 240;

/// What a notification says: the message as plain text, led by its author
/// in a channel or group. Everything is allocated from `arena`.
pub fn body(arena: std.mem.Allocator, st: *const store.Store, n: store.Notice, res: mrkdwn.Resolver) std.mem.Allocator.Error![]const u8 {
    if (n.hide_text) return "New message";
    const plain = (try mrkdwn.render(arena, n.text, res)).text;
    const clipped = clip(std.mem.trim(u8, plain, " \n\r\t"));
    const group = (n.title.len > 0 and n.title[0] == '#') or std.mem.indexOfScalar(u8, n.title, ',') != null;
    if (!group or n.user.len == 0) return clipped;
    const who = st.userName(n.user) orelse n.user;
    return std.fmt.allocPrint(arena, "{s}: {s}", .{ who, clipped });
}

/// At most `max_body` bytes, cut on a character boundary
fn clip(text: []const u8) []const u8 {
    if (text.len <= max_body) return text;
    var end: usize = max_body;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

pub const Sender = *const fn (gpa: std.mem.Allocator, io: std.Io, title: []const u8, body: []const u8) void;

/// Posts one notification. Best effort: a missing notifier means no notification.
pub fn send(gpa: std.mem.Allocator, io: std.Io, title: []const u8, text: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "osascript", "-e", "on run argv", "-e", "display notification (item 1 of argv) with title (item 2 of argv)", "-e", "end run", "--", text, title },
        .windows => windowsArgv(arena, title, text) catch return,
        // `sh -c '... &' _ ARGS` backgrounds the notifier so nothing is left to reap. Its body is
        // markup, so what Slack sent as text is escaped; `--` ends options for a title like "-x"
        else => &.{ "sh", "-c", "notify-send --app-name=Lax --icon=com.gammagamma.lax --hint=string:desktop-entry:com.gammagamma.lax -- \"$1\" \"$2\" >/dev/null 2>&1 &", "lax-notify", title, escapeMarkup(arena, text) catch return },
    };
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch return;
    gpa.free(result.stdout);
    gpa.free(result.stderr);
}

/// `&`, `<` and `>` as entities, for a notifier that reads its body as markup
fn escapeMarkup(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(arena, "&amp;"),
        '<' => try out.appendSlice(arena, "&lt;"),
        '>' => try out.appendSlice(arena, "&gt;"),
        else => try out.append(arena, c),
    };
    return out.items;
}

/// A PowerShell script showing a toast, with `title` and `text` as quoted literals
fn toastScript(arena: std.mem.Allocator, title: []const u8, text: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena,
        \\[void][Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]
        \\$x=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent('ToastText02')
        \\$t=$x.GetElementsByTagName('text')
        \\[void]$t.Item(0).AppendChild($x.CreateTextNode({s}))
        \\[void]$t.Item(1).AppendChild($x.CreateTextNode({s}))
        \\$id='{{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}}\WindowsPowerShell\v1.0\powershell.exe'
        \\[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($id).Show([Windows.UI.Notifications.ToastNotification]::new($x))
    , .{ try psLiteral(arena, title), try psLiteral(arena, text) });
}

/// A PowerShell single-quoted string: only quotes (the typographic ones too) need doubling
fn psLiteral(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '\'');
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const ch = text[i..@min(i + len, text.len)];
        try out.appendSlice(arena, ch);
        for ([_][]const u8{ "'", "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}" }) |q| {
            if (std.mem.eql(u8, ch, q)) try out.appendSlice(arena, ch);
        }
        i += ch.len;
    }
    try out.append(arena, '\'');
    return out.items;
}

/// `powershell -EncodedCommand`: base64 of the UTF-16 script, so no command-line quoting applies
fn windowsArgv(arena: std.mem.Allocator, title: []const u8, text: []const u8) ![]const []const u8 {
    const script = try toastScript(arena, title, text);
    const wide = try std.unicode.utf8ToUtf16LeAlloc(arena, script);
    const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(wide.len * 2));
    _ = std.base64.standard.Encoder.encode(encoded, std.mem.sliceAsBytes(wide));
    const argv = try arena.alloc([]const u8, 5);
    argv[0] = "powershell";
    argv[1] = "-NoProfile";
    argv[2] = "-NonInteractive";
    argv[3] = "-EncodedCommand";
    argv[4] = encoded;
    return argv;
}

fn testName(_: *const anyopaque, id: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, id, "U2")) "ada" else null;
}

test "body: plain text, author in channels, clipped, hidden on request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var st = store.Store.init(std.testing.allocator);
    defer st.deinit();
    try st.apply(.{ .users = &.{.{ .id = "U2", .name = "ada" }} });
    const ctx: u8 = 0;
    const res: mrkdwn.Resolver = .{ .ctx = &ctx, .user = testName, .channel = testName };
    var n: store.Notice = .{ .team = &.{}, .channel = &.{}, .title = @constCast("#general"), .user = @constCast("U2"), .text = @constCast("*hi* <@U2> &amp; <https://x.dev|docs>"), .thread_ts = &.{}, .hide_text = false };
    try std.testing.expectEqualStrings("ada: hi @ada & docs", try body(a, &st, n, res));
    n.title = @constCast("ada");
    try std.testing.expectEqualStrings("hi @ada & docs", try body(a, &st, n, res));
    n.hide_text = true;
    try std.testing.expectEqualStrings("New message", try body(a, &st, n, res));
    // Cut on a character boundary, never inside one
    var long: [400]u8 = undefined;
    for (0..200) |i| @memcpy(long[i * 2 ..][0..2], "é");
    const cut = clip(&long);
    try std.testing.expect(cut.len <= max_body and cut.len % 2 == 0);
}

test "notifier text is escaped for its target" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("a &lt;b&gt; &amp; c", try escapeMarkup(a, "a <b> & c"));
    try std.testing.expectEqualStrings("'it''s ‘‘x’’'", try psLiteral(a, "it's ‘x’"));
    const argv = try windowsArgv(a, "t", "b");
    try std.testing.expectEqualStrings("-EncodedCommand", argv[3]);
    try std.testing.expect(argv[4].len > 0);
}
