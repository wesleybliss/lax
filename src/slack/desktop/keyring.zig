//! OS keyring access. Linux: Secret Service via the `secret-tool` CLI for
//! now (libsecret from libsecret-tools). A native D-Bus or libsecret client is
//! a later swap behind the same functions.
const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{ Unsupported, NotFound, Unavailable } || std.mem.Allocator.Error;

fn runSecretTool(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) Error![]u8 {
    const result = std.process.run(gpa, io, .{ .argv = argv, .stderr_limit = .limited(4096), .stdout_limit = .limited(1 << 16) }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unavailable,
    };
    defer gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);
    if (!result.term.success()) return error.NotFound;
    return result.stdout;
}

/// Chromium's "Slack Safe Storage" password, used to derive the cookie key.
/// Caller owns the result.
pub fn slackSafeStoragePassword(gpa: std.mem.Allocator, io: std.Io) Error![]u8 {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const out = try runSecretTool(gpa, io, &.{ "secret-tool", "lookup", "application", "Slack" });
    defer {
        std.crypto.secureZero(u8, out);
        gpa.free(out);
    }
    const trimmed = std.mem.trimEnd(u8, out, "\n");
    if (trimmed.len == 0) return error.NotFound;
    return gpa.dupe(u8, trimmed);
}

const session_args = [_][]const u8{ "application", "lax-slack-clone", "kind", "session" };

/// Our own saved session (a JSON blob), kept in the keyring instead of
/// anything of Slack's. Caller owns the result.
pub fn loadSession(gpa: std.mem.Allocator, io: std.Io) Error![]u8 {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const out = try runSecretTool(gpa, io, &(.{ "secret-tool", "lookup" } ++ session_args));
    if (out.len == 0) {
        gpa.free(out);
        return error.NotFound;
    }
    return out;
}

/// Saves the session. The secret goes over stdin, never on a command line.
pub fn storeSession(gpa: std.mem.Allocator, io: std.Io, json: []const u8) Error!void {
    _ = gpa;
    if (builtin.os.tag != .linux) return error.Unsupported;
    var child = std.process.spawn(io, .{
        .argv = &(.{ "secret-tool", "store", "--label=Lax Slack session" } ++ session_args),
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.Unavailable;
    errdefer child.kill(io);
    {
        const stdin = child.stdin.?;
        stdin.writeStreamingAll(io, json) catch return error.Unavailable;
        stdin.close(io);
        child.stdin = null;
    }
    const term = child.wait(io) catch return error.Unavailable;
    if (!term.success()) return error.Unavailable;
}

pub fn clearSession(gpa: std.mem.Allocator, io: std.Io) void {
    if (builtin.os.tag != .linux) return;
    const out = runSecretTool(gpa, io, &(.{ "secret-tool", "clear" } ++ session_args)) catch return;
    gpa.free(out);
}
