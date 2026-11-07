//! Auto-extraction of the session from the local Slack desktop app.
//! Reads (copies of) Local Storage LevelDB for the `xoxc-` tokens and the
//! Cookies sqlite DB for the encrypted `d` cookie. See README for the why.
const std = @import("std");
const builtin = @import("builtin");
const leveldb = @import("leveldb.zig");
const sqlite = @import("sqlite.zig");
const cookie = @import("cookie.zig");
pub const keyring = @import("keyring.zig");

pub const Error = error{
    DesktopNotFound,
    NotSignedIn,
    /// Slack holds the file and it could not be read
    Locked,
    KeyringUnavailable,
    KeyringNotFound,
    DecryptFailed,
    FormatChanged,
    Unsupported,
} || std.mem.Allocator.Error;

pub const Workspace = struct {
    team_id: []const u8,
    name: []const u8,
    url: []const u8,
    /// `xoxc-...` token. Never log: wrap in `redact.Secret`.
    token: []const u8,
};

pub const Credentials = struct {
    arena: std.heap.ArenaAllocator,
    /// The `d` cookie value (`xoxd-...`, URL-encoded as stored). Never log.
    cookie: []const u8,
    workspaces: []const Workspace,

    pub fn deinit(c: *Credentials) void {
        std.crypto.secureZero(u8, @constCast(c.cookie));
        c.arena.deinit();
    }

    /// Serialized for the keyring. The result is a secret: wipe it after use.
    pub fn toJson(c: *const Credentials, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        std.json.Stringify.value(.{ .cookie = c.cookie, .workspaces = c.workspaces }, .{}, &aw.writer) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    pub fn fromJson(gpa: std.mem.Allocator, text: []const u8) Error!Credentials {
        var creds: Credentials = .{ .arena = .init(gpa), .cookie = &.{}, .workspaces = &.{} };
        errdefer creds.arena.deinit();
        const Wire = struct { cookie: []const u8, workspaces: []const Workspace };
        const wire = std.json.parseFromSliceLeaky(Wire, creds.arena.allocator(), text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.FormatChanged;
        if (wire.workspaces.len == 0 or !std.mem.startsWith(u8, wire.cookie, "xoxd-")) return error.FormatChanged;
        creds.cookie = wire.cookie;
        creds.workspaces = wire.workspaces;
        return creds;
    }

    /// Credentials the user typed in: one workspace
    pub fn fromManual(gpa: std.mem.Allocator, ws: Workspace, cookie_value: []const u8) std.mem.Allocator.Error!Credentials {
        var creds: Credentials = .{ .arena = .init(gpa), .cookie = &.{}, .workspaces = &.{} };
        errdefer creds.arena.deinit();
        const a = creds.arena.allocator();
        const list = try a.alloc(Workspace, 1);
        list[0] = .{
            .team_id = try a.dupe(u8, ws.team_id),
            .name = try a.dupe(u8, ws.name),
            .url = try a.dupe(u8, ws.url),
            .token = try a.dupe(u8, ws.token),
        };
        creds.workspaces = list;
        creds.cookie = try a.dupe(u8, cookie_value);
        return creds;
    }
};

/// Candidate config directories, most likely first. Caller owns the list and strings.
pub fn candidateDirs(arena: std.mem.Allocator, env: *const std.process.Environ.Map) std.mem.Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    const home = env.get("HOME") orelse "";
    switch (builtin.os.tag) {
        .windows => {
            if (env.get("APPDATA")) |p| try list.append(arena, try std.fs.path.join(arena, &.{ p, "Slack" }));
            if (env.get("LOCALAPPDATA")) |p| try list.append(arena, try std.fs.path.join(arena, &.{ p, "Packages", "com.tinyspeck.slackdesktop_8yrtsj140pw4g", "LocalCache", "Roaming", "Slack" }));
        },
        .macos => {
            try list.append(arena, try std.fs.path.join(arena, &.{ home, "Library", "Application Support", "Slack" }));
            try list.append(arena, try std.fs.path.join(arena, &.{ home, "Library", "Containers", "com.tinyspeck.slackmacgap", "Data", "Library", "Application Support", "Slack" }));
        },
        else => {
            if (env.get("XDG_CONFIG_HOME")) |p| try list.append(arena, try std.fs.path.join(arena, &.{ p, "Slack" }));
            try list.append(arena, try std.fs.path.join(arena, &.{ home, ".config", "Slack" }));
            try list.append(arena, try std.fs.path.join(arena, &.{ home, ".var", "app", "com.slack.Slack", "config", "Slack" }));
            try list.append(arena, try std.fs.path.join(arena, &.{ home, "snap", "slack", "current", ".config", "Slack" }));
        },
    }
    return list.items;
}

fn findConfigDir(io: std.Io, dirs: []const []const u8) ?[]const u8 {
    for (dirs) |d| {
        var dir = std.Io.Dir.openDirAbsolute(io, d, .{}) catch continue;
        dir.close(io);
        return d;
    }
    return null;
}

pub fn extract(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) Error!Credentials {
    var creds: Credentials = .{ .arena = .init(gpa), .cookie = &.{}, .workspaces = &.{} };
    errdefer creds.arena.deinit();
    const arena = creds.arena.allocator();

    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const config_dir = findConfigDir(io, try candidateDirs(scratch, env)) orelse return error.DesktopNotFound;

    // Work on copies: the live profile is locked while Slack runs
    var snap = try Snapshot.create(scratch, io, env, config_dir);
    defer snap.cleanup(io);

    creds.workspaces = try readWorkspaces(gpa, arena, io, snap);
    creds.cookie = try readCookie(gpa, arena, io, snap);
    return creds;
}

const Snapshot = struct {
    dir: std.Io.Dir,
    path: []const u8,

    fn create(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, config_dir: []const u8) Error!Snapshot {
        const base = env.get("XDG_RUNTIME_DIR") orelse "/tmp";
        var rnd: [6]u8 = undefined;
        io.random(&rnd);
        const path = try std.fmt.allocPrint(arena, "{s}/lax-slack-{x}", .{ base, rnd });
        const perms: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
        std.Io.Dir.createDirAbsolute(io, path, perms) catch return error.Locked;
        var snap: Snapshot = .{ .dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return error.Locked, .path = path };
        errdefer snap.cleanup(io);

        var src = std.Io.Dir.openDirAbsolute(io, config_dir, .{}) catch return error.DesktopNotFound;
        defer src.close(io);
        snap.dir.createDirPath(io, "leveldb") catch return error.Locked;
        var ldb = src.openDir(io, "Local Storage/leveldb", .{ .iterate = true }) catch return error.NotSignedIn;
        defer ldb.close(io);
        var it = ldb.iterate();
        while (it.next(io) catch return error.Locked) |entry| {
            if (entry.kind != .file or std.mem.eql(u8, entry.name, "LOCK")) continue;
            const dest = try std.fs.path.join(arena, &.{ "leveldb", entry.name });
            ldb.copyFile(entry.name, snap.dir, dest, io, .{}) catch return error.Locked;
        }
        // Newer Chromium keeps cookies under Network/
        for ([_][]const u8{ "Network/Cookies", "Cookies" }) |name| {
            src.copyFile(name, snap.dir, "Cookies", io, .{}) catch continue;
            break;
        }
        return snap;
    }

    fn cleanup(s: *Snapshot, io: std.Io) void {
        s.dir.close(io);
        std.Io.Dir.cwd().deleteTree(io, s.path) catch {};
    }
};

const config_suffix = "localConfig_v2";

fn readWorkspaces(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, snap: Snapshot) Error![]const Workspace {
    var scanner: leveldb.Scanner = .{ .gpa = gpa, .suffix = config_suffix };
    defer scanner.deinit();

    var dir = snap.dir.openDir(io, "leveldb", .{ .iterate = true }) catch return error.NotSignedIn;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return error.Locked) |entry| {
        if (entry.kind != .file) continue;
        const is_table = std.mem.endsWith(u8, entry.name, ".ldb") or std.mem.endsWith(u8, entry.name, ".sst");
        const is_log = std.mem.endsWith(u8, entry.name, ".log");
        if (!is_table and !is_log) continue;
        const bytes = dir.readFileAlloc(io, entry.name, gpa, .limited(256 << 20)) catch continue;
        defer gpa.free(bytes);
        // A corrupt or torn file must not hide good data in the others
        (if (is_table) leveldb.scanTable(&scanner, bytes) else leveldb.scanLog(&scanner, bytes)) catch continue;
    }

    const entry = scanner.take() orelse return error.NotSignedIn;
    defer {
        gpa.free(entry.key);
        gpa.free(entry.value);
    }
    const json = try decodeLocalStorageValue(gpa, entry.value);
    defer gpa.free(json);
    return parseLocalConfig(arena, json);
}

/// Chromium Local Storage values start with 0 (UTF-16LE) or 1 (Latin-1)
fn decodeLocalStorageValue(gpa: std.mem.Allocator, raw: []const u8) Error![]u8 {
    if (raw.len == 0) return error.FormatChanged;
    return switch (raw[0]) {
        1 => latin1ToUtf8(gpa, raw[1..]),
        0 => utf16leToUtf8(gpa, raw[1..]),
        else => error.FormatChanged,
    };
}

fn latin1ToUtf8(gpa: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (bytes) |b| {
        if (b < 0x80) {
            try out.append(gpa, b);
        } else {
            try out.append(gpa, 0xc0 | (b >> 6));
            try out.append(gpa, 0x80 | (b & 0x3f));
        }
    }
    return out.toOwnedSlice(gpa);
}

fn utf16leToUtf8(gpa: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    if (bytes.len % 2 != 0) return error.FormatChanged;
    const units = try gpa.alloc(u16, bytes.len / 2);
    defer gpa.free(units);
    for (units, 0..) |*u, i| u.* = std.mem.readInt(u16, bytes[2 * i ..][0..2], .little);
    return std.unicode.utf16LeToUtf8Alloc(gpa, units) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.FormatChanged,
    };
}

/// `localConfig_v2` is `{"teams": {"T123": {"name", "url", "token", ...}}}`
pub fn parseLocalConfig(arena: std.mem.Allocator, json: []const u8) Error![]const Workspace {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return error.FormatChanged;
    if (root != .object) return error.FormatChanged;
    const teams = root.object.get("teams") orelse return error.FormatChanged;
    if (teams != .object) return error.FormatChanged;
    var list: std.ArrayList(Workspace) = .empty;
    var it = teams.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .object) continue;
        const t = kv.value_ptr.object;
        const token = stringField(t, "token") orelse continue;
        if (!std.mem.startsWith(u8, token, "xoxc-")) continue;
        try list.append(arena, .{
            .team_id = kv.key_ptr.*,
            .name = stringField(t, "name") orelse "",
            .url = stringField(t, "url") orelse "",
            .token = token,
        });
    }
    if (list.items.len == 0) return error.NotSignedIn;
    return list.items;
}

fn stringField(o: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = o.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

const CookieQuery = struct {
    host_i: usize,
    name_i: usize,
    enc_i: usize,
    val_i: usize,
    password: []const u8,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    result: ?[]const u8 = null,
    saw_encrypted: bool = false,
    decrypt_failed: bool = false,
};

fn cookieRow(ctx: *anyopaque, _: i64, values: []const sqlite.Value) sqlite.Error!void {
    const q: *CookieQuery = @ptrCast(@alignCast(ctx));
    const need = @max(@max(q.host_i, q.name_i), @max(q.enc_i, q.val_i));
    if (values.len <= need) return;
    const host = if (values[q.host_i] == .text) values[q.host_i].text else return;
    const name = if (values[q.name_i] == .text) values[q.name_i].text else return;
    if (!std.mem.eql(u8, name, "d")) return;
    if (!std.mem.endsWith(u8, host, "slack.com")) return;
    switch (values[q.enc_i]) {
        .blob => |enc| if (enc.len > 0) {
            q.saw_encrypted = true;
            const plain = cookie.decrypt(q.gpa, enc, host, q.password) catch {
                q.decrypt_failed = true;
                return;
            };
            defer q.gpa.free(plain);
            if (std.mem.startsWith(u8, plain, "xoxd-")) q.result = try q.arena.dupe(u8, plain);
            return;
        },
        else => {},
    }
    // Unencrypted fallback
    if (values[q.val_i] == .text and std.mem.startsWith(u8, values[q.val_i].text, "xoxd-")) {
        q.result = try q.arena.dupe(u8, values[q.val_i].text);
    }
}

const SchemaQuery = struct {
    root: ?u32 = null,
    sql: []const u8 = "",
};

fn schemaRow(ctx: *anyopaque, _: i64, values: []const sqlite.Value) sqlite.Error!void {
    const q: *SchemaQuery = @ptrCast(@alignCast(ctx));
    if (values.len < 5) return;
    if (values[0] != .text or !std.mem.eql(u8, values[0].text, "table")) return;
    if (values[1] != .text or !std.mem.eql(u8, values[1].text, "cookies")) return;
    if (values[3] != .int or values[4] != .text) return;
    q.root = @intCast(values[3].int);
    q.sql = values[4].text;
}

fn readCookie(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, snap: Snapshot) Error![]const u8 {
    const bytes = snap.dir.readFileAlloc(io, "Cookies", gpa, .limited(256 << 20)) catch return error.Locked;
    defer gpa.free(bytes);
    const db = sqlite.Db.init(bytes) catch return error.FormatChanged;

    var schema: SchemaQuery = .{};
    db.scan(gpa, 1, &schema, schemaRow) catch return error.FormatChanged;
    const root = schema.root orelse return error.FormatChanged;
    // schema.sql points into `bytes`, still alive here

    const password = keyring.slackSafeStoragePassword(gpa, io) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotFound => return error.KeyringNotFound,
        error.Unsupported => return error.Unsupported,
        error.Unavailable => return error.KeyringUnavailable,
    };
    defer {
        std.crypto.secureZero(u8, password);
        gpa.free(password);
    }

    var q: CookieQuery = .{
        .host_i = sqlite.columnIndex(schema.sql, "host_key") orelse return error.FormatChanged,
        .name_i = sqlite.columnIndex(schema.sql, "name") orelse return error.FormatChanged,
        .enc_i = sqlite.columnIndex(schema.sql, "encrypted_value") orelse return error.FormatChanged,
        .val_i = sqlite.columnIndex(schema.sql, "value") orelse return error.FormatChanged,
        .password = password,
        .gpa = gpa,
        .arena = arena,
    };
    db.scan(gpa, root, &q, cookieRow) catch return error.FormatChanged;
    if (q.result) |r| return r;
    return if (q.saw_encrypted or q.decrypt_failed) error.DecryptFailed else error.NotSignedIn;
}

test "parseLocalConfig extracts xoxc teams" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ws = try parseLocalConfig(arena_state.allocator(),
        \\{"teams":{"T1":{"name":"Acme","url":"https://acme.slack.com/","token":"xoxc-1-2-3-abc"},"T2":{"name":"NoTok"}}}
    );
    try std.testing.expectEqual(@as(usize, 1), ws.len);
    try std.testing.expectEqualStrings("T1", ws[0].team_id);
    try std.testing.expectEqualStrings("Acme", ws[0].name);
}

test "parseLocalConfig reports format changes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.FormatChanged, parseLocalConfig(arena_state.allocator(), "[]"));
}

test "credentials survive a JSON round trip" {
    const gpa = std.testing.allocator;
    var c = try Credentials.fromManual(gpa, .{ .team_id = "T1", .name = "Acme", .url = "https://acme.slack.com", .token = "xoxc-1-2-3-a" }, "xoxd-abc%2B");
    defer c.deinit();
    const json = try c.toJson(gpa);
    var back = try Credentials.fromJson(gpa, json);
    defer back.deinit();
    // The source is wiped and freed right after parsing in real use
    std.crypto.secureZero(u8, json);
    gpa.free(json);
    try std.testing.expectEqualStrings("xoxd-abc%2B", back.cookie);
    try std.testing.expectEqualStrings("T1", back.workspaces[0].team_id);
    try std.testing.expectError(error.FormatChanged, Credentials.fromJson(gpa, "{\"cookie\":\"nope\",\"workspaces\":[]}"));
}
