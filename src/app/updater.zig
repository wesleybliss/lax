//! Keeps the app current on Linux. On startup and every 30 minutes a thread
//! asks GitHub for the latest release. A newer one is announced to the UI,
//! and when the user accepts, the package the app was installed from is
//! downloaded, checked against the release's `SHA256SUMS`, and installed:
//!
//! - rpm / deb: `pkexec dnf install` / `pkexec apt-get install` (polkit asks
//!   for the password), then the app restarts
//! - AppImage: the running file is replaced, then the app restarts
//!
//! A build that is none of those (zip, `zig build`, Flatpak) never checks.
const std = @import("std");
const builtin = @import("builtin");
const slack = @import("slack");
const store = @import("store");
const build_options = @import("build_options");
const state_file = @import("state_file.zig");

pub const repo = "wesleybliss/lax";
pub const check_ms: u64 = 30 * 60 * 1000;
const tick_ms: u64 = 250;
const max_package_bytes = 512 << 20;

pub const Kind = enum { rpm, deb, appimage };

/// How this process was installed, and what a restart runs
const Install = struct {
    kind: Kind,
    /// rpm / deb: the installed binary. AppImage: the .AppImage file
    path: []const u8,
};

const Asset = struct {
    name: []const u8,
    browser_download_url: []const u8,
};

const Release = struct {
    tag_name: []const u8,
    draft: bool = false,
    prerelease: bool = false,
    assets: []const Asset = &.{},
};

/// A release worth installing: its version and the files it takes
const Found = struct {
    version: []const u8,
    package: Asset,
    sums_url: []const u8,
};

pub const Updater = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    /// The network thread's queue: updates reach the store through it
    updates: *store.Queue(store.Item),
    wake: *const store.Wake,
    thread: ?std.Thread = null,
    quit: std.atomic.Value(bool) = .init(false),
    /// The UI asked to install what was announced
    apply_requested: std.atomic.Value(bool) = .init(false),
    /// The UI asked to check now, instead of at the next 30 minute mark
    check_requested: std.atomic.Value(bool) = .init(false),
    /// Downloading or installing (quitting then does not wait for the thread)
    installing: std.atomic.Value(bool) = .init(false),
    /// Set once an install worked: what to start in place of this process (gpa-owned)
    relaunch_path: ?[]u8 = null,
    debug: bool = false,

    pub fn start(u: *Updater) !void {
        if (builtin.os.tag != .linux) return;
        if (u.env.get("LAX_NO_UPDATE") != null) return;
        u.debug = u.env.get("LAX_DEBUG") != null;
        u.thread = try std.Thread.spawn(.{}, run, .{u});
    }

    /// Waits for the thread, unless it is mid-install: a download can stall
    /// with no way to cut it short, and a package manager already running
    /// goes on without us. The thread then leaves the queue alone (`emit`).
    pub fn stop(u: *Updater) void {
        u.quit.store(true, .release);
        if (u.thread) |t| {
            if (u.installing.load(.acquire)) t.detach() else t.join();
        }
        u.thread = null;
        if (u.relaunch_path) |p| {
            u.gpa.free(p);
            u.relaunch_path = null;
        }
    }

    /// UI thread: install the announced release
    pub fn apply(u: *Updater) void {
        u.apply_requested.store(true, .release);
    }

    /// UI thread: check for a release now, and report how it went
    pub fn checkNow(u: *Updater) void {
        // No thread (not Linux, or `LAX_NO_UPDATE`): nothing will answer
        if (u.thread == null) return u.emitCheck(.unsupported);
        u.check_requested.store(true, .release);
    }

    fn dbg(u: *const Updater, comptime fmt: []const u8, args: anytype) void {
        if (u.debug) std.debug.print("update: " ++ fmt ++ "\n", args);
    }

    fn emit(u: *Updater, phase: store.UpdatePhase, version: []const u8, comptime fmt: []const u8, args: anytype) void {
        // The app is ending: the queue may be gone
        if (u.quit.load(.acquire)) return;
        var arena = std.heap.ArenaAllocator.init(u.gpa);
        const a = arena.allocator();
        const msg = std.fmt.allocPrint(a, fmt, args) catch return arena.deinit();
        const ver = a.dupe(u8, version) catch return arena.deinit();
        const item: store.Item = .{ .arena = arena, .update = .{ .app_update = .{ .phase = phase, .version = ver, .message = msg } } };
        u.updates.push(u.gpa, u.io, item) catch {
            var it = item;
            return it.deinit();
        };
        u.wake.signal();
    }

    fn emitCheck(u: *Updater, result: store.UpdateCheck) void {
        if (u.quit.load(.acquire)) return;
        const item: store.Item = .{ .arena = .init(u.gpa), .update = .{ .update_check = result } };
        u.updates.push(u.gpa, u.io, item) catch {
            var it = item;
            return it.deinit();
        };
        u.wake.signal();
    }

    fn sleepTick(u: *Updater) bool {
        u.io.sleep(.fromMilliseconds(tick_ms), .awake) catch return false;
        return true;
    }

    fn run(u: *Updater) void {
        var arena_state = std.heap.ArenaAllocator.init(u.gpa);
        defer arena_state.deinit();
        const how = detect(arena_state.allocator(), u) orelse {
            u.dbg("not installed from a package: updates are off", .{});
            // Still answers a manual check
            while (!u.quit.load(.acquire)) {
                if (u.check_requested.swap(false, .acq_rel)) u.emitCheck(.unsupported);
                if (!u.sleepTick()) return;
            }
            return;
        };
        u.dbg("installed as {s} ({s})", .{ @tagName(how.kind), how.path });

        // Each check's release lives in its own arena, replaced by the next
        var found_arena: ?std.heap.ArenaAllocator = null;
        defer if (found_arena) |*a| a.deinit();
        var found: ?Found = null;
        var manual = false;

        while (!u.quit.load(.acquire)) {
            const asked = manual;
            manual = false;
            var next_arena = std.heap.ArenaAllocator.init(u.gpa);
            if (u.check(next_arena.allocator(), how.kind)) |release| {
                if (found_arena) |*a| a.deinit();
                found_arena = next_arena;
                found = release;
                u.emit(.available, release.version, "", .{});
                if (asked) u.emitCheck(.found);
            } else |err| {
                u.dbg("check: {s}", .{@errorName(err)});
                next_arena.deinit();
                if (asked) u.emitCheck(if (err == error.NoUpdate) .current else .failed);
            }

            var waited: u64 = 0;
            while (waited < check_ms and !u.quit.load(.acquire)) : (waited += tick_ms) {
                if (u.check_requested.swap(false, .acq_rel)) {
                    manual = true;
                    break;
                }
                if (u.apply_requested.swap(false, .acq_rel)) if (found) |f| {
                    // Installed: the UI restarts the app, nothing left to check
                    if (u.install(how, f)) return;
                };
                if (!u.sleepTick()) return;
            }
        }
    }

    /// The newest release when it is newer than this build and has what this install needs
    fn check(u: *Updater, arena: std.mem.Allocator, kind: Kind) !Found {
        var api = slack.http.Api.init(u.gpa, u.io, "", "", "");
        defer api.deinit();
        api.user_agent = "lax/" ++ build_options.version;
        const url = "https://api.github.com/repos/" ++ repo ++ "/releases/latest";
        const body = try api.download(arena, url, 4 << 20);
        const release = try std.json.parseFromSliceLeaky(Release, arena, body, .{ .ignore_unknown_fields = true });
        if (release.draft or release.prerelease) return error.NoUpdate;
        if (!isNewer(release.tag_name, build_options.version)) return error.NoUpdate;
        const package = pickAsset(kind, builtin.cpu.arch, release.assets) orelse return error.NoPackage;
        const sums = findAsset(release.assets, "SHA256SUMS") orelse return error.NoChecksums;
        return .{ .version = std.mem.trimStart(u8, release.tag_name, "v"), .package = package, .sums_url = sums.browser_download_url };
    }

    /// Downloads, verifies and installs `f`. True when it worked and the UI
    /// was told to restart the app.
    fn install(u: *Updater, how: Install, f: Found) bool {
        u.installing.store(true, .release);
        defer u.installing.store(false, .release);
        u.emit(.downloading, f.version, "", .{});
        u.installInner(how, f) catch |err| {
            u.dbg("install: {s}", .{@errorName(err)});
            u.emit(.failed, f.version, "{s}", .{failureText(err)});
            return false;
        };
        u.relaunch_path = u.gpa.dupe(u8, how.path) catch return false;
        u.emit(.restart, f.version, "", .{});
        return true;
    }

    fn installInner(u: *Updater, how: Install, f: Found) !void {
        var arena_state = std.heap.ArenaAllocator.init(u.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var api = slack.http.Api.init(u.gpa, u.io, "", "", "");
        defer api.deinit();
        api.user_agent = "lax/" ++ build_options.version;

        const sums = api.download(arena, f.sums_url, 1 << 20) catch return error.Download;
        const want = checksumFor(sums, f.package.name) orelse return error.Checksum;
        const bytes = api.download(arena, f.package.browser_download_url, max_package_bytes) catch return error.Download;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const have = std.fmt.bytesToHex(digest, .lower);
        if (!std.ascii.eqlIgnoreCase(&have, want)) return error.Checksum;

        const cwd = std.Io.Dir.cwd();
        switch (how.kind) {
            .appimage => {
                // Beside the old file, so the swap is one atomic rename
                const staged = try std.fmt.allocPrint(arena, "{s}.update", .{how.path});
                cwd.writeFile(u.io, .{ .sub_path = staged, .data = bytes, .flags = .{ .permissions = .executable_file } }) catch return error.Write;
                errdefer cwd.deleteFile(u.io, staged) catch {};
                cwd.rename(staged, cwd, how.path, u.io) catch return error.Write;
            },
            .rpm, .deb => {
                const cache = (try state_file.cacheDir(arena, u.env)) orelse return error.Write;
                const dir = try std.fs.path.join(arena, &.{ cache, "update" });
                // Leftovers of earlier tries go first
                cwd.deleteTree(u.io, dir) catch {};
                cwd.createDirPath(u.io, dir) catch return error.Write;
                const file = try std.fs.path.join(arena, &.{ dir, f.package.name });
                defer cwd.deleteTree(u.io, dir) catch {};
                cwd.writeFile(u.io, .{ .sub_path = file, .data = bytes }) catch return error.Write;
                u.emit(.installing, f.version, "", .{});
                try u.runPackageManager(how.kind, file);
            },
        }
    }

    /// pkexec asks for the password in the desktop's own dialog (there is no
    /// terminal for `sudo` or `dnf` to ask on)
    fn runPackageManager(u: *Updater, kind: Kind, file: []const u8) !void {
        const argv: []const []const u8 = switch (kind) {
            .rpm => &.{ "pkexec", "dnf", "install", "-y", file },
            else => &.{ "pkexec", "apt-get", "install", "-y", file },
        };
        // Nothing is piped: a package manager must never meet a closed pipe midway
        var child = std.process.spawn(u.io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return error.NoPkexec;
        const term = child.wait(u.io) catch return error.InstallFailed;
        switch (term) {
            .exited => |code| switch (code) {
                0 => {},
                // polkit: dialog dismissed, or not authorized
                126, 127 => return error.Cancelled,
                else => return error.InstallFailed,
            },
            else => return error.InstallFailed,
        }
    }
};

fn failureText(err: anyerror) []const u8 {
    return switch (err) {
        error.Download => "Could not download the update",
        error.Checksum => "The download did not match its checksum",
        error.Write => "Could not save the update here",
        error.NoPkexec => "pkexec is needed to install the update",
        error.Cancelled => "Install cancelled",
        error.InstallFailed => "The package manager failed",
        else => "The update failed",
    };
}

/// Where this process came from: an AppImage, or a package that owns the binary
fn detect(arena: std.mem.Allocator, u: *Updater) ?Install {
    if (u.env.get("APPIMAGE")) |p| if (p.len > 0) return .{ .kind = .appimage, .path = p };
    if (u.env.get("FLATPAK_ID") != null) return null;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.readLinkAbsolute(u.io, "/proc/self/exe", &buf) catch return null;
    const exe = arena.dupe(u8, stripDeleted(buf[0..n])) catch return null;
    if (owns(u, &.{ "rpm", "-qf", exe })) return .{ .kind = .rpm, .path = exe };
    if (owns(u, &.{ "dpkg", "-S", exe })) return .{ .kind = .deb, .path = exe };
    return null;
}

/// A package manager answers yes: some installed package has this file
fn owns(u: *Updater, argv: []const []const u8) bool {
    const result = std.process.run(u.gpa, u.io, .{ .argv = argv }) catch return false;
    defer u.gpa.free(result.stdout);
    defer u.gpa.free(result.stderr);
    return result.term.success();
}

/// A binary replaced while running reads back as `/usr/bin/lax (deleted)`
fn stripDeleted(path: []const u8) []const u8 {
    const suffix = " (deleted)";
    return if (std.mem.endsWith(u8, path, suffix)) path[0 .. path.len - suffix.len] else path;
}

/// Starts `path` detached, for after this process is gone
pub fn relaunch(gpa: std.mem.Allocator, io: std.Io, path: []const u8) void {
    const argv: []const []const u8 = &.{ "sh", "-c", "\"$1\" </dev/null >/dev/null 2>&1 &", "lax-relaunch", path };
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch return;
    gpa.free(result.stdout);
    gpa.free(result.stderr);
}

/// `tag` (`v1.2.3` or `1.2.3`) is a higher version than `current`
fn isNewer(tag: []const u8, current: []const u8) bool {
    const a = std.SemanticVersion.parse(std.mem.trimStart(u8, tag, "v")) catch return false;
    const b = std.SemanticVersion.parse(current) catch return false;
    return a.order(b) == .gt;
}

fn findAsset(assets: []const Asset, name: []const u8) ?Asset {
    for (assets) |a| if (std.mem.eql(u8, a.name, name)) return a;
    return null;
}

/// The release file for this install and CPU: `lax-1.2.3-1.x86_64.rpm`,
/// `lax_1.2.3_amd64.deb`, `lax-1.2.3-linux-x86_64.AppImage`
fn pickAsset(kind: Kind, arch: std.Target.Cpu.Arch, assets: []const Asset) ?Asset {
    const ext = switch (kind) {
        .rpm => ".rpm",
        .deb => ".deb",
        .appimage => ".AppImage",
    };
    const token = switch (arch) {
        .x86_64 => if (kind == .deb) "amd64" else "x86_64",
        .aarch64 => if (kind == .deb) "arm64" else "aarch64",
        else => return null,
    };
    for (assets) |a| {
        if (!std.mem.endsWith(u8, a.name, ext) or std.mem.indexOf(u8, a.name, token) == null) continue;
        // The name becomes a file name, the URL a download: both must be plain
        if (std.mem.indexOfAny(u8, a.name, "/\\") != null or std.mem.startsWith(u8, a.name, ".")) continue;
        if (!std.mem.startsWith(u8, a.browser_download_url, "https://github.com/")) continue;
        return a;
    }
    return null;
}

/// The hash `sha256sum` printed for `name` (`<hash>  <name>`, or `<hash> *<name>`)
fn checksumFor(sums: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeAny(u8, sums, "\r\n");
    while (lines.next()) |line| {
        const sep = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const hash = line[0..sep];
        const file = std.mem.trimStart(u8, line[sep..], " *");
        if (hash.len == 64 and std.mem.eql(u8, file, name)) return hash;
    }
    return null;
}

test "newer versions only" {
    try std.testing.expect(isNewer("v0.3.0", "0.2.0"));
    try std.testing.expect(isNewer("0.2.1", "0.2.0"));
    try std.testing.expect(isNewer("v1.0.0", "0.9.9"));
    try std.testing.expect(isNewer("v0.10.0", "0.9.0"));
    try std.testing.expect(!isNewer("v0.2.0", "0.2.0"));
    try std.testing.expect(!isNewer("v0.1.9", "0.2.0"));
    try std.testing.expect(!isNewer("nightly", "0.2.0"));
}

test "the package for this install and CPU" {
    const assets: []const Asset = &.{
        .{ .name = "lax-0.3.0-linux-x86_64.zip", .browser_download_url = "https://github.com/x/y/releases/download/v0.3.0/lax-0.3.0-linux-x86_64.zip" },
        .{ .name = "lax-0.3.0-1.x86_64.rpm", .browser_download_url = "https://github.com/x/y/releases/download/v0.3.0/lax-0.3.0-1.x86_64.rpm" },
        .{ .name = "lax-0.3.0-1.aarch64.rpm", .browser_download_url = "https://github.com/x/y/releases/download/v0.3.0/lax-0.3.0-1.aarch64.rpm" },
        .{ .name = "lax_0.3.0_amd64.deb", .browser_download_url = "https://github.com/x/y/releases/download/v0.3.0/lax_0.3.0_amd64.deb" },
        .{ .name = "lax_0.3.0_arm64.deb", .browser_download_url = "https://github.com/x/y/releases/download/v0.3.0/lax_0.3.0_arm64.deb" },
        .{ .name = "lax-0.3.0-linux-aarch64.AppImage", .browser_download_url = "https://github.com/x/y/releases/download/v0.3.0/lax-0.3.0-linux-aarch64.AppImage" },
    };
    try std.testing.expectEqualStrings("lax-0.3.0-1.x86_64.rpm", pickAsset(.rpm, .x86_64, assets).?.name);
    try std.testing.expectEqualStrings("lax-0.3.0-1.aarch64.rpm", pickAsset(.rpm, .aarch64, assets).?.name);
    try std.testing.expectEqualStrings("lax_0.3.0_amd64.deb", pickAsset(.deb, .x86_64, assets).?.name);
    try std.testing.expectEqualStrings("lax_0.3.0_arm64.deb", pickAsset(.deb, .aarch64, assets).?.name);
    try std.testing.expect(pickAsset(.appimage, .x86_64, assets) == null);
    try std.testing.expectEqualStrings("lax-0.3.0-linux-aarch64.AppImage", pickAsset(.appimage, .aarch64, assets).?.name);
    try std.testing.expect(pickAsset(.rpm, .riscv64, assets) == null);
}

test "assets with odd names or hosts are skipped" {
    const evil: []const Asset = &.{
        .{ .name = "../lax-x86_64.rpm", .browser_download_url = "https://github.com/x/y/a.rpm" },
        .{ .name = "lax-x86_64.rpm", .browser_download_url = "https://evil.example/a.rpm" },
        .{ .name = "lax-x86_64.rpm", .browser_download_url = "http://github.com/a.rpm" },
    };
    try std.testing.expect(pickAsset(.rpm, .x86_64, evil) == null);
}

test "checksum lines" {
    const hash: [64]u8 = @splat('a');
    const other: [64]u8 = @splat('b');
    const sums = &hash ++ "  lax-0.3.0-1.x86_64.rpm\n" ++ &other ++ " *lax_0.3.0_amd64.deb\n";
    try std.testing.expectEqualStrings(&hash, checksumFor(sums, "lax-0.3.0-1.x86_64.rpm").?);
    try std.testing.expectEqualStrings(&other, checksumFor(sums, "lax_0.3.0_amd64.deb").?);
    try std.testing.expect(checksumFor(sums, "lax") == null);
    try std.testing.expect(checksumFor("short  lax\n", "lax") == null);
}

test "a replaced binary loses its suffix" {
    try std.testing.expectEqualStrings("/usr/bin/lax", stripDeleted("/usr/bin/lax (deleted)"));
    try std.testing.expectEqualStrings("/usr/bin/lax", stripDeleted("/usr/bin/lax"));
}

test "release JSON from the API" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const json =
        \\{"tag_name":"v0.3.0","draft":false,"prerelease":false,"name":"x","assets":[
        \\{"name":"SHA256SUMS","size":1,"browser_download_url":"https://github.com/a/b/releases/download/v0.3.0/SHA256SUMS"}]}
    ;
    const release = try std.json.parseFromSliceLeaky(Release, arena_state.allocator(), json, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("v0.3.0", release.tag_name);
    try std.testing.expect(findAsset(release.assets, "SHA256SUMS") != null);
}
