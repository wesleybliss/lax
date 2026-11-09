//! Light and dark colors, and themes.
//!
//! The base is Material You (M3) baseline, loosely: tonal surfaces and a
//! purple primary. A theme is a JSON file that overrides some of it (all
//! optional, `#RRGGBB` or `#RRGGBBAA`): `colors` for both modes, then
//! `light` or `dark` over that. Set a few seeds (`background`, `text`,
//! `primary`, `secondary`, `accent`) and the rest follows them; any
//! derived color can still be set by name. Built-in themes live in
//! `themes/` (copied to `<config dir>/themes/` on first run), yours in
//! `<config dir>/custom/themes/*.json` (same format).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const Palette = struct {
    /// Sidebar: M3's surface container
    container: ui.Color,
    /// Workspace rail, chips, code backgrounds
    container_high: ui.Color,
    /// Selected navigation item
    secondary_container: ui.Color,
    primary_container: ui.Color,
    on_primary_container: ui.Color,
    /// Link and mention color
    link: ui.Color,
    /// Tonal avatar colors
    avatars: [8]ui.Color,
};

/// What a theme sets for one mode; null keeps the base (or what a seed derives)
pub const Colors = struct {
    // Neutrals
    background: ?[]const u8 = null,
    /// Cards, menus
    surface: ?[]const u8 = null,
    sidebar: ?[]const u8 = null,
    /// Workspace rail, chips
    rail: ?[]const u8 = null,
    hover: ?[]const u8 = null,
    text: ?[]const u8 = null,
    muted: ?[]const u8 = null,
    border: ?[]const u8 = null,
    // Seeds
    /// Buttons, toggles, focus
    primary: ?[]const u8 = null,
    /// Selected rows
    secondary: ?[]const u8 = null,
    /// Links, mentions and tags
    accent: ?[]const u8 = null,
    // Status
    danger: ?[]const u8 = null,
    success: ?[]const u8 = null,
    // Derived from the seeds, settable
    on_primary: ?[]const u8 = null,
    primary_hover: ?[]const u8 = null,
    primary_container: ?[]const u8 = null,
    secondary_container: ?[]const u8 = null,
    /// Up to 8 avatar colors
    avatars: []const []const u8 = &.{},
};

pub const Fonts = struct {
    /// Family of the interface; the Settings choice wins over it
    ui: []const u8 = "",
    /// Family of message text; the Settings choice wins over it
    chat: []const u8 = "",
};

pub const Def = struct {
    /// Unique; a file's name without `.json` when missing
    id: []const u8 = "",
    name: []const u8 = "",
    author: []const u8 = "",
    version: []const u8 = "",
    description: []const u8 = "",
    fonts: Fonts = .{},
    /// Both modes
    colors: Colors = .{},
    light: Colors = .{},
    dark: Colors = .{},
};

pub const default_id = "lax";

/// A theme resolved for one mode
pub const Resolved = struct {
    theme: ui.Theme,
    pal: Palette,
};

const light_pal: Palette = .{
    .container = .hex(0xf3edf7),
    .container_high = .hex(0xece6f0),
    .secondary_container = .hex(0xe8def8),
    .primary_container = .hex(0xeaddff),
    .on_primary_container = .hex(0x21005d),
    .link = .hex(0x6750a4),
    .avatars = .{ .hex(0x6750a4), .hex(0x625b71), .hex(0x7d5260), .hex(0x386a20), .hex(0x006a6a), .hex(0x8c4a60), .hex(0x00639b), .hex(0x8f4c38) },
};

const dark_pal: Palette = .{
    .container = .hex(0x211f26),
    .container_high = .hex(0x2b2930),
    .secondary_container = .hex(0x4a4458),
    .primary_container = .hex(0x4f378b),
    .on_primary_container = .hex(0xeaddff),
    .link = .hex(0xd0bcff),
    .avatars = .{ .hex(0x9a82db), .hex(0x938f99), .hex(0xb58392), .hex(0x6fa35a), .hex(0x4fb3b3), .hex(0xc27d93), .hex(0x5aa9e0), .hex(0xc7826d) },
};

const light_theme: ui.Theme = .{
    .dark = false,
    .background = .hex(0xfef7ff),
    .surface = .hex(0xf3edf7),
    .surface_hover = .hex(0xece6f0),
    .text = .hex(0x1d1b20),
    .muted = .hex(0x49454f),
    .border = .hex(0xcac4d0),
    .accent = .hex(0x6750a4),
    .accent_hover = .hex(0x4f378b),
    .accent_text = .white,
    .track = .hex(0xe7e0ec),
    .knob = .white,
    .danger = .hex(0xb3261e),
    .success = .hex(0x2e7d32),
    .shadow = .{ .a = 0.12 },
};

const dark_theme: ui.Theme = .{
    .dark = true,
    .background = .hex(0x141218),
    .surface = .hex(0x211f26),
    .surface_hover = .hex(0x2b2930),
    .text = .hex(0xe6e0e9),
    .muted = .hex(0xcac4d0),
    .border = .hex(0x49454f),
    .accent = .hex(0xd0bcff),
    .accent_hover = .hex(0xeaddff),
    .accent_text = .hex(0x381e72),
    .track = .hex(0x36343b),
    .knob = .hex(0xe6e0e9),
    .danger = .hex(0xf2b8b5),
    .success = .hex(0x81c784),
    .shadow = .{ .a = 0.4 },
};

/// The base colors of a mode, with no theme
/// The text cursor's color: the built-in text color, whatever the theme sets
pub fn caretColor(dark: bool) ui.Color {
    return if (dark) dark_theme.text else light_theme.text;
}

pub fn base(dark: bool) Resolved {
    return if (dark) .{ .theme = dark_theme, .pal = dark_pal } else .{ .theme = light_theme, .pal = light_pal };
}

/// `#RGB`, `#RRGGBB` or `#RRGGBBAA` (the `#` is optional); null when invalid
pub fn parseColor(text: []const u8) ?ui.Color {
    const s = if (text.len > 0 and text[0] == '#') text[1..] else text;
    switch (s.len) {
        3 => {
            var v: u24 = 0;
            for (s) |ch| {
                const d = std.fmt.charToDigit(ch, 16) catch return null;
                v = v << 8 | @as(u24, d) * 17;
            }
            return .hex(v);
        },
        6, 8 => {
            const rgb = std.fmt.parseInt(u24, s[0..6], 16) catch return null;
            var c: ui.Color = .hex(rgb);
            if (s.len == 8) {
                const a = std.fmt.parseInt(u8, s[6..8], 16) catch return null;
                c.a = @as(f32, @floatFromInt(a)) / 255;
            }
            return c;
        },
        else => return null,
    }
}

fn channel(v: f32) f32 {
    return if (v <= 0.03928) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

fn luminance(c: ui.Color) f32 {
    return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// Text color that reads on `c`: near black on light colors, white on dark
pub fn onColor(c: ui.Color) ui.Color {
    return if (luminance(c) > 0.179) .hex(0x1d1b20) else .white;
}

/// `c` with its alpha made opaque, for blending derived tones
fn solid(c: ui.Color) ui.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b };
}

fn set(slot: *ui.Color, text: ?[]const u8) void {
    if (text) |t| if (parseColor(t)) |c| {
        slot.* = c;
    };
}

fn has(text: ?[]const u8) ?ui.Color {
    const t = text orelse return null;
    return parseColor(t);
}

/// Applies a theme's colors for one mode over `r`: neutrals first (the
/// tones of a background follow it), then seeds (their tones follow
/// them), then the colors set by name
fn applyColors(r: *Resolved, o: Colors) void {
    const t = &r.theme;
    const p = &r.pal;
    const dark = t.dark;

    // Neutrals
    const bg = has(o.background);
    const fg = has(o.text);
    if (fg) |c| {
        t.text = c;
        t.knob = if (dark) c else .white;
    }
    if (bg) |c| t.background = solid(c);
    if (bg != null or fg != null) {
        const b = t.background;
        const f = t.text;
        t.muted = f.mix(b, 0.28);
        t.border = b.mix(f, 0.2);
        t.track = b.mix(f, 0.12);
    }
    if (bg != null) {
        const b = t.background;
        const f = t.text;
        t.surface = b.mix(f, 0.04);
        t.surface_hover = b.mix(f, 0.08);
        p.container = t.surface;
        p.container_high = b.mix(f, 0.08);
    }

    // Seeds
    if (has(o.primary)) |c| {
        const b = t.background;
        t.accent = c;
        t.accent_hover = c.mix(t.text, 0.3);
        t.accent_text = onColor(c);
        p.primary_container = c.mix(b, if (dark) 0.7 else 0.8);
        p.on_primary_container = onColor(p.primary_container);
        p.link = c;
    }
    if (has(o.secondary)) |c| p.secondary_container = c.mix(t.background, if (dark) 0.6 else 0.85);
    if (has(o.accent)) |c| p.link = c;
    set(&t.danger, o.danger);
    set(&t.success, o.success);

    // By name
    set(&t.surface, o.surface);
    set(&p.container, o.sidebar orelse o.surface);
    set(&p.container_high, o.rail);
    set(&t.surface_hover, o.hover);
    set(&t.muted, o.muted);
    set(&t.border, o.border);
    set(&t.accent_text, o.on_primary);
    set(&t.accent_hover, o.primary_hover);
    set(&p.primary_container, o.primary_container);
    set(&p.secondary_container, o.secondary_container);
    for (o.avatars, 0..) |text, i| {
        if (i >= p.avatars.len) break;
        set(&p.avatars[i], text);
    }
}

/// The colors of `def` (null: the base) in light or dark
pub fn resolve(def: ?*const Def, dark: bool) Resolved {
    var r = base(dark);
    if (def) |d| {
        applyColors(&r, d.colors);
        applyColors(&r, if (dark) d.dark else d.light);
    }
    return r;
}

/// Replaces nanoui's theme with `r` (call first thing in `view`)
pub fn apply(c: *ui.Context, r: Resolved) Palette {
    c.theme = r.theme;
    return r.pal;
}

pub fn avatarColor(p: Palette, id: []const u8) ui.Color {
    return p.avatars[std.hash.Wyhash.hash(0, id) % p.avatars.len];
}

// Catalog

const BuiltIn = struct { file: []const u8, data: []const u8 };

const built_in = [_]BuiltIn{
    .{ .file = "lax.json", .data = @embedFile("themes/lax.json") },
    .{ .file = "ocean.json", .data = @embedFile("themes/ocean.json") },
    .{ .file = "forest.json", .data = @embedFile("themes/forest.json") },
    .{ .file = "rose.json", .data = @embedFile("themes/rose.json") },
    .{ .file = "graphite.json", .data = @embedFile("themes/graphite.json") },
};

/// Copies the built-in themes to `<root>/themes/` so they can be read,
/// copied and edited. Only when that directory does not exist yet: files
/// the user deleted or changed later stay that way (a same-id file there
/// replaces the built-in anyway).
pub fn seedBuiltIns(io: std.Io, root: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, user_dirs[0][0] }) catch return;
    if (std.Io.Dir.cwd().access(io, dir, .{})) return else |_| {}
    std.Io.Dir.cwd().createDirPath(io, dir) catch return;
    for (built_in) |b| {
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, b.file }) catch continue;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = b.data }) catch {};
    }
}

fn parse(arena: std.mem.Allocator, data: []const u8) ?Def {
    return std.json.parseFromSliceLeaky(Def, arena, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

/// Adds `def`, replacing one with the same id
fn put(arena: std.mem.Allocator, list: *std.ArrayList(Def), def: Def) void {
    for (list.items) |*d| if (std.mem.eql(u8, d.id, def.id)) {
        d.* = def;
        return;
    };
    list.append(arena, def) catch {};
}

/// Where user themes live under the config dir; a later one wins over an earlier
pub const user_dirs = [_][]const []const u8{ &.{"themes"}, &.{ "custom", "themes" } };

/// Adds the themes of `<dir>/<sub>/*.json`, in name order
fn loadDir(arena: std.mem.Allocator, io: std.Io, list: *std.ArrayList(Def), root: []const u8, sub: []const []const u8) void {
    var parts: std.ArrayList([]const u8) = .empty;
    parts.append(arena, root) catch return;
    parts.appendSlice(arena, sub) catch return;
    const path = std.fs.path.join(arena, parts.items) catch return;
    var themes = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer themes.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = themes.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        names.append(arena, arena.dupe(u8, entry.name) catch continue) catch {};
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    }.less);
    for (names.items) |name| {
        const data = themes.readFileAlloc(io, name, arena, .limited(1 << 16)) catch continue;
        var def = parse(arena, data) orelse continue;
        const stem = name[0 .. name.len - ".json".len];
        if (def.id.len == 0) def.id = stem;
        if (def.name.len == 0) def.name = def.id;
        put(arena, list, def);
    }
}

/// The built-in themes, then the ones in `user_dirs` under `dir` (null:
/// none). A file that is not a valid theme is skipped. Everything lives
/// in `arena`.
pub fn loadAll(arena: std.mem.Allocator, io: std.Io, dir: ?[]const u8) []const Def {
    var list: std.ArrayList(Def) = .empty;
    for (built_in) |b| if (parse(arena, b.data)) |d| put(arena, &list, d);
    if (dir) |root| for (user_dirs) |sub| loadDir(arena, io, &list, root, sub);
    return list.items;
}

/// The theme with `id`, null for an unknown one
pub fn find(defs: []const Def, id: []const u8) ?*const Def {
    for (defs) |*d| if (std.mem.eql(u8, d.id, id)) return d;
    return null;
}

// Tests

test "colors parse, bad ones don't" {
    const c = parseColor("#6750a4").?;
    try std.testing.expectApproxEqAbs(@as(f32, 0x67) / 255, c.r, 0.001);
    try std.testing.expectEqual(@as(f32, 1), c.a);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), parseColor("#ff000080").?.a, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1), parseColor("f00").?.r, 0.001);
    try std.testing.expect(parseColor("#12") == null);
    try std.testing.expect(parseColor("#gggggg") == null);
    try std.testing.expect(parseColor("") == null);
}

test "a theme with one seed derives the rest from it" {
    const def: Def = .{ .id = "t", .colors = .{ .primary = "#0b61a4" } };
    const r = resolve(&def, false);
    try std.testing.expectEqual(parseColor("#0b61a4").?, r.theme.accent);
    // Text on a dark primary is white, the tint follows the primary
    try std.testing.expectEqual(ui.Color.white, r.theme.accent_text);
    try std.testing.expect(r.pal.primary_container.b > r.pal.primary_container.r);
    // What it did not set stays the base
    try std.testing.expectEqual(light_theme.background, r.theme.background);
    // Named colors win over derived ones
    const named: Def = .{ .colors = .{ .primary = "#0b61a4", .on_primary = "#ffee00" } };
    try std.testing.expectEqual(parseColor("#ffee00").?, resolve(&named, false).theme.accent_text);
}

test "light and dark blocks apply to their own mode, over the shared colors" {
    const def: Def = .{
        .colors = .{ .primary = "#112233", .danger = "#aa0000" },
        .dark = .{ .primary = "#ddeeff" },
    };
    try std.testing.expectEqual(parseColor("#112233").?, resolve(&def, false).theme.accent);
    try std.testing.expectEqual(parseColor("#ddeeff").?, resolve(&def, true).theme.accent);
    try std.testing.expectEqual(parseColor("#aa0000").?, resolve(&def, true).theme.danger);
    try std.testing.expect(resolve(&def, true).theme.dark);
}

test "a background derives its surfaces; bad colors are ignored" {
    const def: Def = .{ .light = .{ .background = "#ffffff", .text = "#000000", .secondary = "nope" } };
    const r = resolve(&def, false);
    try std.testing.expectEqual(ui.Color.white, r.theme.background);
    try std.testing.expect(r.theme.surface.r < 1 and r.theme.surface.r > 0.9);
    try std.testing.expectEqual(light_pal.secondary_container, r.pal.secondary_container);
}

test "built-in themes parse and each differs from the base in both modes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const defs = loadAll(arena_state.allocator(), std.testing.io, null);
    try std.testing.expectEqual(built_in.len, defs.len);
    try std.testing.expect(find(defs, default_id) != null);
    for (defs) |*d| {
        try std.testing.expect(d.name.len > 0);
        if (std.mem.eql(u8, d.id, default_id)) continue;
        for ([_]bool{ false, true }) |dark| {
            const r = resolve(d, dark);
            try std.testing.expect(!std.meta.eql(r.theme.accent, base(dark).theme.accent));
        }
    }
}

test "user themes load from the themes directory; a same-id file replaces a built-in" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.createDirPath(io, "lax/themes");
    try tmp.dir.writeFile(io, .{ .sub_path = "lax/themes/mine.json", .data = "{\"colors\":{\"primary\":\"#ff0000\"}}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lax/themes/ocean.json", .data = "{\"id\":\"ocean\",\"name\":\"My Ocean\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lax/themes/broken.json", .data = "{nope" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lax/themes/notes.txt", .data = "ignored" });
    try tmp.dir.createDirPath(io, "lax/custom/themes");
    try tmp.dir.writeFile(io, .{ .sub_path = "lax/custom/themes/extra.json", .data = "{\"name\":\"Extra\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lax/custom/themes/mine.json", .data = "{\"name\":\"Custom Mine\"}" });
    const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/lax", .{tmp.sub_path});
    const defs = loadAll(arena, io, dir);
    try std.testing.expectEqual(built_in.len + 2, defs.len);
    // custom/themes comes later and wins over themes
    try std.testing.expectEqualStrings("Custom Mine", find(defs, "mine").?.name);
    try std.testing.expectEqualStrings("Extra", find(defs, "extra").?.name);
    try std.testing.expectEqualStrings("My Ocean", find(defs, "ocean").?.name);
    try std.testing.expect(find(defs, "broken") == null);
}

test "built-ins are seeded once, and never over what is there" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/lax", .{tmp.sub_path});
    seedBuiltIns(io, root);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqual(built_in.len, loadAll(arena, io, root).len);
    // A deleted file stays deleted, an edited one stays edited
    try tmp.dir.deleteFile(io, "lax/themes/rose.json");
    try tmp.dir.writeFile(io, .{ .sub_path = "lax/themes/ocean.json", .data = "{\"name\":\"Mine\"}" });
    seedBuiltIns(io, root);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "lax/themes/rose.json", .{}));
    try std.testing.expectEqualStrings("Mine", find(loadAll(arena, io, root), "ocean").?.name);
}
