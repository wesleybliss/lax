//! Material You (M3) baseline palette, loosely: tonal surfaces and a
//! purple primary. Applied over nanoui's theme each frame, following the
//! system's light or dark choice.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const Palette = struct {
    /// Sidebar and rails: M3's surface container
    container: ui.Color,
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

const light_palette: Palette = .{
    .container = .hex(0xf3edf7),
    .container_high = .hex(0xece6f0),
    .secondary_container = .hex(0xe8def8),
    .primary_container = .hex(0xeaddff),
    .on_primary_container = .hex(0x21005d),
    .link = .hex(0x6750a4),
    .avatars = .{ .hex(0x6750a4), .hex(0x625b71), .hex(0x7d5260), .hex(0x386a20), .hex(0x006a6a), .hex(0x8c4a60), .hex(0x00639b), .hex(0x8f4c38) },
};

const dark_palette: Palette = .{
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

/// Replaces nanoui's theme with ours (call first thing in `view`) and
/// returns the extra tones
pub fn apply(c: *ui.Context) Palette {
    if (c.theme.dark) {
        c.theme = dark_theme;
        return dark_palette;
    }
    c.theme = light_theme;
    return light_palette;
}

pub fn avatarColor(p: Palette, id: []const u8) ui.Color {
    return p.avatars[std.hash.Wyhash.hash(0, id) % p.avatars.len];
}
