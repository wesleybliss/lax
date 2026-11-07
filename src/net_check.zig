//! Headless check of the network thread + queue + store, no window.
//! Usage: net-check --team <name> --channel <id> [--send <text>] [--seconds N]
const std = @import("std");
const store = @import("store");
const app = @import("app");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var team: ?[]const u8 = null;
    var channel: ?[]const u8 = null;
    var send_text: ?[]const u8 = null;
    var seconds: u32 = 12;
    var react_spec: ?[]const u8 = null; // "<ts>:<name>"
    var do_older = false;
    var flip = false;
    var thread_ts: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--older")) {
            do_older = true;
            continue;
        }
        // Switch to the other workspace and straight back, like a fast double click
        if (std.mem.eql(u8, args[i], "--flip")) {
            flip = true;
            continue;
        }
        if (i + 1 >= args.len) break;
        if (std.mem.eql(u8, args[i], "--react")) react_spec = args[i + 1];
        if (std.mem.eql(u8, args[i], "--thread")) thread_ts = args[i + 1];
        if (std.mem.eql(u8, args[i], "--team")) team = args[i + 1];
        if (std.mem.eql(u8, args[i], "--channel")) channel = args[i + 1];
        if (std.mem.eql(u8, args[i], "--send")) send_text = args[i + 1];
        if (std.mem.eql(u8, args[i], "--seconds")) seconds = try std.fmt.parseInt(u32, args[i + 1], 10);
        i += 1;
    }
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &out.interface;
    defer w.flush() catch {};

    var st = store.Store.init(gpa);
    defer st.deinit();
    var wake = try store.Wake.init();
    defer wake.deinit();
    var net: app.net.Net = .{ .gpa = gpa, .io = init.io, .env = init.environ_map, .team_hint = team, .wake = &wake };
    try net.start();
    defer net.stop();

    var opened = false;
    var acted = false;
    var react_remove_at: ?i64 = null;
    var sent = false;
    var flip_step: u8 = 0;
    var flip_first: []const u8 = "";
    const start = std.Io.Timestamp.now(init.io, .awake);
    while (true) {
        const elapsed: i64 = @intCast(@divTrunc(start.durationTo(std.Io.Timestamp.now(init.io, .awake)).toNanoseconds(), std.time.ns_per_s));
        if (elapsed >= seconds) break;
        var items: std.ArrayList(store.Item) = .empty;
        defer items.deinit(gpa);
        try net.updates.drain(gpa, init.io, &items);
        for (items.items) |*item| {
            switch (item.update) {
                .status => |s| try w.print("[{d}s] status: {s}\n", .{ elapsed, s }),
                .connection => |c| try w.print("[{d}s] connection: {s} ({s})\n", .{ elapsed, @tagName(c), item.team() }),
                .need_manual => |r| try w.print("[{d}s] NEEDS MANUAL CREDENTIALS: {s}\n", .{ elapsed, r }),
                .teams => |t| try w.print("[{d}s] teams: {d}\n", .{ elapsed, t.list.len }),
                .message => |m| try w.print("[{d}s] live message in {s} from {s}\n", .{ elapsed, m.channel, m.message.user orelse "-" }),
                .history => |h| try w.print("[{d}s] history {s}: {d} messages, older={}, has_more={}\n", .{ elapsed, h.channel, h.messages.len, h.older, h.has_more }),
                .thread_history => |h| try w.print("[{d}s] thread {s}: {d} messages\n", .{ elapsed, h.thread_ts, h.messages.len }),
                .reaction => |r| try w.print("[{d}s] reaction {s} {s} on {s} by {s}\n", .{ elapsed, if (r.added) "added" else "removed", r.name, r.ts, r.user }),
                .presence => |p| try w.print("[{d}s] presence: {d} users active={}\n", .{ elapsed, p.users.len, p.active }),
                .typing => |t| try w.print("[{d}s] typing in {s}\n", .{ elapsed, t.channel }),
                else => {},
            }
            try st.applyItem(item);
            item.deinit();
        }
        try w.flush();
        if (flip and st.teams.items.len > 1) {
            if (flip_step == 0 and st.connection == .online) {
                flip_step = 1;
                flip_first = try gpa.dupe(u8, st.active_team);
                for (st.teams.items) |t| if (!std.mem.eql(u8, t.id, flip_first)) {
                    try w.print("[{d}s] flip: to {s}\n", .{ elapsed, t.name });
                    try st.setActive(t.id);
                    net.switchTeam(t.id);
                    break;
                };
            } else if (flip_step == 1) {
                flip_step = 2;
                try w.print("[{d}s] flip: back\n", .{elapsed});
                try st.setActive(flip_first);
                net.switchTeam(flip_first);
            }
        }
        if (!opened and st.connection == .online) if (channel) |ch| {
            opened = true;
            net.open(ch);
        };
        if (opened and !acted and st.channel(channel.?) != null and st.channel(channel.?).?.history_loaded) {
            acted = true;
            const c = st.channel(channel.?).?;
            if (do_older and c.messages.items.len > 0) net.older(channel.?, c.messages.items[0].ts);
            if (thread_ts) |ts| net.openThread(channel.?, ts);
            if (react_spec) |spec| if (std.mem.indexOfScalar(u8, spec, ':')) |colon| {
                net.react(channel.?, spec[0..colon], spec[colon + 1 ..], true);
                react_remove_at = elapsed + 3;
            };
        }
        if (react_remove_at) |at| if (elapsed >= at) {
            react_remove_at = null;
            const spec = react_spec.?;
            const colon = std.mem.indexOfScalar(u8, spec, ':').?;
            net.react(channel.?, spec[0..colon], spec[colon + 1 ..], false);
        };
        if (!sent and opened and send_text != null and st.channel(channel.?) != null and st.channel(channel.?).?.history_loaded) {
            sent = true;
            try w.print("[{d}s] sending test message\n", .{elapsed});
            net.send(channel.?, send_text.?, null);
        }
        try init.io.sleep(.fromMilliseconds(200), .awake);
    }
    if (flip_first.len > 0) {
        try w.print("\nflip: active {s}, started on {s}, channels {d}\n", .{ st.active_team, flip_first, st.channels.items.len });
        gpa.free(flip_first);
    }
    try w.print("\nteam: {s} (active id {s})  self: {s}\nusers: {d}  channels: {d}\n", .{ st.team_name, st.active_team, st.self_id, st.users.count(), st.channels.items.len });
    try w.print("teams in rail: {d}\n", .{st.teams.items.len});
    var unread: usize = 0;
    var mentions: u32 = 0;
    for (st.channels.items) |c| {
        if (c.unread) unread += 1;
        mentions += c.mentions;
    }
    try w.print("unread conversations: {d}, total mentions: {d}\n", .{ unread, mentions });
    if (channel) |ch| if (st.channel(ch)) |c| {
        try w.print("channel {s} ({s}): {d} messages, latest {s}\n", .{ ch, st.channelName(c), c.messages.items.len, c.latest });
        const from = c.messages.items.len -| 3;
        for (c.messages.items[from..]) |m| {
            const name = if (m.user) |u| (st.userName(u) orelse u) else "-";
            try w.print("  {s} {s}: {s}\n", .{ m.ts, name, m.text });
        }
    };
    if (channel == null) {
        var shown: usize = 0;
        for (st.channels.items) |c| {
            if (c.kind != .channel or shown >= 8) continue;
            try w.print("  channel {s} #{s}\n", .{ c.id, c.name });
            shown += 1;
        }
    }
    var dm: usize = 0;
    var named: usize = 0;
    for (st.channels.items) |c| if (c.kind == .im) {
        dm += 1;
        if (st.userName(c.user_id.?) != null) named += 1;
    };
    try w.print("DMs: {d}, names resolved: {d}\n", .{ dm, named });
    var listed: usize = 0;
    var total: usize = 0;
    var dormant: usize = 0;
    var shown_chans: usize = 0;
    var shown_ims: usize = 0;
    var chans: usize = 0;
    for (st.channels.items) |*c| {
        if (c.kind == .im or c.kind == .mpim) {
            total += 1;
            if (c.dormant) dormant += 1;
            if (st.shownInSidebar(c)) {
                listed += 1;
                if (c.kind == .im) shown_ims += 1;
            }
        } else {
            chans += 1;
            if (st.shownInSidebar(c)) shown_chans += 1;
        }
    }
    try w.print("sidebar mode: {s}\nDMs and group DMs: {d} ({d} dormant), shown in the sidebar: {d} (1:1: {d})\nchannels: {d}, shown: {d}\n", .{ @tagName(st.sidebar_mode), total, dormant, listed, shown_ims, chans, shown_chans });
}
