//! Slack Web API over HTTPS, the way the web client calls it: form-encoded
//! POST to `<workspace-url>/api/<method>` with the `xoxc-` token in the body
//! and the `d` cookie in the Cookie header.
const std = @import("std");

pub const Error = error{
    /// Slack answered `ok: false`; see `Api.diag`
    SlackError,
    RateLimited,
    HttpStatus,
    BadResponse,
    Network,
    /// `Api.abort` was set while waiting out a rate limit
    Aborted,
} || std.mem.Allocator.Error;

pub const Param = struct { []const u8, []const u8 };

pub const Diag = struct {
    slack_error: [64]u8 = undefined,
    slack_error_len: u8 = 0,
    retry_after_s: u32 = 0,
    status: u16 = 0,

    pub fn slackError(d: *const Diag) []const u8 {
        return d.slack_error[0..d.slack_error_len];
    }

    /// Errors that mean the stored session is dead: re-extract, then prompt
    pub fn isAuthError(d: *const Diag) bool {
        inline for (.{ "invalid_auth", "token_revoked", "token_expired", "not_authed", "account_inactive", "no_permission" }) |e| {
            if (std.mem.eql(u8, d.slackError(), e)) return true;
        }
        return false;
    }
};

pub const Api = struct {
    io: std.Io,
    client: std.http.Client,
    /// `https://team.slack.com`, no trailing slash
    base_url: []const u8,
    token: []const u8,
    cookie: []const u8,
    user_agent: []const u8 = "lax-slack-clone/0.0.1",
    diag: Diag = .{},
    /// Set from another thread to cut a rate-limit wait short
    abort: ?*const std.atomic.Value(bool) = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, base_url: []const u8, token: []const u8, cookie: []const u8) Api {
        return .{
            .io = io,
            .client = .{ .allocator = gpa, .io = io },
            .base_url = std.mem.trimEnd(u8, base_url, "/"),
            .token = token,
            .cookie = cookie,
        };
    }

    pub fn deinit(api: *Api) void {
        api.client.deinit();
    }

    /// Calls a method and returns the parsed JSON (allocated in `arena`).
    /// 429s are retried after `Retry-After` (capped), up to 3 attempts.
    pub fn call(api: *Api, arena: std.mem.Allocator, method: []const u8, params: []const Param) Error!std.json.Value {
        const url = try std.fmt.allocPrint(arena, "{s}/api/{s}", .{ api.base_url, method });
        var body: std.ArrayList(u8) = .empty;
        try appendField(arena, &body, "token", api.token);
        for (params) |p| try appendField(arena, &body, p[0], p[1]);
        const cookie_header = try std.fmt.allocPrint(arena, "d={s}", .{api.cookie});

        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            api.diag = .{};
            const text = api.post(arena, url, body.items, cookie_header) catch |err| switch (err) {
                error.RateLimited => {
                    if (attempt >= 2) return error.RateLimited;
                    const wait = std.math.clamp(api.diag.retry_after_s, 1, 60);
                    var left: u32 = wait * 10;
                    while (left > 0) : (left -= 1) {
                        if (api.abort) |a| if (a.load(.acquire)) return error.Aborted;
                        api.io.sleep(.fromMilliseconds(100), .awake) catch return error.Network;
                    }
                    continue;
                },
                else => |e| return e,
            };
            const root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return error.BadResponse;
            if (root != .object) return error.BadResponse;
            const ok = root.object.get("ok") orelse return error.BadResponse;
            if (ok == .bool and ok.bool) return root;
            if (root.object.get("error")) |e| if (e == .string) {
                const n = @min(e.string.len, api.diag.slack_error.len);
                @memcpy(api.diag.slack_error[0..n], e.string[0..n]);
                api.diag.slack_error_len = @intCast(n);
            };
            return error.SlackError;
        }
    }

    /// What `Client.request` does before its first TLS connection: load the
    /// system certificates. Needed here because we connect ourselves.
    fn ensureCertificates(api: *Api) Error!void {
        const client = &api.client;
        {
            client.ca_bundle_lock.lockSharedUncancelable(api.io);
            defer client.ca_bundle_lock.unlockShared(api.io);
            if (client.now != null) return;
        }
        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(client.allocator);
        const now = std.Io.Clock.real.now(api.io);
        bundle.rescan(client.allocator, api.io, now) catch return error.Network;
        client.ca_bundle_lock.lockUncancelable(api.io);
        defer client.ca_bundle_lock.unlock(api.io);
        client.now = now;
        std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
    }

    /// A fresh connection with a connect timeout. std's client can only
    /// time out connecting, and a pooled connection to a network that went
    /// away would otherwise hang for minutes, so nothing is kept alive.
    fn connect(api: *Api, uri: std.Uri) Error!*std.http.Client.Connection {
        try api.ensureCertificates();
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = std.Io.net.HostName.fromUri(uri, &host_buf) catch return error.BadResponse;
        return api.client.connectTcpOptions(.{
            .host = host,
            .port = 443,
            .protocol = .tls,
            .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
        }) catch error.Network;
    }

    /// A plain GET of a public file (a workspace icon): no token, no cookie
    pub fn download(api: *Api, arena: std.mem.Allocator, url: []const u8, limit: usize) Error![]u8 {
        return api.get(arena, url, limit, false);
    }

    /// A GET of a file Slack keeps private (an upload's preview): with the
    /// session's token and cookie, which only go to Slack's own hosts.
    pub fn downloadPrivate(api: *Api, arena: std.mem.Allocator, url: []const u8, limit: usize) Error![]u8 {
        return api.get(arena, url, limit, true);
    }

    fn get(api: *Api, arena: std.mem.Allocator, url: []const u8, limit: usize, private: bool) Error![]u8 {
        const uri = std.Uri.parse(url) catch return error.BadResponse;
        if (!std.mem.eql(u8, uri.scheme, "https")) return error.BadResponse;
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = std.Io.net.HostName.fromUri(uri, &host_buf) catch return error.BadResponse;
        if (private and !isSlackHost(host.bytes)) return error.BadResponse;
        const connection = try api.connect(uri);
        const cookie_header = if (private) try std.fmt.allocPrint(arena, "d={s}", .{api.cookie}) else "";
        const auth_header = if (private) try std.fmt.allocPrint(arena, "Bearer {s}", .{api.token}) else "";
        var req = api.client.request(.GET, uri, .{
            .connection = connection,
            .headers = .{ .user_agent = .{ .override = api.user_agent }, .accept_encoding = .omit, .authorization = if (private) .{ .override = auth_header } else .default },
            .extra_headers = if (private) &.{.{ .name = "Cookie", .value = cookie_header }} else &.{},
            .redirect_behavior = if (private) .not_allowed else @fromBackingInt(3),
            .keep_alive = false,
        }) catch return error.Network;
        defer req.deinit();
        req.sendBodiless() catch return error.Network;
        var redirect_buf: [1024]u8 = undefined;
        var resp = req.receiveHead(&redirect_buf) catch return error.Network;
        if (resp.head.status != .ok) return error.HttpStatus;
        var transfer: [4096]u8 = undefined;
        const reader = resp.reader(&transfer);
        return reader.allocRemaining(arena, .limited(limit)) catch error.Network;
    }

    /// POSTs `body` (a multipart form already built: `multipartBody`) to a
    /// signed upload URL from `files.getUploadURL`. No token or cookie: the
    /// URL itself is the credential. Not retried.
    pub fn upload(api: *Api, arena: std.mem.Allocator, url: []const u8, body: []u8) Error!void {
        const uri = std.Uri.parse(url) catch return error.BadResponse;
        if (!std.mem.eql(u8, uri.scheme, "https")) return error.BadResponse;
        const connection = try api.connect(uri);
        var req = api.client.request(.POST, uri, .{
            .connection = connection,
            .headers = .{
                .content_type = .{ .override = multipart_type },
                .user_agent = .{ .override = api.user_agent },
                .accept_encoding = .omit,
            },
            .keep_alive = false,
        }) catch return error.Network;
        defer req.deinit();
        req.sendBodyComplete(body) catch return error.Network;
        var redirect_buf: [1024]u8 = undefined;
        var resp = req.receiveHead(&redirect_buf) catch return error.Network;
        api.diag.status = @intFromEnum(resp.head.status);
        if (resp.head.status != .ok) return error.HttpStatus;
        // Slack answers "OK - <id>"; nothing in it is needed
        var transfer: [1024]u8 = undefined;
        _ = resp.reader(&transfer).allocRemaining(arena, .limited(1 << 16)) catch {};
    }

    fn post(api: *Api, arena: std.mem.Allocator, url: []const u8, body: []const u8, cookie_header: []const u8) Error![]u8 {
        const uri = std.Uri.parse(url) catch return error.BadResponse;
        const connection = try api.connect(uri);
        var req = api.client.request(.POST, uri, .{
            .connection = connection,
            .headers = .{
                .content_type = .{ .override = "application/x-www-form-urlencoded; charset=utf-8" },
                .user_agent = .{ .override = api.user_agent },
                .accept_encoding = .omit,
            },
            .extra_headers = &.{.{ .name = "Cookie", .value = cookie_header }},
            .keep_alive = false,
        }) catch return error.Network;
        defer req.deinit();

        const mutable = try arena.dupe(u8, body);
        req.sendBodyComplete(mutable) catch return error.Network;
        var redirect_buf: [1024]u8 = undefined;
        var resp = req.receiveHead(&redirect_buf) catch return error.Network;

        api.diag.status = @intFromEnum(resp.head.status);
        if (resp.head.status == .too_many_requests) {
            var it = resp.head.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) api.diag.retry_after_s = std.fmt.parseInt(u32, h.value, 10) catch 5;
            }
            if (api.diag.retry_after_s == 0) api.diag.retry_after_s = 5;
            return error.RateLimited;
        }
        if (resp.head.status != .ok) return error.HttpStatus;

        var transfer: [4096]u8 = undefined;
        const reader = resp.reader(&transfer);
        return reader.allocRemaining(arena, .limited(32 << 20)) catch error.Network;
    }
};

/// `files.slack.com` and the like: where the session's secrets may be sent
fn isSlackHost(host: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(host, ".slack.com") or std.ascii.endsWithIgnoreCase(host, ".slack-edge.com");
}

const boundary = "----lax7d1f0c9a5b3e";
const multipart_type = "multipart/form-data; boundary=" ++ boundary;

/// The multipart head and tail around one file's bytes: the body is
/// `head ++ bytes ++ tail`, so the caller can read a file straight into the
/// middle of one buffer.
pub fn multipartParts(arena: std.mem.Allocator, filename: []const u8) std.mem.Allocator.Error!struct { head: []u8, tail: []const u8 } {
    var name: std.ArrayList(u8) = .empty;
    // Quotes and line breaks would end the header early
    for (filename) |c| try name.append(arena, if (c == '"' or c == '\r' or c == '\n') '_' else c);
    const head = try std.fmt.allocPrint(arena, "--{s}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n", .{ boundary, name.items });
    return .{ .head = head, .tail = "\r\n--" ++ boundary ++ "--\r\n" };
}

fn appendField(gpa: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) std.mem.Allocator.Error!void {
    if (out.items.len != 0) try out.append(gpa, '&');
    try percentEncode(gpa, out, key);
    try out.append(gpa, '=');
    try percentEncode(gpa, out, value);
}

fn percentEncode(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) std.mem.Allocator.Error!void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(gpa, c);
        } else {
            try out.print(gpa, "%{X:0>2}", .{c});
        }
    }
}

test "form encoding" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try appendField(gpa, &out, "token", "xoxc-1");
    try appendField(gpa, &out, "text", "a b&c=é");
    try std.testing.expectEqualStrings("token=xoxc-1&text=a%20b%26c%3D%C3%A9", out.items);
}

test "multipart parts wrap a file and sanitize its name" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const p = try multipartParts(a.allocator(), "a\"b\r\nc.txt");
    try std.testing.expect(std.mem.indexOf(u8, p.head, "filename=\"a_b__c.txt\"\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, p.head, "\r\n\r\n"));
    try std.testing.expectEqualStrings("\r\n------lax7d1f0c9a5b3e--\r\n", p.tail);
}

test "only Slack's hosts get the session" {
    try std.testing.expect(isSlackHost("files.slack.com"));
    try std.testing.expect(!isSlackHost("evilslack.com"));
    try std.testing.expect(!isSlackHost("slack.com.evil.net"));
}
