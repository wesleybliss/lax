# Local patches to nanoui

Vendored from https://github.com/justrach/nanoui at tag v0.12.0 (commit d1330a8, MIT, see LICENSE).
Kept in-tree so we can fix bugs we hit. Every change here should be small and upstreamable.
Record each patch below with the reason.

## 1. Color emoji on Linux/Windows/portable text (COLR/CPAL)

**Why:** the pure-Zig text path (`text_tt.zig`) rasterized coverage only and had no emoji font in its fallback list, so emoji came out as monochrome outlines (Noto Emoji or a symbol font), tinted by the text color.

**What:**
- `ui/tt/colr.zig` (new): COLR v0 and v1 + CPAL palette 0. Paints: ColrLayers, Solid, Linear/Radial/Sweep gradients (pad/repeat/reflect), Glyph (clip), ColrGlyph, Transform/Translate/Scale/ScaleUniform/Rotate/Skew (and around-center variants), Composite (all Porter-Duff and blend modes). Each outline goes through the existing `tt/raster.zig` coverage rasterizer; the result is one premultiplied BGRA bitmap per glyph and size. Variable-font deltas (`Var*` paints) are ignored (defaults are drawn).
- `ui/tt/gsub.zig` (new): ligature lookups of `ccmp`/`liga`/`rlig`, which join ZWJ sequences, flags, skin tones and keycaps into one glyph. Contextual, single and multiple substitutions are skipped (Noto uses them only for fallbacks of unsupported tag sequences).
- `ui/tt/emoji.zig` (new): Emoji_Presentation ranges and sequence grammar (flags, VS16, modifiers, keycaps, tags, ZWJ).
- `tt/font.zig`: `COLR`, `CPAL`, `GSUB` table offsets, `Font.isColor`.
- `tt/fontdb.zig`: `emojiFace` finds a color font by name (Noto Color Emoji, Apple Color Emoji, Segoe UI Emoji, Twemoji Mozilla, ...) and checks it really has COLR; emoji-presentation characters go to it before any outline font, other missing characters reach it before the "any face" scan. No color font installed: the old behavior.
- `text_tt.zig`: `shapeInto` shapes an emoji sequence as the color font's ligature glyph (advance from the font, about 1.25 em in Noto); ZWJ and variation selectors alone are zero width. `glyph()` returns color glyphs from the image atlas.
- `atlas_tt.zig`: `Sprite.color`, `Atlas.colorGlyph` (rasterize once per font, glyph and size; geometry kept in `color_meta`).
- `images.zig`: `lookup` and `insertDrawn` pack an app-drawn bitmap into the image atlas, kept and repacked like a decoded picture (`getDecoded` split into `remember`).
- `paint.zig`: a color sprite is pushed as a `Kind.image` instance (white, text alpha) instead of a tinted text glyph. Guarded by `@hasField(Sprite, "color")`, so `text_mac.zig` is untouched.
- Tests: `ui/tests_emoji.zig`, tests in `tt/colr.zig` and `tt/emoji.zig` (the font-backed ones skip when Noto Color Emoji is not installed).

**Known limits:** emoji are placed on whole pixels (no subpixel phase); wrapping can still break inside a ZWJ sequence for a word wider than the line; more distinct color glyphs on screen at once than the decoded-image budget (12 MB, hundreds at 40 pt) garbles that frame; bitmap fonts (CBDT/sbix) are not read.

## 2. Ctrl+C copies the page's selection with no text field focused (Linux)

**Why:** `surface.zig` only turned Ctrl+C into a `.copy` command while a text field had focus, so text selected in a `selectable` box could never be copied unless the composer happened to be focused.

**What:** `keyPress` sends the `.copy` command for Ctrl+C even when `focused_text` is null. `frame.zig` already copies the selection when no field takes the command.

## 3. A second font family for chat text, and app-chosen families (all platforms but macOS)

Why: Lax lets the user pick an interface font and a chat font. nanoui had one
family per window theme, fixed at window creation.

- `ui/types.zig`: `TextStyle.alt`, text that uses the second family.
- `ui/context.zig`: `family_override`, `mono_override`, `alt_override`, set by the view; they win over the theme's families and apply from the next frame.
- `ui/frame.zig`: passes them to the text system.
- `ui/text_tt.zig`: `alt_family`, `setAltFamily`, and `alt` in the font and layout cache keys. `ui/text_mac.zig` has a no-op `setAltFamily` (macOS keeps one family).

## 4. Light and dark from the desktop's real setting, live (Linux)

**Why:** `desktop.isDark()` only looked for "dark" in the `GTK_THEME` environment variable, which GNOME never sets, so a dark desktop always got the light theme, and a change at runtime was never noticed (frames run on input only).

**What:**
- `linux/desktop.zig`: `isDark()` asks GTK's settings: `gtk-interface-color-scheme` (GTK 4.20+, the settings portal's light or dark choice), then `gtk-application-prefer-dark-theme`, then a theme name containing "dark". `GTK_THEME`, when set, still decides alone.
- `linux/gtk.zig`: `g_object_get`, `gtk_settings_get_default`, `gtk_get_minor_version` (GTK 4).
- `linux/surface.zig`: `watchAppearance` connects to the settings' `notify::` signals for those properties and requests a frame; the handlers are disconnected in `destroy`. Not connected with a `theme_override`.

## 5. Files, links and text dragged in from other apps (Linux, GTK 4)

**Why:** `Context.acceptDrop` / `dropAt` already worked on the Mac and Windows, but the Linux surface had no drop target, so a drag from the file manager was refused.

**What:**
- `linux/surface_gtk4.zig`: `attachDrops` puts a `GtkDropTarget` (copy; `GdkFileList` and strings) on the area. `enter` / `motion` set `input.drag_over`, run a frame and answer copy only where `acceptsDropAt`; `leave` clears it; `drop` delivers files as `file://` URLs (`g_file_get_uri`, like the other platforms) or the text for one frame. It is attached with the other controllers, so the GL to CPU fallback keeps it.
- `linux/gtk.zig`: the GTK 4 table gains `gtk_drop_target_new`, `gtk_drop_target_set_gtypes`, `gdk_file_list_get_type` / `_get_files` (GTK 4.6+, else the old GTK 3 fallback), `g_file_get_uri`, `g_type_check_value_holds`, `g_value_get_boxed`, `g_value_get_string`.

**Known limits:** GTK 3 has no drop target (GTK 4 is what ships on current distros); no tests (a drop needs a real drag source on a display).

## 6. JPEG, GIF, WebP and the rest on Linux, through GTK 4

**Why:** the portable image path only reads PNG, so a JPEG given to `ui.image` was dropped. Slack's file previews are JPEGs for JPEG uploads.

**What:**
- `linux/texture_decode.zig` (new): `decode` and `dimensions` over `gdk_texture_new_from_bytes` and `gdk_texture_download` (premultiplied BGRA, what the PNG decoder returns). GTK 3 has no texture: it answers "invalid image", as before.
- `linux/gtk.zig`: the GTK 4 table gains `g_bytes_new`, `g_bytes_unref`, `g_error_free`, `gdk_texture_new_from_bytes`, `_get_width`, `_get_height`, `gdk_texture_download`.
- `ui/images.zig`: on Linux, bytes that are not a PNG go to it, for the header probe and for the decode. PNG keeps nanoui's own decoder.
- Test: in `texture_decode.zig` (skips without GTK 4 and a display).

**Known limits:** decoded on the UI thread, like the PNG path; a GIF shows its first frame.

## 7. A list in a popover or panel can drag its scrollbar thumb

**Why:** `scroll.tryPressScrollbar` ignored a press on a scroll box's track whenever the node under the pointer was interactive, to let a control flush against the box's edge take its own click. A popover's panel is interactive and holds its list, so the list's thumb never dragged (Lax's font picker).

**What:** `scroll.zig`: the press is only left to the node under the pointer when that node is not an ancestor of the scroll box (`isInside`): a control in the box, or an unrelated overlay, still wins; a panel that contains the box does not.
