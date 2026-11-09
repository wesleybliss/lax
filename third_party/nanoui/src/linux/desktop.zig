//! The desktop around the app on Linux: the clipboard (GTK's), opening
//! URLs and files with `xdg-open`, the XDG directories, and the theme.
const std = @import("std");
const gtk = @import("gtk.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn posix_spawnp(pid: *c_int, file: [*:0]const u8, actions: ?*const anyopaque, attr: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" var environ: [*:null]const ?[*:0]const u8;

fn env(name: [*:0]const u8) ?[]const u8 {
    return if (getenv(name)) |v| std.mem.span(v) else null;
}

/// The CLIPBOARD selection: GTK 3's, or GTK 4's display's.
fn board() ?*anyopaque {
    if (!gtk.ready()) return null;
    if (gtk.v4) return gtk.v4api.gdk_display_get_clipboard(gtk.api.gdk_display_get_default() orelse return null);
    return gtk.v3.gtk_clipboard_get(gtk.v3.gdk_atom_intern("CLIPBOARD", 0));
}

/// GTK 4 reads the clipboard only asynchronously: the answer, waited for
/// on GLib's loop (as GTK 3's wait_for_text waits), a second at most.
const Read = struct {
    done: bool = false,
    text: ?[*:0]u8 = null,
    fn finish(source: *anyopaque, result: *anyopaque, data: ?*anyopaque) callconv(.c) void {
        const r: *Read = @ptrCast(@alignCast(data));
        r.text = gtk.v4api.gdk_clipboard_read_text_finish(source, result, null);
        r.done = true;
    }
};

fn readText4(b: *anyopaque) ?[*:0]u8 {
    var r: Read = .{};
    gtk.v4api.gdk_clipboard_read_text_async(b, null, Read.finish, &r);
    var spins: usize = 0;
    while (!r.done and spins < 1000) : (spins += 1) {
        if (gtk.api.g_main_context_iteration(null, 0) == 0) std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(1), .awake) catch {};
    }
    return r.text;
}

pub const clipboard = struct {
    pub fn readText(gpa: std.mem.Allocator) !?[]u8 {
        const b = board() orelse return null;
        const s = (if (gtk.v4) readText4(b) else gtk.v3.gtk_clipboard_wait_for_text(b)) orelse return null;
        defer gtk.api.g_free(s);
        return try gpa.dupe(u8, std.mem.span(s));
    }

    pub fn writeText(text: []const u8) void {
        const b = board() orelse return;
        if (gtk.v4) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(std.heap.c_allocator);
            buf.appendSlice(std.heap.c_allocator, text) catch return;
            buf.append(std.heap.c_allocator, 0) catch return;
            gtk.v4api.gdk_clipboard_set_text(b, @ptrCast(buf.items.ptr));
        } else gtk.v3.gtk_clipboard_set_text(b, text.ptr, @intCast(text.len));
    }

    pub fn changeCount() isize {
        return 0;
    }

    /// Whether the clipboard holds files (copied in the file manager).
    /// GTK 4 only: GTK 3 reports none.
    pub fn hasFiles() bool {
        return gtk.v4 and has(gtk.v4api.gdk_file_list_get_type());
    }

    /// The image on the clipboard (a screenshot, an image copied from a
    /// page or an app) as PNG, or null when it holds none. GTK 4 only.
    /// Caller frees it.
    pub fn readImage(gpa: std.mem.Allocator) !?[]u8 {
        if (!gtk.v4 or !has(gtk.v4api.gdk_texture_get_type())) return null;
        const g4 = &gtk.v4api;
        const r = Wait.start(gpa) orelse return null;
        g4.gdk_clipboard_read_texture_async(board() orelse return null, null, Wait.texture, r);
        if (!r.wait()) return null;
        defer r.finish();
        const texture = r.result orelse return null;
        defer gtk.api.g_object_unref(texture);
        const blob = g4.gdk_texture_save_to_png_bytes(texture) orelse return null;
        defer g4.g_bytes_unref(blob);
        var len: usize = 0;
        const data = g4.g_bytes_get_data(blob, &len) orelse return null;
        return try gpa.dupe(u8, data[0..len]);
    }

    /// The paths of the files on the clipboard (copied in the file
    /// manager), or null when it holds none. Free with `dialog.freePaths`.
    pub fn readFiles(gpa: std.mem.Allocator) !?[][]u8 {
        if (!gtk.v4 or !hasFiles()) return null;
        const g4 = &gtk.v4api;
        const r = Wait.start(gpa) orelse return null;
        g4.gdk_clipboard_read_value_async(board() orelse return null, g4.gdk_file_list_get_type(), 0, null, Wait.files, r);
        if (!r.wait()) return null;
        defer r.finish();
        if (r.failed or r.paths.items.len == 0) {
            for (r.paths.items) |p| gpa.free(p);
            return null;
        }
        return try r.paths.toOwnedSlice(gpa);
    }
};

/// Whether the GTK 4 clipboard offers `kind` (a GType).
fn has(kind: usize) bool {
    if (!gtk.v4) return false;
    const b = board() orelse return false;
    return gtk.v4api.gdk_content_formats_contain_gtype(gtk.v4api.gdk_clipboard_get_formats(b), kind) != 0;
}

/// A GTK 4 clipboard read (of a picture or of files), waited for on GLib's
/// loop, a second at most. The answer is taken in the callback: GDK frees a
/// value with the read's result as soon as it returns.
const Wait = struct {
    gpa: std.mem.Allocator = undefined,
    done: bool = false,
    failed: bool = false,
    /// The picture, owned by the caller
    result: ?*anyopaque = null,
    paths: std.ArrayList([]u8) = .empty,

    fn texture(source: *anyopaque, result: *anyopaque, data: ?*anyopaque) callconv(.c) void {
        const w: *Wait = @ptrCast(@alignCast(data));
        w.result = gtk.v4api.gdk_clipboard_read_texture_finish(source, result, null);
        w.done = true;
    }

    fn files(source: *anyopaque, result: *anyopaque, data: ?*anyopaque) callconv(.c) void {
        const w: *Wait = @ptrCast(@alignCast(data));
        defer w.done = true;
        const g4 = &gtk.v4api;
        const value = g4.gdk_clipboard_read_value_finish(source, result, null) orelse {
            w.failed = true;
            return;
        };
        const list = g4.g_value_get_boxed(value) orelse {
            w.failed = true;
            return;
        };
        const found = g4.gdk_file_list_get_files(list);
        defer gtk.api.g_slist_free(found);
        var node = found;
        while (node) |n| : (node = n.next) {
            const file = n.data orelse continue;
            const name = g4.g_file_get_path(file) orelse continue;
            defer gtk.api.g_free(name);
            const copy = w.gpa.dupe(u8, std.mem.span(name)) catch {
                w.failed = true;
                return;
            };
            w.paths.append(w.gpa, copy) catch {
                w.gpa.free(copy);
                w.failed = true;
                return;
            };
        }
    }

    /// On the heap: after a timeout the callback may still come, and it
    /// writes here (the leak is that of one small struct)
    fn start(gpa: std.mem.Allocator) ?*Wait {
        const w = std.heap.c_allocator.create(Wait) catch return null;
        w.* = .{ .gpa = gpa };
        return w;
    }

    fn finish(w: *Wait) void {
        w.paths.deinit(w.gpa);
        std.heap.c_allocator.destroy(w);
    }

    fn wait(w: *Wait) bool {
        var spins: usize = 0;
        while (!w.done and spins < 1000) : (spins += 1) {
            if (gtk.api.g_main_context_iteration(null, 0) == 0) std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(1), .awake) catch {};
        }
        return w.done;
    }
};

/// Runs `xdg-open` on `target`, not waiting for it.
fn xdgOpen(target: []const u8) bool {
    var buf: [4096]u8 = undefined;
    if (target.len >= buf.len) return false;
    @memcpy(buf[0..target.len], target);
    buf[target.len] = 0;
    const argv = [_:null]?[*:0]const u8{ "xdg-open", @ptrCast(&buf) };
    var pid: c_int = 0;
    return posix_spawnp(&pid, "xdg-open", null, null, &argv, environ) == 0;
}

pub const shell = struct {
    pub fn openUrl(url: []const u8) bool {
        return xdgOpen(url);
    }

    pub fn openPath(file: []const u8) bool {
        return xdgOpen(file);
    }

    pub fn showInFolder(file: []const u8) void {
        _ = xdgOpen(std.fs.path.dirname(file) orelse file);
    }

    pub fn trash(file: []const u8) bool {
        _ = file;
        return false;
    }

    pub fn beep() void {}
};

pub const Directory = enum { data, cache, home, documents, downloads, desktop, temp };

/// The path of a standard directory, by the XDG conventions; for `data`
/// and `cache`, the app's own, created if missing. Caller frees it.
pub fn path(gpa: std.mem.Allocator, dir: Directory, app_name: []const u8) ![]u8 {
    const home = env("HOME") orelse "/tmp";
    const io = std.Io.Threaded.global_single_threaded.io();
    const full = switch (dir) {
        .temp => return gpa.dupe(u8, env("TMPDIR") orelse "/tmp"),
        .home => return gpa.dupe(u8, home),
        .documents => return std.fs.path.join(gpa, &.{ home, "Documents" }),
        .downloads => return std.fs.path.join(gpa, &.{ home, "Downloads" }),
        .desktop => return std.fs.path.join(gpa, &.{ home, "Desktop" }),
        .data => if (env("XDG_DATA_HOME")) |d| try std.fs.path.join(gpa, &.{ d, app_name }) else try std.fs.path.join(gpa, &.{ home, ".local", "share", app_name }),
        .cache => if (env("XDG_CACHE_HOME")) |d| try std.fs.path.join(gpa, &.{ d, app_name }) else try std.fs.path.join(gpa, &.{ home, ".cache", app_name }),
    };
    std.Io.Dir.cwd().createDirPath(io, full) catch {};
    return full;
}

fn nameIsDark(theme: []const u8) bool {
    var i: usize = 0;
    while (i + 4 <= theme.len) : (i += 1) if (std.ascii.eqlIgnoreCase(theme[i .. i + 4], "dark")) return true;
    return false;
}

/// GTK 4.20 reports the desktop's light or dark choice (the settings portal's).
fn hasColorScheme() bool {
    return gtk.v4 and gtk.v4api.gtk_get_minor_version() >= 20;
}

/// The GTK settings properties that decide `isDark`.
pub const dark_properties = [_][*:0]const u8{ "notify::gtk-interface-color-scheme", "notify::gtk-application-prefer-dark-theme", "notify::gtk-theme-name" };

/// Whether the desktop asks for dark colors: `GTK_THEME` when set, else
/// the desktop's color scheme (GNOME's light or dark choice, GTK 4.20+), a
/// GTK setting that prefers dark, or a GTK theme named dark.
pub fn isDark() bool {
    if (env("GTK_THEME")) |theme| return nameIsDark(theme);
    if (!gtk.ready()) return false;
    const settings = gtk.api.gtk_settings_get_default() orelse return false;
    const get = gtk.api.g_object_get;
    const end: ?*anyopaque = null;
    if (hasColorScheme()) {
        // GtkInterfaceColorScheme: 1 default, 2 dark, 3 light
        var scheme: c_int = 0;
        get(settings, "gtk-interface-color-scheme", &scheme, end);
        if (scheme == 2) return true;
        if (scheme == 3) return false;
    }
    var prefer: c_int = 0;
    get(settings, "gtk-application-prefer-dark-theme", &prefer, end);
    if (prefer != 0) return true;
    var name: ?[*:0]u8 = null;
    get(settings, "gtk-theme-name", &name, end);
    const n = name orelse return false;
    defer gtk.api.g_free(n);
    return nameIsDark(std.mem.span(n));
}

pub fn accentColor() [3]f32 {
    return .{ 0.21, 0.52, 0.89 };
}
