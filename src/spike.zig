//! Protocol spike CLI. Never prints tokens or cookies.
//! Usage: spike [channel-id [listen-seconds]]
const std = @import("std");
const slack = @import("slack");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &out.interface;
    defer w.flush() catch {};

    var creds = slack.desktop.extract(gpa, init.io, init.environ_map) catch |err| {
        try w.print("extract failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer creds.deinit();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const channel: ?[]const u8 = if (args.len > 1) args[1] else null;
    const listen_s: u32 = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else 0;
    var listened = false;
    try w.print("cookie: {f} ({d} bytes)\n", .{ slack.redact.Secret{ .bytes = creds.cookie }, creds.cookie.len });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    for (creds.workspaces) |ws| {
        try w.print("\n== {s} \"{s}\" {s}\n", .{ ws.team_id, ws.name, ws.url });
        var api = slack.http.Api.init(gpa, init.io, ws.url, ws.token, creds.cookie);
        defer api.deinit();
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        const res = api.call(arena, "auth.test", &.{}) catch |err| {
            try w.print("auth.test failed: {s} slack_error={s} http={d}\n", .{ @errorName(err), api.diag.slackError(), api.diag.status });
            continue;
        };
        inline for (.{ "ok", "team", "user", "user_id", "team_id", "url", "is_enterprise_install" }) |k| {
            if (res.object.get(k)) |v| switch (v) {
                .string => |s| try w.print("  {s}: {s}\n", .{ k, s }),
                .bool => |b| try w.print("  {s}: {}\n", .{ k, b }),
                else => {},
            };
        }

        if (init.environ_map.get("SPIKE_RAW")) |method| {
            // SPIKE_PARAMS="k=v&k=v" adds form fields; SPIKE_TALLY="array:key" counts a bool field
            var params: std.ArrayList(slack.http.Param) = .empty;
            if (init.environ_map.get("SPIKE_PARAMS")) |ps| {
                var parts = std.mem.splitScalar(u8, ps, '&');
                while (parts.next()) |part| {
                    const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
                    try params.append(arena, .{ part[0..eq], part[eq + 1 ..] });
                }
            }
            const raw = api.call(arena, method, params.items) catch |err| {
                try w.print("  {s} failed: {s} {s}\n", .{ method, @errorName(err), api.diag.slackError() });
                continue;
            };
            try describe(w, "  ", raw, 0);
            if (std.mem.eql(u8, method, "client.counts")) inline for (.{ "ims", "mpims" }) |key| if (raw.object.get(key)) |arr| for (arr.array.items) |item| {
                const o = item.object;
                const latest = if (o.get("latest")) |t| t.string else "";
                const read = if (o.get("last_read")) |t| t.string else "";
                const upd = if (o.get("updated")) |t| t.string else "";
                try w.print("  {s} id={s} latest={s} read={s} updated={s} unread={}\n", .{ key, if (o.get("id")) |t| t.string else "", latest, read, upd, if (o.get("has_unreads")) |b| b.bool else false });
            };
            if (std.mem.eql(u8, method, "users.channelSections.list"))if (raw.object.get("channel_sections")) |secs| for (secs.array.items) |sec| {
                const o = sec.object;
                const ids = if (o.get("channel_ids_page")) |p| (if (p.object.get("channel_ids")) |a| a.array.items.len else 0) else 0;
                try w.print("  section type={s} name={s} ids={d}\n", .{ if (o.get("type")) |t| t.string else "?", if (o.get("name")) |t| t.string else "?", ids });
            };
            // SPIKE_PICK="a.b.c" prints one string/bool/int field by dotted path (non-secret fields only)
            if (init.environ_map.get("SPIKE_PICK")) |path| {
                var cur = raw;
                var parts = std.mem.splitScalar(u8, path, '.');
                while (parts.next()) |k| {
                    if (cur != .object) break;
                    cur = cur.object.get(k) orelse break;
                }
                switch (cur) {
                    .string => |v| try w.print("  pick {s} = {s}\n", .{ path, v }),
                    .bool => |v| try w.print("  pick {s} = {}\n", .{ path, v }),
                    .integer => |v| try w.print("  pick {s} = {d}\n", .{ path, v }),
                    else => try w.print("  pick {s} = (not a scalar or missing)\n", .{path}),
                }
            }
            if (init.environ_map.get("SPIKE_TALLY")) |spec| if (std.mem.indexOfScalar(u8, spec, ':')) |colon| {
                var yes: u32 = 0;
                var no: u32 = 0;
                var missing: u32 = 0;
                if (raw.object.get(spec[0..colon])) |arr| if (arr == .array) for (arr.array.items) |item| {
                    if (item != .object) continue;
                    if (item.object.get(spec[colon + 1 ..])) |b| {
                        if (b == .bool and b.bool) yes += 1 else no += 1;
                    } else missing += 1;
                };
                try w.print("  tally {s}: true={d} false/other={d} missing={d}\n", .{ spec, yes, no, missing });
            };
            continue;
        }

        // Conversations the user is in
        const convs = api.call(arena, "users.conversations", &.{
            .{ "types", "public_channel,private_channel,mpim,im" },
            .{ "exclude_archived", "true" },
            .{ "limit", "200" },
        }) catch |err| {
            try w.print("users.conversations failed: {s} {s}\n", .{ @errorName(err), api.diag.slackError() });
            continue;
        };
        var counts: [4]u32 = @splat(0);
        if (convs.object.get("channels")) |chs| for (chs.array.items) |c| {
            const o = c.object;
            const idx: usize = if (flag(o, "is_im")) 0 else if (flag(o, "is_mpim")) 1 else if (flag(o, "is_private")) 2 else 3;
            counts[idx] += 1;
        };
        try w.print("  conversations: im={d} mpim={d} private={d} public={d} next_cursor={s}\n", .{ counts[0], counts[1], counts[2], counts[3], nextCursor(convs) });

        if (channel) |ch| {
            const hist = api.call(arena, "conversations.history", &.{ .{ "channel", ch }, .{ "limit", "5" } }) catch |err| {
                try w.print("  history({s}) failed: {s} {s}\n", .{ ch, @errorName(err), api.diag.slackError() });
                continue;
            };
            try dumpJson(gpa, init.io, "captures/history.json", hist);
            const msgs = hist.object.get("messages").?.array.items;
            try w.print("  history({s}): {d} messages, has_more={}\n", .{ ch, msgs.len, flag(hist.object, "has_more") });
            for (msgs) |m| {
                const o = m.object;
                try w.print("    ts={s} user={s} type={s} subtype={s} text={s}\n", .{ str(o, "ts"), str(o, "user"), str(o, "type"), str(o, "subtype"), str(o, "text") });
            }
            if (listen_s > 0 and !listened) {
                listened = true;
                try listen(gpa, init.io, w, ws, creds.cookie, str(res.object, "user_id"), listen_s);
            }
        }
    }
}

fn str(o: std.json.ObjectMap, k: []const u8) []const u8 {
    const v = o.get(k) orelse return "-";
    return if (v == .string) v.string else "-";
}

fn flag(o: std.json.ObjectMap, k: []const u8) bool {
    const v = o.get(k) orelse return false;
    return v == .bool and v.bool;
}

fn nextCursor(v: std.json.Value) []const u8 {
    const meta = v.object.get("response_metadata") orelse return "-";
    if (meta != .object) return "-";
    const c = str(meta.object, "next_cursor");
    return if (c.len == 0) "-" else c;
}

/// Connects the socket and prints event shapes (types and ids, never message
/// text) so the protocol can be verified without dumping chat content.
fn listen(gpa: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, ws: slack.desktop.Workspace, cookie: []const u8, self_id: []const u8, seconds: u32) !void {
    try w.print("  -- socket: connecting for {d}s\n", .{seconds});
    try w.flush();
    var sock = slack.realtime.Socket.connect(gpa, io, ws.team_id, ws.token, cookie) catch |err| {
        try w.print("  socket connect failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer sock.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |k| gpa.free(k.*);
        seen.deinit(gpa);
    }

    const start = std.Io.Timestamp.now(io, .awake);
    var last_ping = start;
    var presence_sent = false;
    while (true) {
        const now = std.Io.Timestamp.now(io, .awake);
        const elapsed_s: u64 = @intCast(@divTrunc(start.durationTo(now).toNanoseconds(), std.time.ns_per_s));
        if (elapsed_s >= seconds) break;
        if (@divTrunc(last_ping.durationTo(now).toNanoseconds(), std.time.ns_per_s) >= 20) {
            try sock.ping();
            last_ping = now;
        }
        const frame = (sock.next(1000) catch |err| {
            try w.print("  socket ended: {s}\n", .{@errorName(err)});
            break;
        }) orelse continue;
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        const ev = std.json.parseFromSliceLeaky(std.json.Value, arena, frame, .{}) catch {
            try w.print("  [unparseable frame, {d} bytes]\n", .{frame.len});
            continue;
        };
        if (ev != .object) continue;
        const kind = str(ev.object, "type");
        const slot = try seen.getOrPut(gpa, kind);
        if (!slot.found_existing) {
            slot.key_ptr.* = try gpa.dupe(u8, kind);
            slot.value_ptr.* = 0;
        }
        slot.value_ptr.* += 1;
        const n = slot.value_ptr.*;
        if (n <= 3) {
            try w.print("  [{d}s] type={s} subtype={s} channel={s} user={s} ts={s} keys:", .{ elapsed_s, kind, str(ev.object, "subtype"), str(ev.object, "channel"), str(ev.object, "user"), str(ev.object, "ts") });
            var it = ev.object.iterator();
            while (it.next()) |kv| try w.print(" {s}", .{kv.key_ptr.*});
            try w.writeAll("\n");
        }
        if (!presence_sent and std.mem.eql(u8, kind, "hello")) {
            presence_sent = true;
            var buf: [128]u8 = undefined;
            try sock.send(try std.fmt.bufPrint(&buf, "{{\"type\":\"presence_sub\",\"ids\":[\"{s}\"]}}", .{self_id}));
            try w.writeAll("  -> sent presence_sub for self\n");
        }
        try w.flush();
    }
    var it = seen.iterator();
    try w.writeAll("  event counts:");
    while (it.next()) |kv| try w.print(" {s}={d}", .{ kv.key_ptr.*, kv.value_ptr.* });
    try w.writeAll("\n");
}

/// Raw responses for building fixtures. `captures/` is gitignored: scrub
/// before anything goes into the repo.
fn dumpJson(gpa: std.mem.Allocator, io: std.Io, path: []const u8, value: std.json.Value) !void {
    const dir = std.Io.Dir.cwd();
    try dir.createDirPath(io, "captures");
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &aw.writer);
    try dir.writeFile(io, .{ .sub_path = path, .data = aw.written() });
}

/// Prints the shape of a JSON value: keys, array sizes, and the keys of the
/// first element. Never prints string content.
fn describe(w: *std.Io.Writer, indent: []const u8, v: std.json.Value, depth: u8) !void {
    switch (v) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |kv| {
                switch (kv.value_ptr.*) {
                    .array => |a| {
                        try w.print("{s}{s}: array[{d}]\n", .{ indent, kv.key_ptr.*, a.items.len });
                        if (a.items.len > 0 and depth < 2) {
                            var buf: [64]u8 = undefined;
                            const inner = try std.fmt.bufPrint(&buf, "{s}  ", .{indent});
                            try describe(w, inner, a.items[0], depth + 1);
                        }
                    },
                    .object => {
                        try w.print("{s}{s}: object\n", .{ indent, kv.key_ptr.* });
                        if (depth < 2) {
                            var buf: [64]u8 = undefined;
                            const inner = try std.fmt.bufPrint(&buf, "{s}  ", .{indent});
                            try describe(w, inner, kv.value_ptr.*, depth + 1);
                        }
                    },
                    .string => try w.print("{s}{s}: string\n", .{ indent, kv.key_ptr.* }),
                    .bool => |b| try w.print("{s}{s}: {}\n", .{ indent, kv.key_ptr.*, b }),
                    .integer => |n| try w.print("{s}{s}: {d}\n", .{ indent, kv.key_ptr.*, n }),
                    else => try w.print("{s}{s}: other\n", .{ indent, kv.key_ptr.* }),
                }
            }
        },
        else => {},
    }
}
