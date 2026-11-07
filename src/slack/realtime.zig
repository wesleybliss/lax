//! Real-time socket. Verified shape (wee-slack and slk, MIT, confirmed live):
//! `wss://wss-primary.slack.com/?token=<xoxc>&gateway_server=<TEAM>-1&slack_client=desktop&batch_presence_aware=1`
//! with the `d` cookie, answered by a `hello` event. No `rtm.connect` needed for
//! session (`xoxc`) tokens.
const std = @import("std");
const websocket = @import("websocket");

pub const Error = error{ Connect, Closed, Timeout } || std.mem.Allocator.Error;

pub const Socket = struct {
    gpa: std.mem.Allocator,
    client: websocket.Client,
    next_id: u32 = 1,
    /// Frame currently borrowed from the client; released on the next `next`
    pending: ?websocket.proto.Message = null,

    pub fn connect(gpa: std.mem.Allocator, io: std.Io, team_id: []const u8, token: []const u8, cookie: []const u8) Error!Socket {
        var client = websocket.Client.init(io, gpa, .{
            .host = "wss-primary.slack.com",
            .port = 443,
            .tls = true,
            // The handshake (token in the path, cookie header) is built in the read buffer
            .buffer_size = 8192,
            .max_size = 4 * 1024 * 1024,
        }) catch return error.Connect;
        errdefer client.deinit();

        const path = try std.fmt.allocPrint(gpa, "/?token={s}&gateway_server={s}-1&slack_client=desktop&batch_presence_aware=1&no_query_on_subscribe=1", .{ token, team_id });
        defer {
            std.crypto.secureZero(u8, path);
            gpa.free(path);
        }
        const headers = try std.fmt.allocPrint(gpa, "Host: wss-primary.slack.com\r\nOrigin: https://app.slack.com\r\nCookie: d={s}\r\n", .{cookie});
        defer {
            std.crypto.secureZero(u8, headers);
            gpa.free(headers);
        }
        client.handshake(path, .{ .headers = headers, .timeout_ms = 10_000 }) catch return error.Connect;
        return .{ .gpa = gpa, .client = client };
    }

    pub fn deinit(s: *Socket) void {
        s.release();
        s.client.close(.{}) catch {};
        s.client.deinit();
    }

    fn release(s: *Socket) void {
        if (s.pending) |m| s.client.done(m);
        s.pending = null;
    }

    /// Next text frame, or null after `timeout_ms` without traffic.
    /// The slice is valid until the next call. Answers WebSocket pings itself.
    pub fn next(s: *Socket, timeout_ms: u32) Error!?[]const u8 {
        s.release();
        s.client.readTimeout(timeout_ms) catch return error.Closed;
        while (true) {
            const msg = (s.client.read() catch return error.Closed) orelse return null;
            switch (msg.type) {
                .text => {
                    s.pending = msg;
                    return msg.data;
                },
                .ping => {
                    s.client.writePong(msg.data) catch return error.Closed;
                    s.client.done(msg);
                },
                .close => {
                    s.client.done(msg);
                    return error.Closed;
                },
                else => s.client.done(msg),
            }
        }
    }

    /// Sends one JSON text frame. `json` is copied (the client masks in place).
    pub fn send(s: *Socket, json: []const u8) Error!void {
        const copy = try s.gpa.dupe(u8, json);
        defer s.gpa.free(copy);
        s.client.write(copy) catch return error.Closed;
    }

    /// App-level keepalive (`{"type":"ping","id":N}`); the server answers `pong`
    pub fn ping(s: *Socket) Error!void {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"ping\",\"id\":{d}}}", .{s.next_id}) catch unreachable;
        s.next_id += 1;
        try s.send(msg);
    }
};
