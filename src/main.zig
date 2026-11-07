//! Lax: a minimal native Slack client.
//! Usage: lax [--team <name-substring>] [--channel <id>]
const std = @import("std");
const nanoui = @import("nanoui");
const store = @import("store");
const app = @import("app");
const ui = @import("ui");

const Net = app.net.Net;

/// Everything the wake-up handler needs on the UI thread
const Pump = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    st: *store.Store,
    net: *Net,
    wake: *store.Wake,
    state: *ui.app_view.State,
    window: ?*nanoui.Window = null,
    /// Where the last known state is saved (null: nowhere)
    cache_dir: ?[]const u8 = null,
    dirty: bool = false,
    last_save_ms: i64 = 0,
    /// `LAX_DEBUG=1`: log update counts (never content, tokens or cookies)
    debug: bool = false,

    fn onWake(ctx: ?*anyopaque) callconv(.c) void {
        const p: *Pump = @ptrCast(@alignCast(ctx.?));
        p.wake.drain();
        var items: std.ArrayList(store.Item) = .empty;
        defer items.deinit(p.gpa);
        p.net.updates.drain(p.gpa, p.io, &items) catch return;
        for (items.items) |*item| {
            p.st.applyItem(item) catch {};
            item.deinit();
        }
        if (p.debug) std.debug.print("wake: applied {d} updates, {d} channels, {d} users, connection={s}\n", .{ items.items.len, p.st.channels.items.len, p.st.users.count(), @tagName(p.st.connection) });
        p.state.afterUpdates();
        if (p.window) |w| w.redraw();
        p.dirty = true;
        p.saveCache(false);
    }

    /// Writes the last known state: at most every 20 seconds, or now when forced
    fn saveCache(p: *Pump, force: bool) void {
        const dir = p.cache_dir orelse return;
        if (!p.dirty) return;
        const now = store.nowMs(p.io);
        if (!force and now - p.last_save_ms < 20_000) return;
        p.last_save_ms = now;
        p.dirty = false;
        store.cache.save(p.gpa, p.io, dir, p.st);
    }
};

fn actionOpen(ctx: *anyopaque, channel: []const u8) void {
    const net: *Net = @ptrCast(@alignCast(ctx));
    net.open(channel);
}

fn actionUpload(ctx: *anyopaque, channel: []const u8, text: []const u8, thread_ts: ?[]const u8, paths: []const []const u8) void {
    const net: *Net = @ptrCast(@alignCast(ctx));
    net.upload(channel, text, thread_ts, paths);
}

fn actionFetchImage(ctx: *anyopaque, id: []const u8, url: []const u8) void {
    const net: *Net = @ptrCast(@alignCast(ctx));
    net.fetchImage(id, url);
}

fn actionSend(ctx: *anyopaque, channel: []const u8, text: []const u8, thread_ts: ?[]const u8) void {
    const net: *Net = @ptrCast(@alignCast(ctx));
    net.send(channel, text, thread_ts);
}

fn actionOlder(ctx: *anyopaque, channel: []const u8, before: []const u8) void {
    const net: *Net = @ptrCast(@alignCast(ctx));
    net.older(channel, before);
}

fn actionOpenThread(ctx: *anyopaque, channel: []const u8, ts: []const u8) void {
    const net: *Net = @ptrCast(@alignCast(ctx));
    net.openThread(channel, ts);
}

fn actionReact(ctx: *anyopaque, channel: []const u8, ts: []const u8, name: []const u8, add: bool) void {
    const net: *Net = @ptrCast(@alignCast(ctx));
    net.react(channel, ts, name, add);
}

fn actionTyping(ctx: *anyopaque, channel: []const u8) void {
    const net: *Net = @ptrCast(@alignCast(ctx));
    net.typing(channel);
}

fn actionMark(ctx: *anyopaque, channel: []const u8, ts: []const u8) void {
    const net: *Net = @ptrCast(@alignCast(ctx));
    net.mark(channel, ts);
}

fn actionSwitchTeam(ctx: *anyopaque, team_id: []const u8) void {
    const net: *Net = @ptrCast(@alignCast(ctx));
    net.switchTeam(team_id);
}

fn actionPresence(ctx: *anyopaque, away: bool) void {
    const net: *Net = @ptrCast(@alignCast(ctx));
    net.setPresence(away);
}

fn actionFeed(ctx: *anyopaque, kind: store.FeedKind) void {
    const net: *Net = @ptrCast(@alignCast(ctx));
    net.loadFeed(kind);
}

fn actionManual(ctx: *anyopaque, url: []const u8, token: []const u8, cookie: []const u8) void {
    const net: *Net = @ptrCast(@alignCast(ctx));
    net.manualCredentials(url, token, cookie);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var team: ?[]const u8 = null;
    var channel: ?[]const u8 = null;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "--team")) team = args[i + 1];
        if (std.mem.eql(u8, args[i], "--channel")) channel = args[i + 1];
    }

    var st = store.Store.init(gpa);
    defer st.deinit();
    var wake = try store.Wake.init();
    defer wake.deinit();
    var net: Net = .{ .gpa = gpa, .io = init.io, .env = init.environ_map, .team_hint = team, .wake = &wake };

    var state = ui.app_view.State.init(gpa, init.io, &st, .{
        .ctx = &net,
        .open = actionOpen,
        .send = actionSend,
        .upload = actionUpload,
        .fetch_image = actionFetchImage,
        .older = actionOlder,
        .open_thread = actionOpenThread,
        .react = actionReact,
        .typing = actionTyping,
        .mark = actionMark,
        .switch_team = actionSwitchTeam,
        .manual = actionManual,
        .set_presence = actionPresence,
        .load_feed = actionFeed,
    });
    defer state.deinit();
    state.preferred = channel;

    // Restore the window and sidebar sizes from the last run
    var width: f64 = 1100;
    var height: f64 = 760;
    const config_dir = app.state_file.configDir(init.arena.allocator(), init.environ_map) catch null;
    if (config_dir) |dir| {
        const saved = ui.layout.load(init.arena.allocator(), init.io, dir);
        state.layout_dir = dir;
        state.layout_saved = saved;
        if (saved.hasWindow()) {
            width = saved.width;
            height = saved.height;
        }
        state.restoreSidebar(saved.sidebar);
        state.applySettings(ui.settings.load(init.arena.allocator(), init.io, dir));
    }

    // Open with the last known state; the network side then updates it
    const cache_dir = app.state_file.cacheDir(init.arena.allocator(), init.environ_map) catch null;
    if (cache_dir) |dir| if (team == null) {
        var want: []const u8 = "";
        if (config_dir) |cd| want = app.state_file.load(init.arena.allocator(), init.io, cd).last_team;
        const loaded = store.cache.loadStartup(gpa, init.io, dir, &st, want);
        if (init.environ_map.get("LAX_DEBUG") != null) std.debug.print("cache: loaded={}, {d} channels, {d} users\n", .{ loaded, st.channels.items.len, st.users.count() });
    };
    state.cache_dir = cache_dir;

    var pump: Pump = .{ .gpa = gpa, .io = init.io, .st = &st, .net = &net, .wake = &wake, .state = &state };

    const nano = try nanoui.App.create(init, .{ .name = "Lax" });
    defer nano.destroy();
    const window = try nano.newWindow(.{
        .title = "Lax",
        .width = width,
        .height = height,
        .content = .{ .view = .init(&state, ui.app_view.State.view) },
    });
    pump.cache_dir = cache_dir;
    pump.debug = init.environ_map.get("LAX_DEBUG") != null;
    pump.window = window;
    state.window = window;
    const watch = try nanoui.fdwatch.readable(wake.read_fd, &pump, Pump.onWake);
    defer watch.cancel();

    try net.start();
    defer net.stop();
    try nano.run();
    state.flushLayout();
    pump.dirty = true;
    pump.saveCache(true);
}
