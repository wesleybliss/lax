const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const chat = @import("chat_view.zig");
const layout_mod = @import("layout.zig");

fn newTester(t: *ui.Tester, state: *chat.State) !void {
    try t.init(std.testing.allocator, .init(state, chat.State.view), .{ .width = 900, .height = 700, .scale = 1 });
}

test "10k messages: builds only the rows in view, anchored to the newest" {
    var state: chat.State = undefined;
    try state.init(std.testing.allocator, 10_000);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try newTester(&t, &state);
    defer t.deinit();
    for (0..5) |_| t.frame();
    try std.testing.expect(state.list.built > 0);
    try std.testing.expect(state.list.built < 100);
    try t.screenshot("/tmp/lax-bottom.png");
    const last = state.messages.items[state.messages.items.len - 1].text;
    // The first paragraph of the newest message is on screen
    const first_par = last[0 .. std.mem.indexOfScalar(u8, last, '\n') orelse last.len];
    try std.testing.expect(t.hasText(first_par));
    try t.screenshot("/tmp/lax-bottom.png");
}

test "scrolling up reveals older messages and keeps rows bounded" {
    var state: chat.State = undefined;
    try state.init(std.testing.allocator, 10_000);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try newTester(&t, &state);
    defer t.deinit();
    for (0..5) |_| t.frame();
    for (0..40) |_| {
        t.scroll(450, 300, 300);
        t.frame();
        try std.testing.expect(state.list.built < 100);
    }
    try t.screenshot("/tmp/lax-scrolled.png");
}

test "composer: Return sends, Shift+Return would break the line" {
    var state: chat.State = undefined;
    try state.init(std.testing.allocator, 50);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try newTester(&t, &state);
    defer t.deinit();
    t.frame();
    try t.clickText("Message #general");
    t.typeText("hello from the test");
    t.key(.enter);
    for (0..3) |_| t.frame();
    try std.testing.expectEqual(@as(usize, 51), state.messages.items.len);
    try std.testing.expect(t.hasText("hello from the test"));
}

/// A long text node near the top of the view, to follow across frames
fn trackTarget(t: *ui.Tester) ?struct { text: []const u8, y: f32 } {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (tx.str.len > 60 and n.rect.y > 60 and n.rect.y < 500) return .{ .text = tx.str, .y = n.rect.y },
        else => {},
    };
    return null;
}

test "scrolling through estimated heights does not make content jump" {
    var state: chat.State = undefined;
    try state.init(std.testing.allocator, 10_000);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try newTester(&t, &state);
    defer t.deinit();
    for (0..5) |_| t.frame();

    const step: f32 = 53;
    var checked: usize = 0;
    var jumps: usize = 0;
    for (0..150) |_| {
        const target = trackTarget(&t) orelse continue;
        t.scroll(450, 300, step); // positive: scrolls up, content moves down
        t.frame();
        t.frame();
        const now = t.findText(target.text) orelse continue;
        checked += 1;
        if (@abs((now.y - target.y) - step) > 1.5) jumps += 1;
    }
    std.debug.print("anchor check: {d} steps tracked, {d} jumps\n", .{ checked, jumps });
    try std.testing.expect(checked > 100);
    try std.testing.expectEqual(@as(usize, 0), jumps);
}

test "resize keeps the newest message in view" {
    var state: chat.State = undefined;
    try state.init(std.testing.allocator, 10_000);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try newTester(&t, &state);
    defer t.deinit();
    for (0..3) |_| t.frame();
    t.size = .{ .w = 520, .h = 480 };
    for (0..6) |_| t.frame();
    const last = state.messages.items[state.messages.items.len - 1].text;
    const first_par = last[0 .. std.mem.indexOfScalar(u8, last, '\n') orelse last.len];
    // Wrapped differently now, so look for the first line's start instead
    var found = false;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, first_par)) {
            found = true;
        },
        else => {},
    };
    try std.testing.expect(found);
    try t.screenshot("/tmp/lax-resized.png");
}

fn rssKb() usize {
    var buf: [128]u8 = undefined;
    const data = std.Io.Dir.cwd().readFile(std.testing.io, "/proc/self/statm", &buf) catch return 0;
    var it = std.mem.tokenizeScalar(u8, data, ' ');
    _ = it.next();
    const pages = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch 0;
    return pages * 4;
}

test "frame time and memory at 10k messages" {
    var state: chat.State = undefined;
    try state.init(std.testing.allocator, 10_000);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try newTester(&t, &state);
    defer t.deinit();
    for (0..5) |_| t.frame();
    const start = std.Io.Timestamp.now(std.testing.io, .awake);
    const frames = 300;
    for (0..frames) |_| {
        t.scroll(450, 300, 90);
        t.frame();
    }
    const ns: f64 = @floatFromInt(start.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).toNanoseconds());
    std.debug.print("10k messages: {d:.2} ms/frame over {d} scrolled frames (debug build), rss {d} KB\n", .{ ns / frames / 1e6, frames, rssKb() });
}

test "composer: Shift+Return breaks the line, Return sends it all" {
    var state: chat.State = undefined;
    try state.init(std.testing.allocator, 50);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try newTester(&t, &state);
    defer t.deinit();
    t.frame();
    try t.clickText("Message #general");
    t.typeText("line one");
    t.ctx.input.shift = true;
    t.key(.enter);
    t.ctx.input.shift = false;
    t.typeText("line two");
    try std.testing.expectEqual(@as(usize, 50), state.messages.items.len);
    try std.testing.expectEqualStrings("line one\nline two", state.input.text());
    t.key(.enter);
    for (0..3) |_| t.frame();
    try std.testing.expectEqual(@as(usize, 51), state.messages.items.len);
    try std.testing.expectEqualStrings("line one\nline two", state.messages.items[50].text);
    try std.testing.expectEqualStrings("", state.input.text());
}

test "message text selects across rows and copies" {
    var state: chat.State = undefined;
    try state.init(std.testing.allocator, 10_000);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try newTester(&t, &state);
    defer t.deinit();
    for (0..5) |_| t.frame();

    var first: ?struct { text: []const u8, r: ui.Rect } = null;
    var second: ?struct { text: []const u8, r: ui.Rect } = null;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (tx.str.len > 30 and n.rect.y > 60 and n.rect.y < 400) {
            if (first == null) first = .{ .text = tx.str, .r = n.rect } else if (second == null) second = .{ .text = tx.str, .r = n.rect };
        },
        else => {},
    };
    const a = first.?;
    const b = second.?;
    t.drag(a.r.x + 1, a.r.y + 3, b.r.x + b.r.w - 2, b.r.y + b.r.h - 3);
    t.settle(1);
    t.textOps(&.{.{ .command = .copy }});
    const copied = t.clipboard.items;
    try std.testing.expect(std.mem.indexOf(u8, copied, a.text[0..15]) != null);
    try std.testing.expect(std.mem.indexOf(u8, copied, b.text[0..15]) != null);
}

const app_view = @import("app_view.zig");
const store = @import("store");

var last_link: [128]u8 = undefined;
var last_link_len: usize = 0;

fn fakeOpener(_: std.mem.Allocator, _: std.Io, url: []const u8) void {
    @memcpy(last_link[0..url.len], url);
    last_link_len = url.len;
}

const Fake = struct {
    opened: ?[]const u8 = null,
    team: ?[]const u8 = null,
    manual_len: usize = 0,
    sent_text: [256]u8 = undefined,
    sent_len: usize = 0,
    sent_thread: bool = false,
    react_name: [32]u8 = undefined,
    react_len: usize = 0,
    react_add: bool = false,
    older_calls: usize = 0,
    thread_calls: usize = 0,
    typing_calls: usize = 0,
    away: ?bool = null,

    fn actions(f: *Fake) app_view.Actions {
        return .{
            .ctx = f,
            .open = open,
            .send = send,
            .older = older,
            .open_thread = openThread,
            .react = react,
            .typing = typing,
            .mark = mark,
            .switch_team = switchTeam,
            .manual = manual,
            .set_presence = setPresence,
        };
    }

    fn setPresence(ctx: *anyopaque, away: bool) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.away = away;
    }

    fn open(ctx: *anyopaque, channel: []const u8) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.opened = channel;
    }
    fn send(ctx: *anyopaque, _: []const u8, text: []const u8, thread_ts: ?[]const u8) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        @memcpy(f.sent_text[0..text.len], text);
        f.sent_len = text.len;
        f.sent_thread = thread_ts != null;
    }
    fn older(ctx: *anyopaque, _: []const u8, _: []const u8) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.older_calls += 1;
    }
    fn openThread(ctx: *anyopaque, _: []const u8, _: []const u8) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.thread_calls += 1;
    }
    fn react(ctx: *anyopaque, _: []const u8, _: []const u8, name: []const u8, add: bool) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        @memcpy(f.react_name[0..name.len], name);
        f.react_len = name.len;
        f.react_add = add;
    }
    fn typing(ctx: *anyopaque, _: []const u8) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.typing_calls += 1;
    }
    fn mark(_: *anyopaque, _: []const u8, _: []const u8) void {}
    fn switchTeam(ctx: *anyopaque, team: []const u8) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.team = team;
    }
    fn manual(ctx: *anyopaque, url: []const u8, token: []const u8, cookie: []const u8) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.manual_len = url.len + token.len + cookie.len;
    }
};

fn seedStore(st: *store.Store) !void {
    try st.apply(.{ .self = .{ .user_id = "U1", .team_name = "Acme" } });
    try st.apply(.{ .users = &.{ .{ .id = "U1", .name = "Alex" }, .{ .id = "U2", .name = "Grace" } } });
    try st.apply(.{ .channels = &.{
        .{ .id = "C1", .name = "general", .kind = .channel },
        .{ .id = "C2", .name = "dev", .kind = .channel },
        .{ .id = "C3", .name = "secret", .kind = .private },
        .{ .id = "D1", .name = "", .kind = .im, .user_id = "U2" },
        .{ .id = "G1", .name = "ada, grace, sam", .kind = .mpim },
    } });
    try st.apply(.{ .history = .{ .channel = "C1", .messages = &.{
        .{ .ts = "1700000000.000100", .user = "U2", .text = "morning! *deploy* is green, see <https://example.com/run/1|the run>" },
        .{ .ts = "1700000060.000100", .user = "U2", .text = "cc <@U1> and <#C2|dev>\n&gt; quoted reply\n```\nzig build test\n```" },
        .{ .ts = "1700000100.000100", .user = "U1", .text = "nice. `zig build` took _4s_ & passed ~flaky~" },
    } } });
}

test "real view: sidebar, mrkdwn messages, selection and send" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    try seedStore(&st);
    var fake: Fake = .{};
    var state = app_view.State.init(gpa, std.testing.io, &st, fake.actions());
    defer state.deinit();
    state.preferred = "C1";
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();

    try std.testing.expectEqualStrings("C1", fake.opened.?);
    try std.testing.expect(t.hasText("general"));
    try std.testing.expect(t.hasText("Grace"));
    try t.screenshot("/tmp/lax-app.png");
    try std.testing.expect(t.hasText("morning! deploy is green, see the run"));
    // mrkdwn resolved: mention and channel names, entities, code
    try std.testing.expect(t.hasText("cc @Alex and #dev"));
    try std.testing.expect(t.hasText("quoted reply"));

    // Click another conversation
    try t.clickText("dev");
    for (0..3) |_| t.frame();
    try std.testing.expectEqualStrings("C2", fake.opened.?);

    // A new message elsewhere flags the conversation unread
    try st.apply(.{ .message = .{ .channel = "C3", .message = .{ .ts = "1700000200.000100", .user = "U2", .text = "psst" } } });
    try std.testing.expect(st.channel("C3").?.unread);
    t.frame();
    try t.screenshot("/tmp/lax-app-unread.png");

    // Composer sends to the selected conversation
    try t.clickText("Message #dev");
    t.typeText("hello team");
    t.key(.enter);
    t.frame();
    try std.testing.expectEqualStrings("hello team", fake.sent_text[0..fake.sent_len]);
}

test "links: hand cursor on hover, click opens, text elsewhere keeps the text cursor" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    try seedStore(&st);
    var fake: Fake = .{};
    var state = app_view.State.init(gpa, std.testing.io, &st, fake.actions());
    defer state.deinit();
    state.preferred = "C1";
    state.opener = fakeOpener;
    last_link_len = 0;
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();

    const text = "morning! deploy is green, see the run";
    const r = t.findText(text).?;
    const style: ui.TextStyle = .{ .size = 15, .wrap = true, .line_height = 22 };
    const link_x = r.x + t.ctx.text.caretX(text, style, text.len - 3);
    const y = r.y + 11;
    t.moveTo(link_x, y);
    t.frame();
    try std.testing.expectEqual(ui.Cursor.hand, t.ctx.cursor.?);
    t.moveTo(r.x + 5, y);
    t.frame();
    try std.testing.expect(t.ctx.cursor == null);
    try std.testing.expect(t.ctx.cursor_text);
    t.click(link_x, y);
    t.frame();
    try std.testing.expectEqualStrings("https://example.com/run/1", last_link[0..last_link_len]);
}

test "composer pins the text cursor while hovered" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    try seedStore(&st);
    var fake: Fake = .{};
    var state = app_view.State.init(gpa, std.testing.io, &st, fake.actions());
    defer state.deinit();
    state.preferred = "C1";
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();
    const r = t.findText("Message #general").?;
    t.moveTo(r.x + 20, r.y + 4);
    for (0..6) |_| {
        t.frame();
        try std.testing.expectEqual(ui.Cursor.text, t.ctx.cursor.?);
    }
}

fn newFakeState(gpa: std.mem.Allocator, st: *store.Store, fake: *Fake) app_view.State {
    return app_view.State.init(gpa, std.testing.io, st, fake.actions());
}

test "rail: clicking a workspace shows it at once, and switching back finds it cached" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    try st.apply(.{ .teams = .{ .list = &.{ .{ .id = "T1", .name = "Acme", .url = "u1" }, .{ .id = "T2", .name = "Side Project", .url = "u2" } }, .active = "T1" } });
    try seedStore(&st);
    var fake: Fake = .{};
    var state = newFakeState(gpa, &st, &fake);
    defer state.deinit();
    state.preferred = "C1";
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();
    try t.screenshot("/tmp/lax-rail.png");
    try std.testing.expect(t.hasText("A"));
    try t.clickText("S");
    for (0..3) |_| t.frame();
    try std.testing.expectEqualStrings("T2", fake.team.?);
    // The UI shows the other workspace without waiting for the network
    try std.testing.expectEqualStrings("T2", st.active_team);
    try std.testing.expect(state.selected == null);
    try std.testing.expectEqual(@as(usize, 0), st.channels.items.len);
    // Late updates for the first workspace land in its parked data
    var late: store.Item = .{ .arena = std.heap.ArenaAllocator.init(gpa), .update = .{ .message = .{ .channel = "C1", .message = .{ .ts = "1700000900.000100", .user = "U2", .text = "while you were away" } } } };
    defer late.arena.deinit();
    late.setTeam("T1");
    try st.applyItem(&late);
    try std.testing.expectEqual(@as(usize, 0), st.channels.items.len);
    // Back to the first: its channels, selection and messages are all there
    try t.clickText("A");
    for (0..4) |_| t.frame();
    try std.testing.expectEqualStrings("T1", fake.team.?);
    try std.testing.expectEqualStrings("C1", state.selected.?);
    try std.testing.expect(t.hasText("while you were away"));
}

test "manual sign-in: shown on need_manual, submits the three fields" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    var fake: Fake = .{};
    var state = newFakeState(gpa, &st, &fake);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 760, .scale = 1 });
    defer t.deinit();
    try st.apply(.{ .need_manual = "Could not read a Slack session from the desktop app." });
    for (0..3) |_| t.frame();
    try t.screenshot("/tmp/lax-manual.png");
    try std.testing.expect(t.hasText("Sign in to Slack"));
    try std.testing.expect(t.hasText("Could not read a Slack session from the desktop app."));

    try t.clickText("https://yourteam.slack.com");
    t.typeText("acme.slack.com");
    try t.clickText("xoxc-…");
    t.typeText("xoxc-1-2-3-abc");
    try t.clickText("xoxd-…");
    t.typeText("xoxd-cookie");
    t.frame();
    try t.clickText("Connect");
    t.frame();
    try std.testing.expectEqual(@as(usize, "acme.slack.com".len + "xoxc-1-2-3-abc".len + "xoxd-cookie".len), fake.manual_len);

    // Working credentials hide it again
    try st.apply(.manual_done);
    for (0..3) |_| t.frame();
    try std.testing.expect(!t.hasText("Sign in to Slack"));
}

fn seedFor(gpa: std.mem.Allocator, st: *store.Store, fake: *Fake) !app_view.State {
    try seedStore(st);
    var state = newFakeState(gpa, st, fake);
    state.preferred = "C1";
    return state;
}

test "reactions: pills show, clicking toggles, toolbar reacts" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    var fake: Fake = .{};
    var state = try seedFor(gpa, &st, &fake);
    defer state.deinit();
    try st.apply(.{ .reaction = .{ .channel = "C1", .ts = "1700000100.000100", .name = "tada", .user = "U2", .added = true } });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();
    try t.screenshot("/tmp/lax-reactions.png");
    try std.testing.expect(t.hasText("🎉 1"));
    try t.clickText("🎉 1");
    t.frame();
    try std.testing.expectEqualStrings("tada", fake.react_name[0..fake.react_len]);
    try std.testing.expect(fake.react_add);
}

test "threads: reply link opens the panel, replies show, thread composer sends in the thread" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    var fake: Fake = .{};
    var state = try seedFor(gpa, &st, &fake);
    defer state.deinit();
    try st.apply(.{ .reply_count = .{ .channel = "C1", .ts = "1700000000.000100", .count = 2 } });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1200, .height = 700, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();
    try std.testing.expect(t.hasText("2 replies"));
    try t.clickText("2 replies");
    for (0..3) |_| t.frame();
    try std.testing.expectEqual(@as(usize, 1), fake.thread_calls);
    try std.testing.expect(st.thread != null);
    try std.testing.expect(t.hasText("Thread"));
    try std.testing.expect(!st.thread.?.loaded);

    try st.apply(.{ .thread_history = .{ .channel = "C1", .thread_ts = "1700000000.000100", .messages = &.{
        .{ .ts = "1700000000.000100", .user = "U2", .text = "root message" },
        .{ .ts = "1700000020.000100", .user = "U1", .text = "a reply here" },
    } } });
    for (0..3) |_| t.frame();
    try t.screenshot("/tmp/lax-thread.png");
    try std.testing.expect(t.hasText("a reply here"));

    try t.clickText("Reply…");
    t.typeText("thread answer");
    t.key(.enter);
    t.frame();
    try std.testing.expectEqualStrings("thread answer", fake.sent_text[0..fake.sent_len]);
    try std.testing.expect(fake.sent_thread);

    try t.clickText("✕");
    for (0..2) |_| t.frame();
    try std.testing.expect(st.thread == null);
}

test "typing indicator, presence dot, and older page request" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    var fake: Fake = .{};
    var state = try seedFor(gpa, &st, &fake);
    defer state.deinit();
    try st.apply(.{ .typing = .{ .channel = "C1", .user = "U2", .at_ms = store.nowMs(std.testing.io) } });
    try st.apply(.{ .presence = .{ .users = &.{"U2"}, .active = true } });
    try st.apply(.{ .history = .{ .channel = "C1", .has_more = true, .messages = &.{} } });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();
    try t.screenshot("/tmp/lax-typing.png");
    try std.testing.expect(t.hasText("Grace is typing…"));
    // The list is short, so the top is in view: the older page is asked for once
    try std.testing.expectEqual(@as(usize, 1), fake.older_calls);
    for (0..3) |_| t.frame();
    try std.testing.expectEqual(@as(usize, 1), fake.older_calls);

    // Typing in the composer tells Slack
    try t.clickText("Message #general");
    t.typeText("hi");
    t.frame();
    try std.testing.expect(fake.typing_calls >= 1);
}

test "an older page keeps the reader's place" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    var fake: Fake = .{};
    var state = try seedFor(gpa, &st, &fake);
    defer state.deinit();
    // A long channel, with more on the server
    var buf: [32]u8 = undefined;
    var infos: [80]store.MessageInfo = undefined;
    for (&infos, 0..) |*info, i| {
        const ts = try std.fmt.allocPrint(std.testing.allocator, "{d}.000100", .{1700001000 + i * 30});
        defer std.testing.allocator.free(ts);
        _ = &buf;
        info.* = .{ .ts = try gpa.dupe(u8, ts), .user = "U2", .text = "message number to make the list long enough to scroll around in" };
    }
    defer for (infos) |info| gpa.free(info.ts);
    try st.apply(.{ .history = .{ .channel = "C1", .has_more = true, .messages = &infos } });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..5) |_| t.frame();
    // Scroll up to near the top: the older page is requested
    for (0..60) |_| {
        t.scroll(600, 300, 400);
        t.frame();
    }
    try std.testing.expect(fake.older_calls >= 1);
    const c = st.channel("C1").?;
    const before = c.messages.items.len;

    // Track something on screen, then deliver the older page
    var target: ?[]const u8 = null;
    var target_y: f32 = 0;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (tx.str.len > 40 and n.rect.y > 100 and n.rect.y < 400) {
            target = tx.str;
            target_y = n.rect.y;
            break;
        },
        else => {},
    };
    var older: [30]store.MessageInfo = undefined;
    for (&older, 0..) |*info, i| {
        const ts = try std.fmt.allocPrint(gpa, "{d}.000100", .{1699990000 + i * 30});
        defer gpa.free(ts);
        info.* = .{ .ts = try gpa.dupe(u8, ts), .user = "U2", .text = "an older message that came in the second page of history here" };
    }
    defer for (older) |info| gpa.free(info.ts);
    try st.apply(.{ .history = .{ .channel = "C1", .older = true, .has_more = true, .messages = &older } });
    try std.testing.expectEqual(before + 30, c.messages.items.len);
    for (0..4) |_| t.frame();
    if (target) |text| {
        // The same text sits at (nearly) the same y: nothing jumped
        var found: ?f32 = null;
        for (t.ctx.nodes.items) |n| switch (n.content) {
            .text => |tx| if (std.mem.eql(u8, tx.str, text)) {
                found = n.rect.y;
            },
            else => {},
        };
        if (found) |y| try std.testing.expect(@abs(y - target_y) < 40);
    }
}

test "hover toolbar shows quick reactions and Reply" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    var fake: Fake = .{};
    var state = try seedFor(gpa, &st, &fake);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();
    const r = t.findText("morning! deploy is green, see the run").?;
    t.moveTo(r.x + 100, r.y + 10);
    for (0..3) |_| t.frame();
    try t.screenshot("/tmp/lax-hover.png");
    try std.testing.expect(t.hasText("Reply"));
    try t.clickText("Reply");
    for (0..2) |_| t.frame();
    try std.testing.expectEqual(@as(usize, 1), fake.thread_calls);
}

test "completion: @mention expands to Slack's form, :emoji: and #channel complete" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    var fake: Fake = .{};
    var state = try seedFor(gpa, &st, &fake);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();

    try t.clickText("Message #general");
    t.typeText("hello @gr");
    for (0..2) |_| t.frame();
    try t.screenshot("/tmp/lax-complete.png");
    try std.testing.expect(t.hasText("@Grace"));
    // Tab takes the suggestion instead of moving focus or sending
    t.key(.tab);
    for (0..2) |_| t.frame();
    try std.testing.expectEqualStrings("hello @Grace ", state.main_composer.text());
    t.typeText("see #de");
    for (0..2) |_| t.frame();
    try std.testing.expect(t.hasText("#dev"));
    t.key(.enter);
    for (0..2) |_| t.frame();
    try std.testing.expectEqualStrings("hello @Grace see #dev ", state.main_composer.text());
    // Not sent by that Enter
    try std.testing.expectEqual(@as(usize, 0), fake.sent_len);
    t.typeText(":tad");
    for (0..2) |_| t.frame();
    try std.testing.expect(t.hasText(":tada:"));
    t.key(.escape);
    for (0..2) |_| t.frame();
    try std.testing.expect(!t.hasText(":tada:"));
    // With the popup closed, Enter sends, mentions in Slack's form
    t.key(.enter);
    for (0..2) |_| t.frame();
    try std.testing.expectEqualStrings("hello <@U2> see <#C2> :tad", fake.sent_text[0..fake.sent_len]);
}

test "color emoji render in reactions and messages" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    var fake: Fake = .{};
    var state = try seedFor(gpa, &st, &fake);
    defer state.deinit();
    try st.apply(.{ .message = .{ .channel = "C1", .message = .{ .ts = "1700000200.000100", .user = "U2", .text = "shipped :tada: :fire: :+1::skin-tone-4: :heart:" } } });
    try st.apply(.{ .reaction = .{ .channel = "C1", .ts = "1700000200.000100", .name = "tada", .user = "U2", .added = true } });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();
    try t.screenshot("/tmp/lax-emoji-app.png");
    // Pixels of the message are not all gray: emoji drew in color
    const r = t.findText("shipped 🎉 🔥 👍🏽 ❤️").?;
    const px = try t.render(gpa);
    defer gpa.free(px.bytes);
    var colored: usize = 0;
    const x0: usize = @intFromFloat(r.x);
    const y0: usize = @intFromFloat(r.y);
    var y: usize = y0;
    while (y < y0 + @as(usize, @intFromFloat(r.h))) : (y += 1) {
        var x: usize = x0;
        while (x < x0 + @as(usize, @intFromFloat(r.w))) : (x += 1) {
            const i = (y * px.width + x) * 4;
            const rr: i32 = px.bytes[i];
            const gg: i32 = px.bytes[i + 1];
            const bb: i32 = px.bytes[i + 2];
            if (@abs(rr - gg) > 60 or @abs(gg - bb) > 60) colored += 1;
        }
    }
    try std.testing.expect(colored > 150);
}

test "real view: dragging over message text copies it" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    try seedStore(&st);
    var fake: Fake = .{};
    var state = app_view.State.init(gpa, std.testing.io, &st, fake.actions());
    defer state.deinit();
    state.preferred = "C1";
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();
    const r = t.findText("nice. zig build took 4s & passed flaky") orelse return error.TestUnexpectedResult;
    t.drag(r.x + 1, r.y + 4, r.x + r.w - 2, r.y + 6);
    t.settle(1);
    t.textOps(&.{.{ .command = .copy }});
    try std.testing.expect(std.mem.indexOf(u8, t.clipboard.items, "nice.") != null);
}

test "toolbar floats whole over a short continuation row with reactions" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    var fake: Fake = .{};
    var state = try seedFor(gpa, &st, &fake);
    defer state.deinit();
    // Same author within 5 minutes: no header, a one-line row
    try st.apply(.{ .history = .{ .channel = "C1", .messages = &.{
        .{ .ts = "1700000110.000100", .user = "U1", .text = "short follow-up", .reactions = &.{.{ .name = "joy", .count = 1 }} },
    } } });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();
    const r = t.findText("short follow-up").?;
    t.moveTo(r.x + 40, r.y + 8);
    for (0..3) |_| t.frame();
    try t.screenshot("/tmp/lax-toolbar-cont.png");
    const reply = t.findText("Reply").?;
    // The bar sits over the row's top edge, fully inside the window
    try std.testing.expect(reply.y >= 0);
    try std.testing.expect(reply.y < r.y);
    try t.clickText("Reply");
    for (0..2) |_| t.frame();
    try std.testing.expectEqual(@as(usize, 1), fake.thread_calls);
}

test "sidebar: channels above direct messages, closed DMs hidden, strip resizes" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    var fake: Fake = .{};
    var state = try seedFor(gpa, &st, &fake);
    defer state.deinit();
    try st.apply(.{ .users = &.{.{ .id = "U3", .name = "Hidden Hank" }} });
    try st.apply(.{ .channels = &.{.{ .id = "D2", .name = "", .kind = .im, .user_id = "U3" }} });
    // Slack's counts list the open conversations only: D2 is closed
    try st.apply(.{ .unreads = &.{
        .{ .id = "C1", .has_unreads = false },
        .{ .id = "D1", .has_unreads = false, .latest = "1700000000.000100" },
    } });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();
    const dm = t.findText("Direct messages").?;
    const ch = t.findText("Channels").?;
    try std.testing.expect(ch.y < dm.y);
    try std.testing.expect(!t.hasText("Hidden Hank"));
    // The dragged strip sits right of the sidebar
    const before = state.sidebar_px;
    const x = 76 + before + 3;
    t.drag(x, 300, x + 80, 300);
    for (0..3) |_| t.frame();
    try std.testing.expect(state.sidebar_px > before + 60);
    // A live message opens a closed DM
    try st.apply(.{ .message = .{ .channel = "D2", .message = .{ .ts = "1700000300.000100", .user = "U3", .text = "hi" } } });
    t.frame();
    try std.testing.expect(t.hasText("Hidden Hank"));
}

test "sidebar: Slack's top rows, Starred, custom sections and Apps in order" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    var fake: Fake = .{};
    var state = try seedFor(gpa, &st, &fake);
    defer state.deinit();
    try st.apply(.{ .users = &.{.{ .id = "UB", .name = "Helper Bot", .is_bot = true }} });
    try st.apply(.{ .channels = &.{
        .{ .id = "C1", .name = "general", .kind = .channel, .section = "", .place = .starred },
        .{ .id = "C7", .name = "ops", .kind = .channel, .section = "Work", .place = .above },
        .{ .id = "D1", .name = "", .kind = .im, .user_id = "U2", .section = "Later", .place = .below },
        .{ .id = "D9", .name = "", .kind = .im, .user_id = "UB" },
    } });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 900, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();
    const order = [_][]const u8{ "Threads", "Huddles", "Drafts & sent", "Saved", "Starred", "Work", "Channels", "Direct messages", "Later", "Apps" };
    var prev: f32 = -1;
    for (order) |label| {
        const r = t.findText(label) orelse {
            std.debug.print("missing: {s}\n", .{label});
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(r.y > prev);
        prev = r.y;
    }
    // A starred channel is listed there and not again under Channels
    try std.testing.expect(t.findText("general").?.y < t.findText("Work").?.y);
    // The bot's DM is under Apps
    try std.testing.expect(t.findText("Helper Bot").?.y > t.findText("Apps").?.y);
    // A top row opens its page, a conversation closes it
    try t.clickText("Saved");
    for (0..2) |_| t.frame();
    try std.testing.expect(t.hasText("Coming soon"));
    try t.clickText("ops");
    for (0..2) |_| t.frame();
    try std.testing.expect(!t.hasText("Coming soon"));
}

test "rail: hovering a workspace names it" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    var fake: Fake = .{};
    var state = try seedFor(gpa, &st, &fake);
    defer state.deinit();
    try st.apply(.{ .teams = .{ .list = &.{
        .{ .id = "T1", .name = "Acme", .url = "https://a.slack.com" },
        .{ .id = "T2", .name = "Side Project", .url = "https://b.slack.com" },
    }, .active = "T1" } });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();
    const second = t.findText("S").?;
    _ = second;
    // Two tiles start with S: rest on the second one
    t.moveTo(38, 16 + 52 + 12 + 26);
    t.settle(1);
    try t.screenshot("/tmp/lax-rail-tip.png");
    try std.testing.expect(t.hasText("Side Project"));
}

test "rail: a workspace's icon replaces its initial" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    var fake: Fake = .{};
    var state = try seedFor(gpa, &st, &fake);
    defer state.deinit();
    try st.apply(.{ .teams = .{ .list = &.{
        .{ .id = "T1", .name = "Acme", .url = "https://a.slack.com" },
        .{ .id = "T2", .name = "Side Project", .url = "https://b.slack.com" },
    }, .active = "T1" } });
    // A solid blue square, as BGRA: 0xFF blue, no green or red
    var pixels: [16 * 16 * 4]u8 = undefined;
    for (0..16 * 16) |i| {
        pixels[i * 4 ..][0..4].* = .{ 0xff, 0x20, 0x20, 0xff };
    }
    const png = try ui.png.encode(gpa, .{ .bytes = &pixels, .width = 16, .height = 16 });
    defer gpa.free(png);
    try st.apply(.{ .team_icon = .{ .team = "T2", .bytes = png } });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();
    try t.screenshot("/tmp/lax-rail-icon.png");
    const px = try t.render(gpa);
    defer gpa.free(px.bytes);
    // The second tile's centre is the picture
    const at = (@as(usize, 16 + 52 + 12 + 26) * px.width + 38) * 4;
    const b = px.bytes[at];
    const g = px.bytes[at + 1];
    const r = px.bytes[at + 2];
    try std.testing.expect(@max(r, b) > 200 and g < 90 and @min(r, b) < 90);
}

test "layout: a resized sidebar is saved once it settles and restored" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const dir = try std.fmt.allocPrint(arena_state.allocator(), ".zig-cache/tmp/{s}/lax", .{tmp.sub_path});

    var st = store.Store.init(gpa);
    defer st.deinit();
    var fake: Fake = .{};
    var state = try seedFor(gpa, &st, &fake);
    defer state.deinit();
    state.layout_dir = dir;
    state.layout_settle_ms = 3_600_000;
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..3) |_| t.frame();
    const x = 76 + state.sidebar_px + 3;
    t.drag(x, 300, x + 60, 300);
    for (0..3) |_| t.frame();
    // Still changing: nothing on disk yet
    try std.testing.expect(!layout_mod.load(arena_state.allocator(), io, dir).hasWindow());
    // Settled
    state.layout_settle_ms = 0;
    t.frame();
    const saved = layout_mod.load(arena_state.allocator(), io, dir);
    try std.testing.expect(saved.hasWindow());
    try std.testing.expectEqual(state.sidebar_px, saved.sidebar);

    var again = try seedFor(gpa, &st, &fake);
    defer again.deinit();
    again.restoreSidebar(saved.sidebar);
    try std.testing.expectEqual(saved.sidebar, again.sidebar_px);
    again.restoreSidebar(5000);
    try std.testing.expectEqual(saved.sidebar, again.sidebar_px);
}

test "pointer in a message row's empty space is an arrow" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    var fake: Fake = .{};
    var state = try seedFor(gpa, &st, &fake);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();
    // Above a message's text, inside its row: padding, nothing clickable
    const r = t.findText("morning! deploy is green, see the run").?;
    t.moveTo(r.x + 150, r.y - 10);
    t.frame();
    t.frame();
    try std.testing.expect(t.ctx.hot != 0);
    try std.testing.expect(!t.ctx.cursor_hand);
    try std.testing.expect(t.ctx.cursor == null);
}

test "composer: two lines by default, the border button makes it ten" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    var fake: Fake = .{};
    var state = try seedFor(gpa, &st, &fake);
    defer state.deinit();
    state.preferred = "C1";
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();
    const small = t.findText("Message #general").?;
    const toggle = t.findText("▴").?;
    t.click(toggle.x + 3, toggle.y + 3);
    for (0..3) |_| t.frame();
    try std.testing.expect(state.composer_expanded);
    const tall = t.findText("Message #general").?;
    // Eight more lines of 22 points: the box grew upward
    try std.testing.expect(small.y - tall.y > 150);
    try t.screenshot("/tmp/lax-composer-tall.png");
    const back = t.findText("▾").?;
    t.click(back.x + 3, back.y + 3);
    for (0..3) |_| t.frame();
    try std.testing.expect(!state.composer_expanded);
    try std.testing.expectApproxEqAbs(small.y, t.findText("Message #general").?.y, 1);
}

test "account menu: avatar opens it, Settings opens the page, fonts and sizes apply" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    var fake: Fake = .{};
    var state = try seedFor(gpa, &st, &fake);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();
    // The avatar is the last thing in the rail: bottom left
    t.click(38, 640 - 16 - 26);
    for (0..4) |_| t.frame();
    try std.testing.expect(state.user_menu_open);
    try std.testing.expect(t.hasText("Account settings"));
    try std.testing.expect(t.hasText("Exit Lax"));
    try std.testing.expect(!t.hasText("Sign out"));
    try t.screenshot("/tmp/lax-user-menu.png");
    // Away
    try t.clickText("Set yourself as away");
    for (0..3) |_| t.frame();
    try std.testing.expectEqual(@as(?bool, true), fake.away);
    // Settings
    t.click(38, 640 - 16 - 26);
    for (0..4) |_| t.frame();
    try t.clickText("Settings");
    for (0..4) |_| t.frame();
    try std.testing.expect(state.settings_open);
    try std.testing.expect(t.hasText("Text size"));
    try t.screenshot("/tmp/lax-settings.png");
    const before = state.settings.chat_size;
    // numberInput's plus button: find it by its position after the label
    state.applySettings(.{ .chat_size = 18, .interface_size = 110 });
    for (0..4) |_| t.frame();
    try std.testing.expect(state.settings.chat_size > before);
    try std.testing.expectEqual(@as(f32, 1.1), t.ctx.text.zoom);
    try t.screenshot("/tmp/lax-settings-big.png");
}

test "fonts: the chat font changes message text only, and a bad name falls back" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    var fake: Fake = .{};
    var state = try seedFor(gpa, &st, &fake);
    defer state.deinit();
    state.preferred = "C1";
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();
    const text = "morning! deploy is green, see the run";
    const chat_st: ui.TextStyle = .{ .size = 15, .alt = true };
    const iface: ui.TextStyle = .{ .size = 15 };
    const side = t.findText("general").?;
    const plain = t.ctx.text.caretX(text, chat_st, text.len);
    state.applySettings(.{ .chat_font = "Noto Serif" });
    for (0..4) |_| t.frame();
    const serif = t.ctx.text.caretX(text, chat_st, text.len);
    try std.testing.expect(@abs(serif - plain) > 4);
    // The interface font is untouched
    try std.testing.expectApproxEqAbs(plain, t.ctx.text.caretX(text, iface, text.len), 0.5);
    try std.testing.expect(t.hasText("general"));
    _ = side;
    try t.screenshot("/tmp/lax-chat_st-serif.png");
    state.applySettings(.{ .chat_font = "No Such Font" });
    for (0..4) |_| t.frame();
    try std.testing.expectApproxEqAbs(plain, t.ctx.text.caretX(text, chat_st, text.len), 0.5);
}

test "sidebar: a DM without a resolved name stays out until it resolves" {
    const gpa = std.testing.allocator;
    var st = store.Store.init(gpa);
    defer st.deinit();
    var fake: Fake = .{};
    var state = try seedFor(gpa, &st, &fake);
    defer state.deinit();
    try st.apply(.{ .channels = &.{.{ .id = "D9", .name = "", .kind = .im, .user_id = "U9" }} });
    try st.apply(.{ .message = .{ .channel = "D9", .message = .{ .ts = "1700000300.000100", .user = "U9", .text = "hi" } } });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1000, .height = 640, .scale = 1 });
    defer t.deinit();
    for (0..4) |_| t.frame();
    try std.testing.expect(!t.hasText("D9"));
    try std.testing.expect(!t.hasText("U9"));
    try st.apply(.{ .users = &.{.{ .id = "U9", .name = "Newly Named" }} });
    t.frame();
    try std.testing.expect(t.hasText("Newly Named"));
}
