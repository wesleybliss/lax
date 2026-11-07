//! The network thread: owns the Slack session, the HTTP client and the
//! socket. Talks to the UI only through queues: `Update`s out (applied by the
//! UI thread to the store), `Command`s in.
const std = @import("std");
const slack = @import("slack");
const store = @import("store");

const state_file = @import("state_file.zig");

const json = slack.jsonutil;

pub const Command = union(enum) {
    /// Post a message, in a thread if `thread_ts` is set (owned strings)
    send: struct { channel: []u8, text: []u8, thread_ts: ?[]u8 },
    /// Post files (paths) with `text` as their comment, in a thread if
    /// `thread_ts` is set (owned strings)
    upload: struct { channel: []u8, text: []u8, thread_ts: ?[]u8, paths: [][]u8 },
    /// Download a file's preview picture (`url` is private to the workspace)
    fetch_image: struct { id: []u8, url: []u8 },
    /// Load the page of messages before `before`
    older: struct { channel: []u8, before: []u8 },
    open_thread: struct { channel: []u8, ts: []u8 },
    react: struct { channel: []u8, ts: []u8, name: []u8, add: bool },
    /// Replace a message's text (`chat.update`)
    edit: struct { channel: []u8, ts: []u8, text: []u8 },
    /// Delete one of our messages
    delete: struct { channel: []u8, ts: []u8 },
    /// Add a message to Saved
    save: struct { channel: []u8, ts: []u8 },
    /// The user is typing in a conversation
    typing: []u8,
    /// The user opened a conversation: load its history if needed, mark read
    open: []u8,
    /// Mark a conversation read up to `ts`
    mark: struct { channel: []u8, ts: []u8 },
    /// Show another signed-in workspace (team id)
    switch_team: []u8,
    /// Away (true) or automatic presence
    presence: bool,
    /// Load a top-row page (Threads, Drafts & sent, Saved)
    feed: store.FeedKind,
    /// Credentials the user pasted
    manual: struct { url: []u8, token: []u8, cookie: []u8 },
    quit,

    fn deinit(c: Command, gpa: std.mem.Allocator) void {
        switch (c) {
            .send => |m| {
                gpa.free(m.channel);
                gpa.free(m.text);
                if (m.thread_ts) |t| gpa.free(t);
            },
            .upload => |m| {
                gpa.free(m.channel);
                gpa.free(m.text);
                if (m.thread_ts) |t| gpa.free(t);
                for (m.paths) |p| gpa.free(p);
                gpa.free(m.paths);
            },
            .fetch_image => |m| {
                gpa.free(m.id);
                gpa.free(m.url);
            },
            .older => |m| {
                gpa.free(m.channel);
                gpa.free(m.before);
            },
            .open_thread => |m| {
                gpa.free(m.channel);
                gpa.free(m.ts);
            },
            .react => |m| {
                gpa.free(m.channel);
                gpa.free(m.ts);
                gpa.free(m.name);
            },
            .edit => |m| {
                gpa.free(m.channel);
                gpa.free(m.ts);
                gpa.free(m.text);
            },
            .delete => |m| {
                gpa.free(m.channel);
                gpa.free(m.ts);
            },
            .save => |m| {
                gpa.free(m.channel);
                gpa.free(m.ts);
            },
            .typing => |ch| gpa.free(ch),
            .open => |ch| gpa.free(ch),
            .switch_team => |t| gpa.free(t),
            .presence, .feed => {},
            .mark => |m| {
                gpa.free(m.channel);
                gpa.free(m.ts);
            },
            .manual => |m| {
                gpa.free(m.url);
                std.crypto.secureZero(u8, m.token);
                gpa.free(m.token);
                std.crypto.secureZero(u8, m.cookie);
                gpa.free(m.cookie);
            },
            .quit => {},
        }
    }
};

/// Largest file read into memory to upload (one buffer: the file and its form)
const upload_max = 256 << 20;

/// Offline for longer than this: fetch conversations and users again
const full_refresh_ms = 5 * 60 * 1000;

/// Conversations opened in the background after connecting, at most
const prefetch_max = 10;
/// Saved items listed on the page: each costs one request, for its message text
const saved_max = 15;
/// Gap between those fetches: a person clicking around
const prefetch_gap_ms = 600;

/// What the network side remembers per workspace between sessions
const TeamCache = struct {
    /// When conversations and users were last fetched in full (0: never)
    full_ms: i64 = 0,
    /// Users of our 1:1 DMs, for presence subscriptions
    dm_users: std.ArrayList([]u8) = .empty,
    icon_tried: bool = false,

    fn clearDmUsers(c: *TeamCache, gpa: std.mem.Allocator) void {
        for (c.dm_users.items) |u| gpa.free(u);
        c.dm_users.clearRetainingCapacity();
    }
};

pub const Net = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    /// Substring of a workspace name or domain to start with (command line)
    team_hint: ?[]const u8,
    updates: store.Queue(store.Item) = .{},
    commands: store.Queue(Command) = .{},
    wake: *const store.Wake,
    thread: ?std.Thread = null,
    quit: std.atomic.Value(bool) = .init(false),
    /// Log what the connection is doing (never content or secrets)
    debug: bool = false,
    /// Seconds without any frame before the connection counts as dead
    /// (`LAX_STALE_SECS`, for testing)
    stale_secs: i64 = 60,

    // Thread-owned state below: only the network thread touches it

    creds: ?slack.desktop.Credentials = null,
    /// Team chosen in the UI; wins over every other preference
    team_pref: ?[]u8 = null,
    /// Team currently shown in the store
    shown_team: ?[]u8 = null,
    /// Conversation the user has open, refetched after reconnecting
    active: ?[]u8 = null,
    /// Last used team from the state file (arena-owned by `run`)
    last_team: []const u8 = "",
    config_dir: ?[]const u8 = null,
    /// Set once a session got through bootstrap (the credentials work)
    bootstrapped: bool = false,
    self_id: []u8 = &.{},
    /// Per workspace, by team id
    caches: std.StringHashMapUnmanaged(*TeamCache) = .empty,
    /// The shown workspace's entry
    cur: ?*TeamCache = null,
    /// Commands that arrived while a session was starting
    deferred: std.ArrayList(Command) = .empty,
    /// The UI asked for another workspace (cuts rate-limit waits short)
    switch_pending: std.atomic.Value(bool) = .init(false),
    /// Conversations to load in the background, next first
    prefetch: std.ArrayList([]u8) = .empty,

    pub fn start(n: *Net) !void {
        n.debug = n.env.get("LAX_DEBUG") != null;
        if (n.env.get("LAX_STALE_SECS")) |v| n.stale_secs = std.fmt.parseInt(i64, v, 10) catch 60;
        n.thread = try std.Thread.spawn(.{}, run, .{n});
    }

    pub fn stop(n: *Net) void {
        n.quit.store(true, .release);
        if (n.thread) |t| t.join();
        n.thread = null;
        var pending: std.ArrayList(store.Item) = .empty;
        defer pending.deinit(n.gpa);
        n.updates.drain(n.gpa, n.io, &pending) catch {};
        for (pending.items) |*i| i.deinit();
        var cmds: std.ArrayList(Command) = .empty;
        defer cmds.deinit(n.gpa);
        n.commands.drain(n.gpa, n.io, &cmds) catch {};
        for (cmds.items) |c| c.deinit(n.gpa);
        n.updates.deinit(n.gpa);
        n.commands.deinit(n.gpa);
        for (n.deferred.items) |c| c.deinit(n.gpa);
        n.deferred.deinit(n.gpa);
        for (n.prefetch.items) |id| n.gpa.free(id);
        n.prefetch.deinit(n.gpa);
        var it = n.caches.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.*.clearDmUsers(n.gpa);
            kv.value_ptr.*.dm_users.deinit(n.gpa);
            n.gpa.destroy(kv.value_ptr.*);
            n.gpa.free(kv.key_ptr.*);
        }
        n.caches.deinit(n.gpa);
    }

    // UI-thread API

    pub fn send(n: *Net, channel: []const u8, text: []const u8, thread_ts: ?[]const u8) void {
        const ch = n.gpa.dupe(u8, channel) catch return;
        const tx = n.gpa.dupe(u8, text) catch return;
        const th = if (thread_ts) |t| n.gpa.dupe(u8, t) catch return else null;
        n.commands.push(n.gpa, n.io, .{ .send = .{ .channel = ch, .text = tx, .thread_ts = th } }) catch {};
    }

    pub fn upload(n: *Net, channel: []const u8, text: []const u8, thread_ts: ?[]const u8, paths: []const []const u8) void {
        const ch = n.gpa.dupe(u8, channel) catch return;
        const tx = n.gpa.dupe(u8, text) catch return;
        const th = if (thread_ts) |t| n.gpa.dupe(u8, t) catch return else null;
        const owned = n.gpa.alloc([]u8, paths.len) catch return;
        var made: usize = 0;
        for (paths) |p| {
            owned[made] = n.gpa.dupe(u8, p) catch break;
            made += 1;
        }
        if (made == 0) {
            n.gpa.free(owned);
            return;
        }
        n.commands.push(n.gpa, n.io, .{ .upload = .{ .channel = ch, .text = tx, .thread_ts = th, .paths = owned[0..made] } }) catch {};
    }

    pub fn fetchImage(n: *Net, id: []const u8, url: []const u8) void {
        const i = n.gpa.dupe(u8, id) catch return;
        const u = n.gpa.dupe(u8, url) catch {
            n.gpa.free(i);
            return;
        };
        n.commands.push(n.gpa, n.io, .{ .fetch_image = .{ .id = i, .url = u } }) catch {
            n.gpa.free(i);
            n.gpa.free(u);
        };
    }

    pub fn older(n: *Net, channel: []const u8, before: []const u8) void {
        const ch = n.gpa.dupe(u8, channel) catch return;
        const b = n.gpa.dupe(u8, before) catch return;
        n.commands.push(n.gpa, n.io, .{ .older = .{ .channel = ch, .before = b } }) catch {};
    }

    pub fn openThread(n: *Net, channel: []const u8, ts: []const u8) void {
        const ch = n.gpa.dupe(u8, channel) catch return;
        const t = n.gpa.dupe(u8, ts) catch return;
        n.commands.push(n.gpa, n.io, .{ .open_thread = .{ .channel = ch, .ts = t } }) catch {};
    }

    pub fn react(n: *Net, channel: []const u8, ts: []const u8, name: []const u8, add: bool) void {
        const ch = n.gpa.dupe(u8, channel) catch return;
        const t = n.gpa.dupe(u8, ts) catch return;
        const nm = n.gpa.dupe(u8, name) catch return;
        n.commands.push(n.gpa, n.io, .{ .react = .{ .channel = ch, .ts = t, .name = nm, .add = add } }) catch {};
    }

    pub fn edit(n: *Net, channel: []const u8, ts: []const u8, text: []const u8) void {
        const ch = n.gpa.dupe(u8, channel) catch return;
        const t = n.gpa.dupe(u8, ts) catch return;
        const tx = n.gpa.dupe(u8, text) catch return;
        n.commands.push(n.gpa, n.io, .{ .edit = .{ .channel = ch, .ts = t, .text = tx } }) catch {};
    }

    pub fn delete(n: *Net, channel: []const u8, ts: []const u8) void {
        const ch = n.gpa.dupe(u8, channel) catch return;
        const t = n.gpa.dupe(u8, ts) catch return;
        n.commands.push(n.gpa, n.io, .{ .delete = .{ .channel = ch, .ts = t } }) catch {};
    }

    pub fn save(n: *Net, channel: []const u8, ts: []const u8) void {
        const ch = n.gpa.dupe(u8, channel) catch return;
        const t = n.gpa.dupe(u8, ts) catch return;
        n.commands.push(n.gpa, n.io, .{ .save = .{ .channel = ch, .ts = t } }) catch {};
    }

    pub fn typing(n: *Net, channel: []const u8) void {
        const ch = n.gpa.dupe(u8, channel) catch return;
        n.commands.push(n.gpa, n.io, .{ .typing = ch }) catch {};
    }

    pub fn open(n: *Net, channel: []const u8) void {
        const ch = n.gpa.dupe(u8, channel) catch return;
        n.commands.push(n.gpa, n.io, .{ .open = ch }) catch {};
    }

    pub fn switchTeam(n: *Net, team_id: []const u8) void {
        const t = n.gpa.dupe(u8, team_id) catch return;
        n.switch_pending.store(true, .release);
        n.commands.push(n.gpa, n.io, .{ .switch_team = t }) catch {};
    }

    pub fn manualCredentials(n: *Net, url: []const u8, token: []const u8, cookie: []const u8) void {
        const u = n.gpa.dupe(u8, url) catch return;
        const t = n.gpa.dupe(u8, token) catch return;
        const c = n.gpa.dupe(u8, cookie) catch return;
        n.commands.push(n.gpa, n.io, .{ .manual = .{ .url = u, .token = t, .cookie = c } }) catch {};
    }

    pub fn loadFeed(n: *Net, kind: store.FeedKind) void {
        n.commands.push(n.gpa, n.io, .{ .feed = kind }) catch {};
    }

    pub fn setPresence(n: *Net, away: bool) void {
        n.commands.push(n.gpa, n.io, .{ .presence = away }) catch {};
    }

    pub fn mark(n: *Net, channel: []const u8, ts: []const u8) void {
        const ch = n.gpa.dupe(u8, channel) catch return;
        const t = n.gpa.dupe(u8, ts) catch return;
        n.commands.push(n.gpa, n.io, .{ .mark = .{ .channel = ch, .ts = t } }) catch {};
    }

    // Thread side

    fn emit(n: *Net, item: store.Item) void {
        var it = item;
        if (n.shown_team) |t| it.setTeam(t);
        n.updates.push(n.gpa, n.io, it) catch {
            it.deinit();
            return;
        };
        n.wake.signal();
    }

    fn emitStatus(n: *Net, comptime fmt: []const u8, args: anytype) void {
        var arena = std.heap.ArenaAllocator.init(n.gpa);
        const msg = std.fmt.allocPrint(arena.allocator(), fmt, args) catch {
            arena.deinit();
            return;
        };
        n.emit(.{ .arena = arena, .update = .{ .status = msg } });
    }

    fn emitConnection(n: *Net, c: store.Connection) void {
        n.emit(.{ .arena = std.heap.ArenaAllocator.init(n.gpa), .update = .{ .connection = c } });
    }

    fn dbg(n: *Net, comptime fmt: []const u8, args: anytype) void {
        if (n.debug) std.debug.print("net: " ++ fmt ++ "\n", args);
    }

    fn run(n: *Net) void {
        var arena_state = std.heap.ArenaAllocator.init(n.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        n.config_dir = state_file.configDir(arena, n.env) catch null;
        if (n.config_dir) |d| n.last_team = state_file.load(arena, n.io, d).last_team;
        defer {
            if (n.creds) |*c| c.deinit();
            if (n.team_pref) |t| n.gpa.free(t);
            if (n.shown_team) |t| n.gpa.free(t);
            if (n.active) |t| n.gpa.free(t);
            n.gpa.free(n.self_id);
        }

        var backoff_s: u32 = 1;
        var auth_retried = false;
        var force_extract = false;
        while (!n.quit.load(.acquire)) {
            n.bootstrapped = false;
            n.session(force_extract) catch |err| {
                n.dbg("session ended: {s}", .{@errorName(err)});
                if (n.bootstrapped) {
                    // It worked for a while: start the retry ladders over
                    auth_retried = false;
                    force_extract = false;
                    backoff_s = 1;
                }
                switch (err) {
                    error.Quit => break,
                    error.SwitchTeam => {
                        backoff_s = 1;
                        continue;
                    },
                    error.AuthFailed => {
                        n.dropCreds();
                        if (!auth_retried) {
                            // Re-read the desktop app's session once, then ask
                            auth_retried = true;
                            force_extract = true;
                            n.emitStatus("Session expired; re-reading Slack's session…", .{});
                            continue;
                        }
                        auth_retried = false;
                        force_extract = false;
                        n.promptManual("Slack rejected the saved session.") catch break;
                        continue;
                    },
                    error.NoCredentials => {
                        force_extract = false;
                        n.promptManual("Could not read a Slack session from the desktop app.") catch break;
                        continue;
                    },
                    else => {
                        n.emitConnection(.offline);
                        n.emitStatus("Disconnected ({s}); reconnecting in {d}s", .{ @errorName(err), backoff_s });
                    },
                }
            };
            if (n.quit.load(.acquire)) break;
            n.sleepInterruptible(backoff_s);
            backoff_s = @min(backoff_s * 2, 30);
        }
    }

    fn sleepInterruptible(n: *Net, seconds: u32) void {
        var left: u32 = seconds * 10;
        while (left > 0 and !n.quit.load(.acquire)) : (left -= 1) {
            n.io.sleep(.fromMilliseconds(100), .awake) catch return;
        }
    }

    const SessionError = error{ NoCredentials, AuthFailed, Api, Socket, SwitchTeam, Quit } || std.mem.Allocator.Error;

    fn dropCreds(n: *Net) void {
        if (n.creds) |*c| c.deinit();
        n.creds = null;
        slack.desktop.keyring.clearSession(n.gpa, n.io);
    }

    /// Our saved session first, then the desktop app's (saved afterwards)
    fn obtainCreds(n: *Net, force: bool) SessionError!slack.desktop.Credentials {
        if (!force) saved: {
            const json_text = slack.desktop.keyring.loadSession(n.gpa, n.io) catch break :saved;
            defer {
                std.crypto.secureZero(u8, json_text);
                n.gpa.free(json_text);
            }
            return slack.desktop.Credentials.fromJson(n.gpa, json_text) catch break :saved;
        }
        n.emitStatus("Reading Slack session…", .{});
        var creds = slack.desktop.extract(n.gpa, n.io, n.env) catch |err| {
            n.dbg("extract failed: {s}", .{@errorName(err)});
            return error.NoCredentials;
        };
        n.saveCreds(&creds);
        return creds;
    }

    fn saveCreds(n: *Net, creds: *const slack.desktop.Credentials) void {
        const json_text = creds.toJson(n.gpa) catch return;
        defer {
            std.crypto.secureZero(u8, json_text);
            n.gpa.free(json_text);
        }
        slack.desktop.keyring.storeSession(n.gpa, n.io, json_text) catch |err| {
            n.dbg("could not save session to the keyring: {s}", .{@errorName(err)});
        };
    }

    /// Asks the UI for a token and cookie and waits until a working pair
    /// arrives (or the app quits)
    fn promptManual(n: *Net, reason: []const u8) SessionError!void {
        n.emitConnection(.offline);
        n.emit(.{ .arena = std.heap.ArenaAllocator.init(n.gpa), .update = .{ .status = "" } });
        n.emitNeedManual(reason);
        while (!n.quit.load(.acquire)) {
            var cmds: std.ArrayList(Command) = .empty;
            defer cmds.deinit(n.gpa);
            n.commands.drain(n.gpa, n.io, &cmds) catch return error.OutOfMemory;
            var done = false;
            for (cmds.items) |cmd| {
                defer cmd.deinit(n.gpa);
                if (done) continue;
                const m = switch (cmd) {
                    .manual => |m| m,
                    else => continue,
                };
                if (n.tryManual(m.url, m.token, m.cookie)) |problem| {
                    n.emitNeedManual(problem);
                } else {
                    done = true;
                }
            }
            if (done) {
                n.emit(.{ .arena = std.heap.ArenaAllocator.init(n.gpa), .update = .manual_done });
                return;
            }
            n.io.sleep(.fromMilliseconds(100), .awake) catch return error.Quit;
        }
        return error.Quit;
    }

    fn emitNeedManual(n: *Net, reason: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(n.gpa);
        const copy = arena.allocator().dupe(u8, reason) catch {
            arena.deinit();
            return;
        };
        n.emit(.{ .arena = arena, .update = .{ .need_manual = copy } });
    }

    /// Checks pasted credentials with auth.test; null means they work and
    /// are now in use and saved
    fn tryManual(n: *Net, url_in: []const u8, token: []const u8, cookie_in: []const u8) ?[]const u8 {
        const token_t = std.mem.trim(u8, token, " \t\r\n\"'");
        var cookie_t = std.mem.trim(u8, cookie_in, " \t\r\n\"';");
        if (std.mem.startsWith(u8, cookie_t, "d=")) cookie_t = cookie_t[2..];
        if (!std.mem.startsWith(u8, token_t, "xoxc-")) return "The token should start with xoxc-";
        if (!std.mem.startsWith(u8, cookie_t, "xoxd-")) return "The d cookie should start with xoxd-";
        const url = normalizeUrl(n.gpa, url_in) catch return "Out of memory";
        defer n.gpa.free(url);
        if (url.len == 0) return "Enter your workspace address, like https://yourteam.slack.com";

        var tmp = std.heap.ArenaAllocator.init(n.gpa);
        defer tmp.deinit();
        var api = slack.http.Api.init(n.gpa, n.io, url, token_t, cookie_t);
        defer api.deinit();
        const auth = api.call(tmp.allocator(), "auth.test", &.{}) catch |err| {
            if (err == error.SlackError) return "Slack rejected that token and cookie pair";
            return "Could not reach Slack to check them";
        };
        var creds = slack.desktop.Credentials.fromManual(n.gpa, .{
            .team_id = json.str(auth.object, "team_id") orelse "",
            .name = json.str(auth.object, "team") orelse "",
            .url = url,
            .token = token_t,
        }, cookie_t) catch return "Out of memory";
        n.saveCreds(&creds);
        if (n.creds) |*old| old.deinit();
        n.creds = creds;
        return null;
    }

    /// One connected session; returns on any failure so `run` can react
    fn session(n: *Net, force_extract: bool) SessionError!void {
        var arena_state = std.heap.ArenaAllocator.init(n.gpa);
        defer arena_state.deinit();

        n.emitConnection(.connecting);
        if (n.creds == null) n.creds = try n.obtainCreds(force_extract);
        const creds = &n.creds.?;
        const ws = n.pickWorkspace(creds.workspaces) orelse return error.NoCredentials;
        n.dbg("session start, {d} workspace(s)", .{creds.workspaces.len});

        try n.announceTeams(creds.workspaces, ws.team_id);
        var api = slack.http.Api.init(n.gpa, n.io, ws.url, ws.token, creds.cookie);
        api.abort = &n.switch_pending;
        defer api.deinit();

        const self_id = try n.bootstrap(&api, &arena_state);
        n.bootstrapped = true;

        var sock = slack.realtime.Socket.connect(n.gpa, n.io, ws.team_id, ws.token, creds.cookie) catch return error.Socket;
        defer sock.deinit();
        n.emitConnection(.online);
        n.emitStatus("", .{});
        n.dbg("socket connected", .{});
        try n.loop(&api, &sock, self_id);
    }

    /// Order: the UI's choice, the command line, the last used, the first
    fn pickWorkspace(n: *Net, list: []const slack.desktop.Workspace) ?slack.desktop.Workspace {
        if (list.len == 0) return null;
        if (n.team_pref) |id| for (list) |w| if (std.mem.eql(u8, w.team_id, id)) return w;
        if (n.shown_team == null) {
            if (n.team_hint) |hint| for (list) |w| {
                if (containsIgnoreCase(w.name, hint) or containsIgnoreCase(w.url, hint)) return w;
            };
            if (n.last_team.len > 0) for (list) |w| if (std.mem.eql(u8, w.team_id, n.last_team)) return w;
        }
        // Reconnecting: stay on the team that is shown
        if (n.shown_team) |id| for (list) |w| if (std.mem.eql(u8, w.team_id, id)) return w;
        return list[0];
    }

    /// Tells the UI which workspaces exist and which is shown; resets the
    /// store when the shown one changes. Remembers the choice.
    fn announceTeams(n: *Net, list: []const slack.desktop.Workspace, active: []const u8) SessionError!void {
        var item_arena = std.heap.ArenaAllocator.init(n.gpa);
        errdefer item_arena.deinit();
        const ia = item_arena.allocator();
        const infos = try ia.alloc(store.TeamInfo, list.len);
        for (list, infos) |w, *info| info.* = .{
            .id = try ia.dupe(u8, w.team_id),
            .name = try ia.dupe(u8, w.name),
            .url = try ia.dupe(u8, w.url),
        };
        const active_copy = try ia.dupe(u8, active);

        const changed = if (n.shown_team) |t| !std.mem.eql(u8, t, active) else false;
        n.emit(.{ .arena = item_arena, .update = .{ .teams = .{ .list = infos, .active = active_copy } } });

        if (n.shown_team == null or changed) {
            if (n.shown_team) |t| n.gpa.free(t);
            n.shown_team = try n.gpa.dupe(u8, active);
            if (changed) {
                if (n.active) |a| n.gpa.free(a);
                n.active = null;
            }
            if (n.config_dir) |d| state_file.save(n.gpa, n.io, d, .{ .last_team = active });
        }
        n.cur = try n.cacheFor(active);
    }

    fn cacheFor(n: *Net, team: []const u8) std.mem.Allocator.Error!*TeamCache {
        if (n.caches.get(team)) |c| return c;
        const key = try n.gpa.dupe(u8, team);
        errdefer n.gpa.free(key);
        const c = try n.gpa.create(TeamCache);
        errdefer n.gpa.destroy(c);
        c.* = .{};
        try n.caches.put(n.gpa, key, c);
        return c;
    }

    /// Looks at the UI's commands between steps of a session start: a switch
    /// to another workspace ends this session (so the new one starts
    /// without waiting for this one to load); the rest wait their turn.
    fn checkpoint(n: *Net) SessionError!void {
        var cmds: std.ArrayList(Command) = .empty;
        defer cmds.deinit(n.gpa);
        n.commands.drain(n.gpa, n.io, &cmds) catch return error.OutOfMemory;
        var target: ?[]u8 = null;
        defer if (target) |t| n.gpa.free(t);
        for (cmds.items) |cmd| switch (cmd) {
            .switch_team => |id| {
                if (target) |old| n.gpa.free(old);
                target = id;
            },
            else => n.deferred.append(n.gpa, cmd) catch cmd.deinit(n.gpa),
        };
        const id = target orelse return;
        n.switch_pending.store(false, .release);
        if (n.team_pref) |old| n.gpa.free(old);
        n.team_pref = try n.gpa.dupe(u8, id);
        const same = if (n.shown_team) |t| std.mem.eql(u8, t, id) else false;
        if (!same) return error.SwitchTeam;
    }

    /// auth.test, conversations, users, unread state. Returns our user id (arena-owned).
    fn bootstrap(n: *Net, api: *slack.http.Api, arena_state: *std.heap.ArenaAllocator) SessionError![]const u8 {
        const arena = arena_state.allocator();
        const auth = api.call(arena, "auth.test", &.{}) catch |err| return n.apiFailed(api, "auth.test", err);
        const self_id = json.str(auth.object, "user_id") orelse return error.Api;
        n.gpa.free(n.self_id);
        n.self_id = try n.gpa.dupe(u8, self_id);
        {
            var item_arena = std.heap.ArenaAllocator.init(n.gpa);
            errdefer item_arena.deinit();
            const ia = item_arena.allocator();
            // Allocate first: the arena is copied into the item after
            const user_id = try ia.dupe(u8, self_id);
            const team_name = try ia.dupe(u8, json.str(auth.object, "team") orelse "");
            n.emit(.{ .arena = item_arena, .update = .{ .self = .{ .user_id = user_id, .team_name = team_name } } });
        }
        // A quick reconnect (or coming back to a workspace) keeps what the
        // store has; unreads always refresh
        const now = store.nowMs(n.io);
        const cache = n.cur.?;
        if (cache.full_ms == 0 or now - cache.full_ms > full_refresh_ms) {
            try n.checkpoint();
            try n.fetchSidebarMode(api);
            try n.checkpoint();
            try n.fetchConversations(api);
            try n.checkpoint();
            try n.fetchUsers(api);
            cache.full_ms = now;
        } else n.dbg("quick reconnect: keeping conversations and users", .{});
        try n.checkpoint();
        try n.fetchUnreads(api);
        return self_id;
    }

    /// Slack refusing one call is `Api` (the session carries on); anything
    /// else means the connection is in trouble
    fn apiFailed(n: *Net, api: *slack.http.Api, method: []const u8, err: anyerror) SessionError {
        if (err == error.Aborted) {
            // The UI wants another workspace: that decides, not this failure
            n.checkpoint() catch |e| return e;
            return error.Socket;
        }
        if (err == error.SlackError) {
            n.emitStatus("{s} failed: {s}", .{ method, api.diag.slackError() });
            return if (api.diag.isAuthError()) error.AuthFailed else error.Api;
        }
        n.emitStatus("{s} failed: {s}", .{ method, @errorName(err) });
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.Socket;
    }

    /// One conversation failing to load does not end the session
    fn soft(err: SessionError) SessionError!void {
        switch (err) {
            error.Api => {},
            else => return err,
        }
    }

    /// The user's sidebar preference ("Most recent", "Unreads only", ...).
    /// Best effort: without it the sidebar assumes "Most recent".
    fn fetchSidebarMode(n: *Net, api: *slack.http.Api) SessionError!void {
        var tmp = std.heap.ArenaAllocator.init(n.gpa);
        defer tmp.deinit();
        const res = api.call(tmp.allocator(), "users.prefs.get", &.{}) catch |err| {
            if (err == error.SlackError and api.diag.isAuthError()) return error.AuthFailed;
            if (err == error.Aborted) return n.apiFailed(api, "users.prefs.get", err);
            n.dbg("users.prefs.get failed: {s}", .{@errorName(err)});
            return;
        };
        const prefs = json.obj(res.object, "prefs") orelse return;
        const mode = store.SidebarMode.parse(json.str(prefs, "sidebar_behavior") orelse "");
        n.dbg("sidebar mode: {s}", .{@tagName(mode)});
        n.emit(.{ .arena = std.heap.ArenaAllocator.init(n.gpa), .update = .{ .sidebar_mode = mode } });
    }

    /// Initial read state, the way the web client gets it. Best effort: it
    /// is an internal endpoint, so a failure only costs the unread dots.
    /// Also picks what to load in the background: unread conversations,
    /// then the busiest DMs.
    fn fetchUnreads(n: *Net, api: *slack.http.Api) SessionError!void {
        var tmp = std.heap.ArenaAllocator.init(n.gpa);
        defer tmp.deinit();
        const res = api.call(tmp.allocator(), "client.counts", &.{}) catch |err| {
            if (err == error.SlackError and api.diag.isAuthError()) return error.AuthFailed;
            if (err == error.Aborted) return n.apiFailed(api, "client.counts", err);
            n.dbg("client.counts failed: {s}", .{@errorName(err)});
            return;
        };
        var item_arena = std.heap.ArenaAllocator.init(n.gpa);
        errdefer item_arena.deinit();
        const ia = item_arena.allocator();
        var out: std.ArrayList(store.UnreadInfo) = .empty;
        inline for (.{ "channels", "mpims", "ims" }) |key| {
            for (json.arr(res.object, key)) |v| {
                if (v != .object) continue;
                const o = v.object;
                const id = json.str(o, "id") orelse continue;
                const mentions: u32 = if (o.get("mention_count")) |m| (if (m == .integer) std.math.cast(u32, m.integer) orelse 0 else 0) else 0;
                try out.append(ia, .{
                    .id = try ia.dupe(u8, id),
                    .has_unreads = json.flag(o, "has_unreads"),
                    .mentions = mentions,
                    .latest = try ia.dupe(u8, json.str(o, "latest") orelse ""),
                });
            }
        }
        try n.pickPrefetch(out.items, tmp.allocator());
        n.emit(.{ .arena = item_arena, .update = .{ .unreads = out.items } });
    }

    /// Unread conversations first, then the most recently active DMs
    fn pickPrefetch(n: *Net, list: []const store.UnreadInfo, scratch: std.mem.Allocator) std.mem.Allocator.Error!void {
        for (n.prefetch.items) |id| n.gpa.free(id);
        n.prefetch.clearRetainingCapacity();
        const dms = try scratch.alloc(store.UnreadInfo, list.len);
        const rest = try scratch.alloc(store.UnreadInfo, list.len);
        var nd: usize = 0;
        var nr: usize = 0;
        for (list) |u| {
            if (n.active) |a| if (std.mem.eql(u8, a, u.id)) continue;
            if (u.has_unreads) {
                dms[nd] = u;
                nd += 1;
            } else if (u.id.len > 0 and (u.id[0] == 'D' or u.id[0] == 'G' or u.id[0] == 'C') and u.latest.len > 0) {
                rest[nr] = u;
                nr += 1;
            }
        }
        const newest = struct {
            fn first(_: void, a: store.UnreadInfo, b: store.UnreadInfo) bool {
                return store.tsLess(b.latest, a.latest);
            }
        }.first;
        std.mem.sort(store.UnreadInfo, dms[0..nd], {}, newest);
        // Recent DMs only (ids starting with D are 1:1): channels load when opened
        var kept: usize = 0;
        for (rest[0..nr]) |u| if (u.id[0] == 'D') {
            rest[kept] = u;
            kept += 1;
        };
        std.mem.sort(store.UnreadInfo, rest[0..kept], {}, newest);
        for (dms[0..nd]) |u| {
            if (n.prefetch.items.len >= prefetch_max) return;
            try n.prefetch.append(n.gpa, try n.gpa.dupe(u8, u.id));
        }
        for (rest[0..kept]) |u| {
            if (n.prefetch.items.len >= prefetch_max) return;
            try n.prefetch.append(n.gpa, try n.gpa.dupe(u8, u.id));
        }
    }

    /// Where one conversation sits in Slack's channel sections
    const Placement = struct { section: []const u8, place: store.SectionPlace, rank: u16 };

    /// The user's channel sections (Starred and custom ones), by conversation
    /// id, the way the web client reads them. Best effort: without them
    /// conversations are listed by kind.
    fn fetchSections(n: *Net, api: *slack.http.Api, arena: std.mem.Allocator) SessionError!std.StringHashMapUnmanaged(Placement) {
        var map: std.StringHashMapUnmanaged(Placement) = .empty;
        var tmp = std.heap.ArenaAllocator.init(n.gpa);
        defer tmp.deinit();
        const res = api.call(tmp.allocator(), "users.channelSections.list", &.{}) catch |err| {
            if (err == error.SlackError and api.diag.isAuthError()) return error.AuthFailed;
            if (err == error.Aborted) return n.apiFailed(api, "users.channelSections.list", err);
            n.dbg("users.channelSections.list failed: {s}", .{@errorName(err)});
            return map;
        };
        const sections = json.arr(res.object, "channel_sections");
        const order = sectionOrder(tmp.allocator(), sections) catch return map;
        // Custom sections count from 0; a section after Direct messages is "below"
        var rank: u16 = 0;
        var after_dms = false;
        for (order) |sv| {
            const o = sv.object;
            const kind = json.str(o, "type") orelse "";
            if (std.mem.eql(u8, kind, "direct_messages")) after_dms = true;
            const place: store.SectionPlace = if (std.mem.eql(u8, kind, "stars")) .starred else if (std.mem.eql(u8, kind, "standard")) (if (after_dms) .below else .above) else continue;
            const name = try arena.dupe(u8, json.str(o, "name") orelse "");
            const ids = if (json.obj(o, "channel_ids_page")) |page| json.arr(page, "channel_ids") else &.{};
            for (ids) |idv| {
                if (idv != .string) continue;
                try map.put(arena, try arena.dupe(u8, idv.string), .{ .section = name, .place = place, .rank = rank });
            }
            if (place != .starred) rank += 1;
        }
        try n.fetchStars(api, arena, &map);
        n.dbg("channel sections: {d}, placing {d} conversations", .{ order.len, map.count() });
        return map;
    }

    /// Starred conversations: Slack's own sidebar fills Starred from
    /// `stars.list`, the section itself comes back empty
    fn fetchStars(n: *Net, api: *slack.http.Api, arena: std.mem.Allocator, map: *std.StringHashMapUnmanaged(Placement)) SessionError!void {
        var page: u32 = 1;
        while (page <= 5) : (page += 1) {
            try n.checkpoint();
            var tmp = std.heap.ArenaAllocator.init(n.gpa);
            defer tmp.deinit();
            var buf: [16]u8 = undefined;
            const page_str = std.fmt.bufPrint(&buf, "{d}", .{page}) catch return;
            const res = api.call(tmp.allocator(), "stars.list", &.{ .{ "page", page_str }, .{ "count", "100" } }) catch |err| {
                if (err == error.SlackError and api.diag.isAuthError()) return error.AuthFailed;
                if (err == error.Aborted) return n.apiFailed(api, "stars.list", err);
                n.dbg("stars.list failed: {s}", .{@errorName(err)});
                return;
            };
            for (json.arr(res.object, "items")) |iv| {
                if (iv != .object) continue;
                const kind = json.str(iv.object, "type") orelse continue;
                // Starred messages and files are Saved items, not sidebar entries
                if (!std.mem.eql(u8, kind, "channel") and !std.mem.eql(u8, kind, "group") and !std.mem.eql(u8, kind, "im")) continue;
                const id = json.str(iv.object, "channel") orelse continue;
                try map.put(arena, try arena.dupe(u8, id), .{ .section = "", .place = .starred, .rank = 0 });
            }
            const pages = if (json.obj(res.object, "paging")) |p| (if (p.get("pages")) |v| (if (v == .integer) v.integer else 1) else 1) else 1;
            if (page >= pages) return;
        }
    }

    fn fetchConversations(n: *Net, api: *slack.http.Api) SessionError!void {
        const cache = n.cur.?;
        cache.clearDmUsers(n.gpa);
        var item_arena = std.heap.ArenaAllocator.init(n.gpa);
        errdefer item_arena.deinit();
        const ia = item_arena.allocator();
        var out: std.ArrayList(store.ChannelInfo) = .empty;
        try n.checkpoint();
        const placed = try n.fetchSections(api, ia);

        var page_arena_state = std.heap.ArenaAllocator.init(n.gpa);
        defer page_arena_state.deinit();
        var cursor: ?[]const u8 = null;
        while (true) {
            try n.checkpoint();
            _ = page_arena_state.reset(.retain_capacity);
            const pa = page_arena_state.allocator();
            var params: std.ArrayList(slack.http.Param) = .empty;
            try params.appendSlice(pa, &.{
                .{ "types", "public_channel,private_channel,mpim,im" },
                .{ "exclude_archived", "true" },
                .{ "limit", "200" },
            });
            if (cursor) |c| try params.append(pa, .{ "cursor", c });
            const res = api.call(pa, "users.conversations", params.items) catch |err| return n.apiFailed(api, "users.conversations", err);
            for (json.arr(res.object, "channels")) |cv| {
                if (cv != .object) continue;
                const o = cv.object;
                const id = json.str(o, "id") orelse continue;
                const kind: store.Kind = if (json.flag(o, "is_im")) .im else if (json.flag(o, "is_mpim")) .mpim else if (json.flag(o, "is_private")) .private else .channel;
                const name = json.str(o, "name") orelse "";
                if (kind == .im) if (json.str(o, "user")) |u| try cache.dm_users.append(n.gpa, try n.gpa.dupe(u8, u));
                try out.append(ia, .{
                    .id = try ia.dupe(u8, id),
                    .name = if (kind == .mpim) try prettyMpim(ia, name) else try ia.dupe(u8, name),
                    .kind = kind,
                    .user_id = if (json.str(o, "user")) |u| try ia.dupe(u8, u) else null,
                    .dormant = if (json.obj(o, "properties")) |p| json.flag(p, "is_dormant") else false,
                    .section = if (placed.get(id)) |pl| pl.section else "",
                    .place = if (placed.get(id)) |pl| pl.place else .none,
                    .section_rank = if (placed.get(id)) |pl| pl.rank else 0,
                });
            }
            const next = json.nextCursor(res) orelse break;
            // The page arena resets next round, so keep the cursor elsewhere
            cursor = try ia.dupe(u8, next);
        }
        n.emit(.{ .arena = item_arena, .update = .{ .channels = out.items } });
    }

    fn fetchUsers(n: *Net, api: *slack.http.Api) SessionError!void {
        var item_arena = std.heap.ArenaAllocator.init(n.gpa);
        errdefer item_arena.deinit();
        const ia = item_arena.allocator();
        var out: std.ArrayList(store.User) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;

        var page_arena_state = std.heap.ArenaAllocator.init(n.gpa);
        defer page_arena_state.deinit();
        var cursor: ?[]const u8 = null;
        while (true) {
            try n.checkpoint();
            _ = page_arena_state.reset(.retain_capacity);
            const pa = page_arena_state.allocator();
            var params: std.ArrayList(slack.http.Param) = .empty;
            try params.appendSlice(pa, &.{.{ "limit", "500" }});
            if (cursor) |c| try params.append(pa, .{ "cursor", c });
            const res = api.call(pa, "users.list", params.items) catch |err| return n.apiFailed(api, "users.list", err);
            for (json.arr(res.object, "members")) |mv| {
                if (mv != .object) continue;
                if (json.flag(mv.object, "deleted")) continue;
                if (try userOf(ia, mv.object)) |user| {
                    try out.append(ia, user);
                    try seen.put(ia, user.id, {});
                }
            }
            const next = json.nextCursor(res) orelse break;
            cursor = try ia.dupe(u8, next);
        }

        // People in our DMs that the list left out (deactivated, external)
        var asked: usize = 0;
        for (n.cur.?.dm_users.items) |id| {
            if (seen.contains(id) or asked >= 40) continue;
            asked += 1;
            try n.checkpoint();
            _ = page_arena_state.reset(.retain_capacity);
            const res = api.call(page_arena_state.allocator(), "users.info", &.{.{ "user", id }}) catch continue;
            const user_obj = json.obj(res.object, "user") orelse continue;
            if (try userOf(ia, user_obj)) |user| try out.append(ia, user);
        }
        n.emit(.{ .arena = item_arena, .update = .{ .users = out.items } });
    }

    /// A page of history. `before` set: the page older than that ts.
    fn fetchHistory(n: *Net, api: *slack.http.Api, channel: []const u8, before: ?[]const u8) SessionError!void {
        var item_arena = std.heap.ArenaAllocator.init(n.gpa);
        errdefer item_arena.deinit();
        const ia = item_arena.allocator();
        var tmp = std.heap.ArenaAllocator.init(n.gpa);
        defer tmp.deinit();
        const ta = tmp.allocator();
        var params: std.ArrayList(slack.http.Param) = .empty;
        try params.appendSlice(ta, &.{ .{ "channel", channel }, .{ "limit", if (before != null) "50" else "100" } });
        if (before) |b| try params.appendSlice(ta, &.{ .{ "latest", b }, .{ "inclusive", "false" } });
        const res = api.call(ta, "conversations.history", params.items) catch |err| return n.apiFailed(api, "conversations.history", err);
        var out: std.ArrayList(store.MessageInfo) = .empty;
        for (json.arr(res.object, "messages")) |mv| {
            if (mv != .object) continue;
            try out.append(ia, try messageInfo(ia, mv.object, n.self_id));
        }
        const channel_copy = try ia.dupe(u8, channel);
        n.emit(.{ .arena = item_arena, .update = .{ .history = .{
            .channel = channel_copy,
            .messages = out.items,
            .has_more = json.flag(res.object, "has_more"),
            .older = before != null,
        } } });
    }

    fn fetchReplies(n: *Net, api: *slack.http.Api, channel: []const u8, ts: []const u8) SessionError!void {
        var item_arena = std.heap.ArenaAllocator.init(n.gpa);
        errdefer item_arena.deinit();
        const ia = item_arena.allocator();
        var tmp = std.heap.ArenaAllocator.init(n.gpa);
        defer tmp.deinit();
        const res = api.call(tmp.allocator(), "conversations.replies", &.{ .{ "channel", channel }, .{ "ts", ts }, .{ "limit", "200" } }) catch |err| return n.apiFailed(api, "conversations.replies", err);
        var out: std.ArrayList(store.MessageInfo) = .empty;
        for (json.arr(res.object, "messages")) |mv| {
            if (mv != .object) continue;
            try out.append(ia, try messageInfo(ia, mv.object, n.self_id));
        }
        const channel_copy = try ia.dupe(u8, channel);
        const ts_copy = try ia.dupe(u8, ts);
        n.emit(.{ .arena = item_arena, .update = .{ .thread_history = .{ .channel = channel_copy, .thread_ts = ts_copy, .messages = out.items } } });
    }

    fn postMessage(n: *Net, api: *slack.http.Api, channel: []const u8, text: []const u8, thread_ts: ?[]const u8) SessionError!void {
        var tmp = std.heap.ArenaAllocator.init(n.gpa);
        defer tmp.deinit();
        const ta = tmp.allocator();
        var params: std.ArrayList(slack.http.Param) = .empty;
        try params.appendSlice(ta, &.{ .{ "channel", channel }, .{ "text", text } });
        if (thread_ts) |t| try params.append(ta, .{ "thread_ts", t });
        const res = api.call(ta, "chat.postMessage", params.items) catch |err| {
            if (err == error.SlackError) {
                if (api.diag.isAuthError()) return error.AuthFailed;
                n.emitStatus("Send failed: {s}", .{api.diag.slackError()});
            } else n.emitStatus("Send failed: {s}", .{@errorName(err)});
            return;
        };
        // The socket echoes it too; the store dedupes by ts
        const ts = json.str(res.object, "ts") orelse return;
        var item_arena = std.heap.ArenaAllocator.init(n.gpa);
        const ia = item_arena.allocator();
        const msg = json.obj(res.object, "message");
        const built: ?store.Update = blk: {
            const ch = ia.dupe(u8, channel) catch break :blk null;
            const info: store.MessageInfo = .{
                .ts = ia.dupe(u8, ts) catch break :blk null,
                .user = if (msg) |m| if (json.str(m, "user")) |u| ia.dupe(u8, u) catch null else null else null,
                .text = ia.dupe(u8, if (msg) |m| json.str(m, "text") orelse text else text) catch break :blk null,
                .thread_ts = if (thread_ts) |t| ia.dupe(u8, t) catch null else null,
            };
            if (thread_ts) |t| break :blk .{ .thread_message = .{ .channel = ch, .thread_ts = ia.dupe(u8, t) catch break :blk null, .message = info } };
            break :blk .{ .message = .{ .channel = ch, .message = info } };
        };
        // Allocate first: the arena is copied into the item after
        if (built) |u| n.emit(.{ .arena = item_arena, .update = u }) else item_arena.deinit();
    }

    /// Slack's upload flow, as the web client does it: an upload URL for each
    /// file (`files.getUploadURL`), its bytes posted there, then one
    /// `files.completeUpload` that posts the message. The socket delivers it.
    fn uploadFiles(n: *Net, api: *slack.http.Api, channel: []const u8, text: []const u8, thread_ts: ?[]const u8, paths: []const []const u8) SessionError!void {
        var tmp = std.heap.ArenaAllocator.init(n.gpa);
        defer tmp.deinit();
        const ta = tmp.allocator();
        const Item = struct { id: []const u8, title: []const u8 };
        var done: std.ArrayList(Item) = .empty;
        for (paths) |path| {
            const name = std.fs.path.basename(path);
            n.emitStatus("Uploading {s}…", .{name});
            const id = n.uploadOne(api, ta, path, name) catch |err| switch (err) {
                error.AuthFailed => return error.AuthFailed,
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    n.emitStatus("Could not upload {s}: {s}", .{ name, uploadProblem(api, err) });
                    continue;
                },
            };
            try done.append(ta, .{ .id = id, .title = name });
        }
        if (done.items.len == 0) return;
        var files: std.Io.Writer.Allocating = .init(ta);
        std.json.Stringify.value(done.items, .{}, &files.writer) catch return error.OutOfMemory;
        var params: std.ArrayList(slack.http.Param) = .empty;
        try params.appendSlice(ta, &.{ .{ "files", files.written() }, .{ "channel", channel } });
        if (text.len > 0) try params.append(ta, .{ "intro", text });
        if (thread_ts) |t| try params.append(ta, .{ "thread_ts", t });
        _ = api.call(ta, "files.completeUpload", params.items) catch |err| {
            if (err == error.SlackError) {
                if (api.diag.isAuthError()) return error.AuthFailed;
                n.emitStatus("Upload failed: {s}", .{api.diag.slackError()});
            } else n.emitStatus("Upload failed: {s}", .{@errorName(err)});
            return;
        };
        n.emitStatus("", .{});
    }

    const UploadError = error{ Unreadable, NotAFile, TooLarge, AuthFailed, NoUploadUrl } || slack.http.Error;

    /// One file's bytes to Slack; its file id.
    fn uploadOne(n: *Net, api: *slack.http.Api, ta: std.mem.Allocator, path: []const u8, name: []const u8) UploadError![]const u8 {
        // The bytes only live while this file uploads
        var fa = std.heap.ArenaAllocator.init(n.gpa);
        defer fa.deinit();
        const a = fa.allocator();
        const file = std.Io.Dir.cwd().openFile(n.io, path, .{}) catch return error.Unreadable;
        defer file.close(n.io);
        const stat = file.stat(n.io) catch return error.Unreadable;
        if (stat.kind != .file) return error.NotAFile;
        if (stat.size > upload_max) return error.TooLarge;
        const size: usize = @intCast(stat.size);
        // head ++ bytes ++ tail, read straight into place
        const parts = try slack.http.multipartParts(a, name);
        const body = try a.alloc(u8, parts.head.len + size + parts.tail.len);
        @memcpy(body[0..parts.head.len], parts.head);
        const got = file.readPositionalAll(n.io, body[parts.head.len..][0..size], 0) catch return error.Unreadable;
        if (got != size) return error.Unreadable;
        @memcpy(body[parts.head.len + size ..], parts.tail);

        const length = try std.fmt.allocPrint(a, "{d}", .{size});
        const res = api.call(a, "files.getUploadURL", &.{ .{ "filename", name }, .{ "length", length } }) catch |err| {
            if (err == error.SlackError and api.diag.isAuthError()) return error.AuthFailed;
            return err;
        };
        const id = json.str(res.object, "file") orelse return error.NoUploadUrl;
        const url = json.str(res.object, "upload_url") orelse return error.NoUploadUrl;
        try api.upload(a, url, body);
        return ta.dupe(u8, id);
    }

    fn uploadProblem(api: *const slack.http.Api, err: UploadError) []const u8 {
        return switch (err) {
            error.Unreadable => "could not read it",
            error.NotAFile => "not a file",
            error.TooLarge => "too large",
            error.SlackError => api.diag.slackError(),
            else => @errorName(err),
        };
    }

    /// A file's preview, for the message that shows it
    fn fetchFileImage(n: *Net, api: *slack.http.Api, id: []const u8, url: []const u8) void {
        n.dbg("fetching file preview {s}", .{id});
        var item_arena = std.heap.ArenaAllocator.init(n.gpa);
        const ia = item_arena.allocator();
        const bytes = api.downloadPrivate(ia, url, 8 << 20) catch |err| {
            n.dbg("file preview failed: {s}", .{@errorName(err)});
            return item_arena.deinit();
        };
        n.dbg("file preview {s}: {d} bytes", .{ id, bytes.len });
        const copy_id = ia.dupe(u8, id) catch return item_arena.deinit();
        n.emit(.{ .arena = item_arena, .update = .{ .file_image = .{ .id = copy_id, .bytes = bytes } } });
    }

    fn markRead(n: *Net, api: *slack.http.Api, channel: []const u8, ts: []const u8) void {
        var tmp = std.heap.ArenaAllocator.init(n.gpa);
        defer tmp.deinit();
        _ = api.call(tmp.allocator(), "conversations.mark", &.{ .{ "channel", channel }, .{ "ts", ts } }) catch {};
    }

    fn fetchFeed(n: *Net, api: *slack.http.Api, kind: store.FeedKind) SessionError!void {
        var item_arena = std.heap.ArenaAllocator.init(n.gpa);
        errdefer item_arena.deinit();
        const ia = item_arena.allocator();
        var tmp = std.heap.ArenaAllocator.init(n.gpa);
        defer tmp.deinit();
        var out: std.ArrayList(store.FeedEntryInfo) = .empty;
        switch (kind) {
            .threads => try n.threadsFeed(api, tmp.allocator(), ia, &out),
            .drafts => try n.draftsFeed(api, tmp.allocator(), ia, &out),
            .saved => try n.savedFeed(api, tmp.allocator(), ia, &out),
        }
        n.emit(.{ .arena = item_arena, .update = .{ .feed = .{ .kind = kind, .entries = out.items } } });
    }

    /// The Threads page: threads you follow, newest activity first
    fn threadsFeed(n: *Net, api: *slack.http.Api, tmp: std.mem.Allocator, ia: std.mem.Allocator, out: *std.ArrayList(store.FeedEntryInfo)) SessionError!void {
        const res = api.call(tmp, "subscriptions.thread.getView", &.{.{ "limit", "30" }}) catch |err| return n.apiFailed(api, "subscriptions.thread.getView", err);
        for (json.arr(res.object, "threads")) |tv| {
            if (tv != .object) continue;
            const root = json.obj(tv.object, "root_msg") orelse continue;
            const channel = json.str(root, "channel") orelse continue;
            const ts = json.str(root, "ts") orelse continue;
            const replies = json.arr(tv.object, "latest_replies");
            const newest: ?std.json.ObjectMap = if (replies.len > 0 and replies[replies.len - 1] == .object) replies[replies.len - 1].object else null;
            const count: u32 = if (root.get("reply_count")) |c| (if (c == .integer) std.math.cast(u32, c.integer) orelse 0 else 0) else 0;
            const last_read = json.str(root, "last_read") orelse "";
            const latest = json.str(root, "latest_reply") orelse "";
            try out.append(ia, .{
                .channel = try ia.dupe(u8, channel),
                .ts = try ia.dupe(u8, ts),
                .thread_ts = try ia.dupe(u8, json.str(root, "thread_ts") orelse ts),
                .user = try ia.dupe(u8, json.str(root, "user") orelse json.str(root, "bot_id") orelse ""),
                .text = try ia.dupe(u8, json.str(root, "text") orelse ""),
                .note = try std.fmt.allocPrint(ia, "{d} {s}", .{ count, if (count == 1) "reply" else "replies" }),
                .reply_user = if (newest) |r| try ia.dupe(u8, json.str(r, "user") orelse json.str(r, "bot_id") orelse "") else "",
                .reply_text = if (newest) |r| try ia.dupe(u8, json.str(r, "text") orelse "") else "",
                .unread = latest.len > 0 and store.tsLess(last_read, latest),
            });
        }
    }

    /// Drafts & sent: your drafts, scheduled messages and sent ones
    fn draftsFeed(n: *Net, api: *slack.http.Api, tmp: std.mem.Allocator, ia: std.mem.Allocator, out: *std.ArrayList(store.FeedEntryInfo)) SessionError!void {
        const res = api.call(tmp, "drafts.list", &.{}) catch |err| return n.apiFailed(api, "drafts.list", err);
        const drafts = json.arr(res.object, "drafts");
        // Drafts first, then scheduled ones, then sent ones; each newest first as Slack lists them
        for ([_][]const u8{ "Draft", "Scheduled", "Sent" }) |wanted| {
            for (drafts) |dv| {
                if (dv != .object) continue;
                const o = dv.object;
                if (json.flag(o, "is_deleted")) continue;
                const scheduled = if (o.get("date_scheduled")) |v| (v == .integer and v.integer > 0) else false;
                const label: []const u8 = if (json.flag(o, "is_sent")) "Sent" else if (scheduled) "Scheduled" else "Draft";
                if (!std.mem.eql(u8, label, wanted)) continue;
                const dests = json.arr(o, "destinations");
                if (dests.len == 0 or dests[0] != .object) continue;
                const channel = json.str(dests[0].object, "channel_id") orelse continue;
                const sent_ts = json.str(dests[0].object, "message_ts") orelse "";
                const ts = if (sent_ts.len > 0) sent_ts else json.str(o, "last_updated_ts") orelse "";
                var text: std.ArrayList(u8) = .empty;
                try richText(ia, &text, json.arr(o, "blocks"));
                try out.append(ia, .{
                    .channel = try ia.dupe(u8, channel),
                    .ts = try ia.dupe(u8, ts),
                    .user = try ia.dupe(u8, json.str(o, "user_id") orelse ""),
                    .text = text.items,
                    .note = label,
                });
            }
        }
    }

    /// Saved items still in progress, with each message's text
    fn savedFeed(n: *Net, api: *slack.http.Api, tmp: std.mem.Allocator, ia: std.mem.Allocator, out: *std.ArrayList(store.FeedEntryInfo)) SessionError!void {
        const res = api.call(tmp, "saved.list", &.{}) catch |err| return n.apiFailed(api, "saved.list", err);
        for (json.arr(res.object, "saved_items")) |sv| {
            if (sv != .object or out.items.len >= saved_max) continue;
            const o = sv.object;
            if (!std.mem.eql(u8, json.str(o, "item_type") orelse "", "message")) continue;
            if (json.flag(o, "is_archived")) continue;
            if (o.get("date_completed")) |v| if (v == .integer and v.integer > 0) continue;
            const channel = json.str(o, "item_id") orelse continue;
            const ts = json.str(o, "ts") orelse continue;
            try n.checkpoint();
            var user: []const u8 = "";
            var text: []const u8 = "";
            // The item names a message by channel and ts only
            if (api.call(tmp, "conversations.history", &.{ .{ "channel", channel }, .{ "latest", ts }, .{ "inclusive", "true" }, .{ "limit", "1" } })) |hist| {
                const msgs = json.arr(hist.object, "messages");
                if (msgs.len > 0 and msgs[0] == .object and std.mem.eql(u8, json.str(msgs[0].object, "ts") orelse "", ts)) {
                    user = try ia.dupe(u8, json.str(msgs[0].object, "user") orelse json.str(msgs[0].object, "bot_id") orelse "");
                    text = try ia.dupe(u8, json.str(msgs[0].object, "text") orelse "");
                }
            } else |err| if (err == error.Aborted) return n.apiFailed(api, "conversations.history", err);
            try out.append(ia, .{ .channel = try ia.dupe(u8, channel), .ts = try ia.dupe(u8, ts), .user = user, .text = text });
        }
    }

    fn callPresence(n: *Net, api: *slack.http.Api, away: bool) void {
        var tmp = std.heap.ArenaAllocator.init(n.gpa);
        defer tmp.deinit();
        _ = api.call(tmp.allocator(), "users.setPresence", &.{.{ "presence", if (away) "away" else "auto" }}) catch |err| {
            if (err == error.SlackError) n.dbg("setPresence failed: {s}", .{api.diag.slackError()});
        };
    }

    fn callReact(n: *Net, api: *slack.http.Api, channel: []const u8, ts: []const u8, name: []const u8, add: bool) SessionError!void {
        var tmp = std.heap.ArenaAllocator.init(n.gpa);
        defer tmp.deinit();
        _ = api.call(tmp.allocator(), if (add) "reactions.add" else "reactions.remove", &.{ .{ "channel", channel }, .{ "timestamp", ts }, .{ "name", name } }) catch |err| {
            if (err == error.SlackError) {
                if (api.diag.isAuthError()) return error.AuthFailed;
                // Already reacted and similar are not worth a status
                n.dbg("reaction failed: {s}", .{api.diag.slackError()});
            }
        };
        // The socket reports the change; the store updates from that
    }

    /// A call on one message whose result is the socket's echo (an edit, a
    /// delete) or nothing to show (a save). A failure goes to the status line.
    fn callMessage(n: *Net, api: *slack.http.Api, method: []const u8, what: []const u8, params: []const slack.http.Param) SessionError!void {
        var tmp = std.heap.ArenaAllocator.init(n.gpa);
        defer tmp.deinit();
        _ = api.call(tmp.allocator(), method, params) catch |err| {
            if (err == error.SlackError) {
                if (api.diag.isAuthError()) return error.AuthFailed;
                n.emitStatus("{s} failed: {s}", .{ what, api.diag.slackError() });
            } else n.emitStatus("{s} failed: {s}", .{ what, @errorName(err) });
        };
    }

    /// presence_sub for the people in our DMs, then ask for their current
    /// state (the socket is opened with no_query_on_subscribe)
    fn subscribePresence(n: *Net, sock: *slack.realtime.Socket) void {
        const dm_users = (n.cur orelse return).dm_users.items;
        var from: usize = 0;
        while (from < dm_users.len) {
            const end = @min(from + 100, dm_users.len);
            inline for (.{ "presence_sub", "presence_query" }) |kind| {
                var aw: std.Io.Writer.Allocating = .init(n.gpa);
                defer aw.deinit();
                std.json.Stringify.value(.{ .type = kind, .ids = dm_users[from..end] }, .{}, &aw.writer) catch return;
                sock.send(aw.written()) catch return;
            }
            from = end;
        }
    }

    fn loop(n: *Net, api: *slack.http.Api, sock: *slack.realtime.Socket, self_id: []const u8) SessionError!void {
        _ = self_id;
        var loaded: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = loaded.keyIterator();
            while (it.next()) |k| n.gpa.free(k.*);
            loaded.deinit(n.gpa);
        }
        const started = std.Io.Timestamp.now(n.io, .awake);
        var last_frame = started;
        var last_ping = started;
        var last_background = started;
        var icon_next: usize = 0;

        // After a reconnect the open conversation may have missed messages
        if (n.active) |a| {
            try loaded.put(n.gpa, try n.gpa.dupe(u8, a), {});
            n.fetchHistory(api, a, null) catch |e| try soft(e);
        }

        while (!n.quit.load(.acquire)) {
            // Commands from the UI, after any that waited while this session started
            var cmds: std.ArrayList(Command) = .empty;
            defer cmds.deinit(n.gpa);
            try cmds.appendSlice(n.gpa, n.deferred.items);
            n.deferred.clearRetainingCapacity();
            n.commands.drain(n.gpa, n.io, &cmds) catch return error.OutOfMemory;
            var next: usize = 0;
            // Whatever is left when this returns early waits for the next session
            defer for (cmds.items[next..]) |rest| n.deferred.append(n.gpa, rest) catch rest.deinit(n.gpa);
            while (next < cmds.items.len) {
                const cmd = cmds.items[next];
                next += 1;
                defer cmd.deinit(n.gpa);
                switch (cmd) {
                    .quit => return,
                    .send => |m| try n.postMessage(api, m.channel, m.text, m.thread_ts),
                    .fetch_image => |m| n.fetchFileImage(api, m.id, m.url),
                    .upload => |m| try n.uploadFiles(api, m.channel, m.text, m.thread_ts, m.paths),
                    .mark => |m| n.markRead(api, m.channel, m.ts),
                    .presence => |away| n.callPresence(api, away),
                    .feed => |kind| n.fetchFeed(api, kind) catch |e| try soft(e),
                    .older => |m| n.fetchHistory(api, m.channel, m.before) catch |e| try soft(e),
                    .open_thread => |m| n.fetchReplies(api, m.channel, m.ts) catch |e| try soft(e),
                    .react => |m| try n.callReact(api, m.channel, m.ts, m.name, m.add),
                    .edit => |m| try n.callMessage(api, "chat.update", "Edit", &.{ .{ "channel", m.channel }, .{ "ts", m.ts }, .{ "text", m.text } }),
                    .delete => |m| try n.callMessage(api, "chat.delete", "Delete", &.{ .{ "channel", m.channel }, .{ "ts", m.ts } }),
                    .save => |m| try n.callMessage(api, "saved.add", "Save", &.{ .{ "item_type", "message" }, .{ "item_id", m.channel }, .{ "ts", m.ts } }),
                    .typing => |ch| n.sendTyping(sock, ch),
                    .manual => {},
                    .switch_team => |id| {
                        n.switch_pending.store(false, .release);
                        if (n.team_pref) |old| n.gpa.free(old);
                        n.team_pref = try n.gpa.dupe(u8, id);
                        const same = if (n.shown_team) |t| std.mem.eql(u8, t, id) else false;
                        if (!same) return error.SwitchTeam;
                    },
                    .open => |ch| {
                        if (n.active) |a| n.gpa.free(a);
                        n.active = try n.gpa.dupe(u8, ch);
                        if (!loaded.contains(ch)) {
                            try loaded.put(n.gpa, try n.gpa.dupe(u8, ch), {});
                            n.fetchHistory(api, ch, null) catch |e| try soft(e);
                        }
                    },
                }
            }

            const now = std.Io.Timestamp.now(n.io, .awake);
            if (secondsSince(last_ping, now) >= 20) {
                sock.ping() catch return error.Socket;
                last_ping = now;
            }
            // Slack answers pings: silence for a minute means a dead connection
            if (secondsSince(last_frame, now) >= n.stale_secs) {
                n.dbg("no frames for {d}s: stale, reconnecting", .{n.stale_secs});
                n.emitStatus("Connection stale; reconnecting", .{});
                return error.Socket;
            }

            // Background work, one step at a time and only while the UI is quiet:
            // the workspaces' icons, then the busiest conversations
            if (millisSince(last_background, now) >= prefetch_gap_ms and n.commands.isEmpty(n.io)) {
                const icon_ws: ?slack.desktop.Workspace = if (n.creds) |creds| (if (icon_next < creds.workspaces.len) creds.workspaces[icon_next] else null) else null;
                if (icon_ws) |ws| {
                    n.fetchIcon(ws, n.creds.?.cookie);
                    icon_next += 1;
                    last_background = std.Io.Timestamp.now(n.io, .awake);
                } else if (n.prefetch.items.len > 0) {
                    const id = n.prefetch.orderedRemove(0);
                    defer n.gpa.free(id);
                    if (!loaded.contains(id)) {
                        try loaded.put(n.gpa, try n.gpa.dupe(u8, id), {});
                        n.dbg("prefetching a conversation", .{});
                        n.fetchHistory(api, id, null) catch |e| try soft(e);
                    }
                    last_background = std.Io.Timestamp.now(n.io, .awake);
                }
            }

            const frame = (sock.next(200) catch return error.Socket) orelse continue;
            last_frame = std.Io.Timestamp.now(n.io, .awake);
            n.handleFrame(frame, sock);
        }
    }

    /// A workspace's icon, once per run: `team.info`, then the picture
    fn fetchIcon(n: *Net, ws: slack.desktop.Workspace, cookie: []const u8) void {
        const cache = n.cacheFor(ws.team_id) catch return;
        if (cache.icon_tried) return;
        cache.icon_tried = true;
        var arena_state = std.heap.ArenaAllocator.init(n.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var api = slack.http.Api.init(n.gpa, n.io, ws.url, ws.token, cookie);
        defer api.deinit();
        const info = api.call(arena, "team.info", &.{}) catch return;
        const team = json.obj(info.object, "team") orelse return;
        const icon = json.obj(team, "icon") orelse return;
        // The stock placeholder is no better than the initial we draw
        if (json.flag(icon, "image_default")) return;
        const url = json.str(icon, "image_132") orelse json.str(icon, "image_102") orelse json.str(icon, "image_88") orelse return;
        const bytes = api.download(arena, url, 512 * 1024) catch return;
        n.dbg("icon downloaded: {d} bytes, png={}", .{ bytes.len, std.mem.startsWith(u8, bytes, "\x89PNG") });
        var item_arena = std.heap.ArenaAllocator.init(n.gpa);
        const ia = item_arena.allocator();
        const built: ?store.Update = blk: {
            const id = ia.dupe(u8, ws.team_id) catch break :blk null;
            const copy = ia.dupe(u8, bytes) catch break :blk null;
            break :blk .{ .team_icon = .{ .team = id, .bytes = copy } };
        };
        // Allocate first: the arena is copied into the item after
        if (built) |u| n.emit(.{ .arena = item_arena, .update = u }) else item_arena.deinit();
    }

    fn sendTyping(n: *Net, sock: *slack.realtime.Socket, channel: []const u8) void {
        var aw: std.Io.Writer.Allocating = .init(n.gpa);
        defer aw.deinit();
        std.json.Stringify.value(.{ .type = "typing", .channel = channel }, .{}, &aw.writer) catch return;
        sock.send(aw.written()) catch {};
    }

    fn millisSince(from: std.Io.Timestamp, to: std.Io.Timestamp) i64 {
        return @intCast(@divTrunc(from.durationTo(to).toNanoseconds(), std.time.ns_per_ms));
    }

    fn secondsSince(from: std.Io.Timestamp, to: std.Io.Timestamp) i64 {
        return @intCast(@divTrunc(from.durationTo(to).toNanoseconds(), std.time.ns_per_s));
    }

    fn handleFrame(n: *Net, frame: []const u8, sock: *slack.realtime.Socket) void {
        n.translate(frame, sock, false);
        // Thread replies are a second update from the same frame
        if (std.mem.indexOf(u8, frame, "\"thread_ts\"") != null) n.translate(frame, sock, true);
    }

    /// One frame to at most one store update. `as_thread`: only the thread
    /// view of a reply; otherwise everything but that.
    fn translate(n: *Net, frame: []const u8, sock: *slack.realtime.Socket, as_thread: bool) void {
        var item_arena = std.heap.ArenaAllocator.init(n.gpa);
        const ia = item_arena.allocator();
        const ev = slack.events.parse(ia, frame) catch {
            item_arena.deinit();
            return;
        };
        if (as_thread) {
            const m = switch (ev) {
                .message => |m| m,
                else => return item_arena.deinit(),
            };
            if (m.hidden or !m.isThreadReply()) return item_arena.deinit();
            n.emit(.{ .arena = item_arena, .update = .{ .thread_message = .{
                .channel = m.channel,
                .thread_ts = m.thread_ts.?,
                .message = .{ .ts = m.ts, .user = m.user, .text = m.text, .thread_ts = m.thread_ts, .subtype = m.subtype, .files = fileInfos(item_arena.allocator(), m.files) catch &.{} },
            } } });
            return;
        }
        const update: ?store.Update = switch (ev) {
            .hello => blk: {
                n.subscribePresence(sock);
                break :blk null;
            },
            .message => |m| blk: {
                const broadcast = if (m.subtype) |sub| std.mem.eql(u8, sub, "thread_broadcast") else false;
                // Replies live in the thread view, unless broadcast to the channel
                if (m.hidden or (m.isThreadReply() and !broadcast)) break :blk null;
                break :blk .{ .message = .{ .channel = m.channel, .message = .{
                    .ts = m.ts,
                    .user = m.user,
                    .text = m.text,
                    .thread_ts = m.thread_ts,
                    .subtype = m.subtype,
                    .files = fileInfos(item_arena.allocator(), m.files) catch &.{},
                } } };
            },
            .message_changed => |c| .{ .edited = .{ .channel = c.channel, .ts = c.ts, .text = c.text, .files = fileInfos(item_arena.allocator(), c.files) catch &.{} } },
            .message_deleted => |d| .{ .deleted = .{ .channel = d.channel, .ts = d.ts } },
            .reply_count => |r| .{ .reply_count = .{ .channel = r.channel, .ts = r.ts, .count = r.count } },
            .reaction => |r| .{ .reaction = .{ .channel = r.channel, .ts = r.ts, .name = r.name, .user = r.user, .added = r.added } },
            .typing => |t| .{ .typing = .{ .channel = t.channel, .user = t.user, .at_ms = store.nowMs(n.io) } },
            .presence => |p| .{ .presence = .{ .users = p.users, .active = std.mem.eql(u8, p.state, "active") } },
            .marked => |m| .{ .marked = .{ .channel = m.channel, .ts = m.ts, .unread = m.unread, .mentions = m.mentions } },
            else => null,
        };
        if (update) |u| {
            n.emit(.{ .arena = item_arena, .update = u });
        } else item_arena.deinit();
    }
};

/// A user object to the name we show: display name, else real name, else handle
/// The text of Block Kit rich text, in mrkdwn the renderer understands
fn richText(arena: std.mem.Allocator, out: *std.ArrayList(u8), nodes: []const std.json.Value) std.mem.Allocator.Error!void {
    for (nodes) |nv| {
        if (nv != .object) continue;
        const o = nv.object;
        const kind = json.str(o, "type") orelse "";
        if (std.mem.eql(u8, kind, "text")) {
            try out.appendSlice(arena, json.str(o, "text") orelse "");
        } else if (std.mem.eql(u8, kind, "link")) {
            try out.appendSlice(arena, json.str(o, "url") orelse "");
        } else if (std.mem.eql(u8, kind, "user")) {
            try out.print(arena, "<@{s}>", .{json.str(o, "user_id") orelse ""});
        } else if (std.mem.eql(u8, kind, "channel")) {
            try out.print(arena, "<#{s}>", .{json.str(o, "channel_id") orelse ""});
        } else if (std.mem.eql(u8, kind, "emoji")) {
            try out.print(arena, ":{s}:", .{json.str(o, "name") orelse ""});
        } else if (std.mem.eql(u8, kind, "broadcast")) {
            try out.print(arena, "@{s}", .{json.str(o, "range") orelse "here"});
        }
        try richText(arena, out, json.arr(o, "elements"));
        // Sections of a list or paragraphs run on a new line
        if (std.mem.eql(u8, kind, "rich_text_list") or std.mem.eql(u8, kind, "rich_text_preformatted")) try out.append(arena, '\n');
    }
}

/// The sections in sidebar order: Slack links each to the next one
fn sectionOrder(arena: std.mem.Allocator, sections: []const std.json.Value) std.mem.Allocator.Error![]const std.json.Value {
    var out: std.ArrayList(std.json.Value) = .empty;
    var by_id: std.StringHashMapUnmanaged(std.json.Value) = .empty;
    var pointed_at: std.StringHashMapUnmanaged(void) = .empty;
    for (sections) |sv| {
        if (sv != .object) continue;
        const id = json.str(sv.object, "channel_section_id") orelse continue;
        try by_id.put(arena, id, sv);
        if (json.str(sv.object, "next_channel_section_id")) |next| if (next.len > 0) try pointed_at.put(arena, next, {});
    }
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    // The head is the one nothing points at; a broken chain keeps what is left in list order
    for (sections) |head| {
        if (head != .object) continue;
        const hid = json.str(head.object, "channel_section_id") orelse continue;
        if (pointed_at.contains(hid) or visited.contains(hid)) continue;
        var cur = head;
        while (true) {
            const id = json.str(cur.object, "channel_section_id") orelse break;
            if ((try visited.fetchPut(arena, id, {})) != null) break;
            try out.append(arena, cur);
            const next = json.str(cur.object, "next_channel_section_id") orelse break;
            cur = by_id.get(next) orelse break;
        }
    }
    for (sections) |sv| {
        if (sv != .object) continue;
        const id = json.str(sv.object, "channel_section_id") orelse continue;
        if (!visited.contains(id)) try out.append(arena, sv);
    }
    return out.items;
}

fn userOf(arena: std.mem.Allocator, o: std.json.ObjectMap) std.mem.Allocator.Error!?store.User {
    const id = json.str(o, "id") orelse return null;
    const profile = json.obj(o, "profile");
    const display = if (profile) |p| json.str(p, "display_name") orelse "" else "";
    const real = if (profile) |p| json.str(p, "real_name") orelse "" else "";
    const name = if (display.len > 0) display else if (real.len > 0) real else json.str(o, "name") orelse id;
    return .{ .id = try arena.dupe(u8, id), .name = try arena.dupe(u8, name), .is_bot = json.flag(o, "is_bot") or json.flag(o, "is_app_user") };
}

fn normalizeUrl(gpa: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]u8 {
    var t = std.mem.trim(u8, input, " \t\r\n/");
    if (std.mem.startsWith(u8, t, "https://")) t = t[8..] else if (std.mem.startsWith(u8, t, "http://")) t = t[7..];
    const host_end = std.mem.indexOfAny(u8, t, "/?#") orelse t.len;
    const host = t[0..host_end];
    if (host.len == 0) return gpa.dupe(u8, "");
    return std.fmt.allocPrint(gpa, "https://{s}", .{host});
}

test "richText flattens rich text blocks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\[{"type":"rich_text","elements":[{"type":"rich_text_section","elements":[
        \\ {"type":"text","text":"hi "},{"type":"user","user_id":"U1"},{"type":"text","text":" see "},
        \\ {"type":"link","url":"https://example.com"},{"type":"emoji","name":"tada"}]}]}]
    , .{});
    var out: std.ArrayList(u8) = .empty;
    try richText(a, &out, doc.array.items);
    try std.testing.expectEqualStrings("hi <@U1> see https://example.com:tada:", out.items);
}

test "sectionOrder follows the next links" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\[{"channel_section_id":"B","type":"channels","next_channel_section_id":"C"},
        \\ {"channel_section_id":"C","type":"direct_messages","next_channel_section_id":""},
        \\ {"channel_section_id":"A","type":"stars","next_channel_section_id":"B"},
        \\ {"channel_section_id":"X","type":"agents","next_channel_section_id":"nowhere"}]
    , .{});
    const order = try sectionOrder(a, doc.array.items);
    try std.testing.expectEqual(@as(usize, 4), order.len);
    const want = [_][]const u8{ "A", "B", "C", "X" };
    for (order, want) |sv, id| try std.testing.expectEqualStrings(id, json.str(sv.object, "channel_section_id").?);
}

test "normalizeUrl" {
    const gpa = std.testing.allocator;
    for ([_][2][]const u8{
        .{ "acme.slack.com", "https://acme.slack.com" },
        .{ " https://acme.slack.com/messages/C1 ", "https://acme.slack.com" },
        .{ "", "" },
    }) |case| {
        const out = try normalizeUrl(gpa, case[0]);
        defer gpa.free(out);
        try std.testing.expectEqualStrings(case[1], out);
    }
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (hay.len < needle.len) return false;
    for (0..hay.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn messageInfo(arena: std.mem.Allocator, o: std.json.ObjectMap, self_id: []const u8) std.mem.Allocator.Error!store.MessageInfo {
    var reactions: std.ArrayList(store.ReactionInfo) = .empty;
    for (json.arr(o, "reactions")) |rv| {
        if (rv != .object) continue;
        const name = json.str(rv.object, "name") orelse continue;
        var mine = false;
        for (json.arr(rv.object, "users")) |u| if (u == .string and std.mem.eql(u8, u.string, self_id)) {
            mine = true;
        };
        const count: u32 = if (rv.object.get("count")) |c| (if (c == .integer) std.math.cast(u32, c.integer) orelse 0 else 0) else 0;
        try reactions.append(arena, .{ .name = try arena.dupe(u8, name), .count = count, .mine = mine });
    }
    const replies: u32 = if (o.get("reply_count")) |c| (if (c == .integer) std.math.cast(u32, c.integer) orelse 0 else 0) else 0;
    return .{
        .ts = try arena.dupe(u8, json.str(o, "ts") orelse ""),
        .user = if (json.str(o, "user") orelse json.str(o, "bot_id")) |u| try arena.dupe(u8, u) else null,
        .text = try arena.dupe(u8, json.str(o, "text") orelse ""),
        .thread_ts = if (json.str(o, "thread_ts")) |t| try arena.dupe(u8, t) else null,
        .subtype = if (json.str(o, "subtype")) |t| try arena.dupe(u8, t) else null,
        .reactions = reactions.items,
        .reply_count = replies,
        .files = try fileInfos(arena, json.arr(o, "files")),
    };
}

/// Slack's `files` array as what we show: images carry a preview, the rest a link
fn fileInfos(arena: std.mem.Allocator, files: []const std.json.Value) std.mem.Allocator.Error![]const store.FileInfo {
    var out: std.ArrayList(store.FileInfo) = .empty;
    for (files) |fv| {
        if (fv != .object) continue;
        const f = fv.object;
        const id = json.str(f, "id") orelse continue;
        // Gone (deleted or not shared with us): nothing to show
        if (json.str(f, "mode")) |mode| if (std.mem.eql(u8, mode, "tombstone")) continue;
        var info: store.FileInfo = .{
            .id = try arena.dupe(u8, id),
            .name = try arena.dupe(u8, json.str(f, "name") orelse json.str(f, "title") orelse "file"),
            .mimetype = try arena.dupe(u8, json.str(f, "mimetype") orelse ""),
            .link = try arena.dupe(u8, json.str(f, "permalink") orelse ""),
        };
        // The preview a message shows: 360 wide, as Slack's own does
        if (json.str(f, "thumb_360")) |url| {
            const w = dimension(f, "thumb_360_w");
            const h = dimension(f, "thumb_360_h");
            if (w > 0 and h > 0) {
                info.thumb = try arena.dupe(u8, url);
                info.thumb_w = w;
                info.thumb_h = h;
            }
        }
        try out.append(arena, info);
    }
    return out.items;
}

fn dimension(o: std.json.ObjectMap, key: []const u8) u32 {
    const v = o.get(key) orelse return 0;
    return if (v == .integer) std.math.cast(u32, v.integer) orelse 0 else 0;
}

/// `mpdm-ada--grace--sam-1` to `ada, grace, sam`
fn prettyMpim(arena: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    var s = name;
    if (std.mem.startsWith(u8, s, "mpdm-")) s = s[5..];
    if (std.mem.lastIndexOfScalar(u8, s, '-')) |i| {
        if (std.mem.indexOfNone(u8, s[i + 1 ..], "0123456789") == null) s = s[0..i];
    }
    return std.mem.replaceOwned(u8, arena, s, "--", ", ");
}

test "prettyMpim" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("ada, grace, sam", try prettyMpim(a.allocator(), "mpdm-ada--grace--sam-1"));
}
