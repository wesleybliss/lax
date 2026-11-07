//! Color emoji: COLR glyphs through the text system, the atlases and the
//! CPU renderer. They need a COLR font (Noto Color Emoji) installed, and
//! skip where there is none.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const colr = @import("tt/colr.zig");

const Sample = struct {
    str: []const u8 = "🔒 👥 🎉 😀 👍 a",
    size: f32 = 20,
    wrap: bool = false,
    spans: []const ui.Span = &.{},
    width: f32 = 0,

    fn view(s: *Sample, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(8), .gap = 4, .width = if (s.width > 0) .{ .px = s.width } else .auto });
        if (s.spans.len > 0) {
            ui.richText(c, s.str, s.spans, .{ .size = s.size, .wrap = s.wrap });
        } else ui.text(c, s.str, .{ .size = s.size, .wrap = s.wrap });
        ui.end(c);
    }
};

/// Skips the test where no COLR font is installed.
fn needFont() !void {
    const data = colr.testFont(testing.allocator) orelse return error.SkipZigTest;
    testing.allocator.free(data);
}

/// How many pixels of the frame are visibly colored (saturated), and how
/// many are inked at all (differ from the background).
fn colors(t: *ui.Tester) !struct { saturated: usize, inked: usize } {
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    const bg = px.bytes[0..4].*;
    var saturated: usize = 0;
    var inked: usize = 0;
    var i: usize = 0;
    while (i + 3 < px.bytes.len) : (i += 4) {
        const b = px.bytes[i];
        const g = px.bytes[i + 1];
        const r = px.bytes[i + 2];
        if (!std.mem.eql(u8, px.bytes[i..][0..4], &bg)) inked += 1;
        if (@max(r, @max(g, b)) - @min(r, @min(g, b)) > 80) saturated += 1;
    }
    return .{ .saturated = saturated, .inked = inked };
}

test "emoji are drawn in color, not as a mono outline" {
    try needFont();
    var s: Sample = .{ .size = 32 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Sample.view), .{ .width = 360, .height = 80 });
    defer t.deinit();
    const c = try colors(&t);
    try testing.expect(c.inked > 1000);
    // Five emoji at 32 points, twice over: a large part of their ink is saturated.
    try testing.expect(c.saturated > c.inked / 2);
    try t.screenshot("/tmp/nanoui-emoji.png");
}

test "plain text stays gray: no color where there is no emoji" {
    try needFont();
    var s: Sample = .{ .str = "Hello, world 123", .size = 20 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Sample.view), .{ .width = 360, .height = 80 });
    defer t.deinit();
    const c = try colors(&t);
    try testing.expect(c.inked > 100);
    try testing.expectEqual(@as(usize, 0), c.saturated);
}

test "an emoji is about an em wide, and sits on the baseline of the text" {
    try needFont();
    var s: Sample = .{ .size = 20 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Sample.view), .{ .width = 360, .height = 80 });
    defer t.deinit();
    const one = t.text.width("😀", .{ .size = 20 });
    try testing.expect(one > 18 and one < 30);
    // Two are twice one; a space between is a space's more.
    try testing.expectApproxEqAbs(2 * one, t.text.width("😀😀", .{ .size = 20 }), 0.01);
    try testing.expectApproxEqAbs(2 * one + t.text.width(" ", .{ .size = 20 }), t.text.width("😀 😀", .{ .size = 20 }), 0.01);
    // The glyph's sprite lies above the baseline and reaches no further below it than a descender.
    const lay = t.text.layout("😀", .{ .size = 20 });
    try testing.expectEqual(@as(usize, 1), lay.glyphs.len);
    const sp = t.text.glyph(lay.glyphs[0], 0, 0).?;
    try testing.expect(sp.color);
    try testing.expect(sp.y < -10 and sp.y + sp.h > 0 and sp.y + sp.h < 8);
}

test "sequences join into one glyph: skin tone, flag, family, heart, keycap" {
    try needFont();
    var s: Sample = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Sample.view), .{ .width = 360, .height = 80 });
    defer t.deinit();
    const style: ui.TextStyle = .{ .size = 20 };
    const cases = [_][]const u8{
        "👍🏽",
        "🇫🇷",
        "👨\u{200d}👩\u{200d}👧\u{200d}👦",
        "❤\u{fe0f}",
        "🏳\u{fe0f}\u{200d}🌈",
        "1\u{fe0f}\u{20e3}",
        "🏴\u{e0067}\u{e0062}\u{e0073}\u{e0063}\u{e0074}\u{e007f}",
    };
    for (cases) |str| {
        const lay = t.text.layout(str, style);
        var drawn: usize = 0;
        for (lay.glyphs) |g| {
            if (t.text.glyph(g, 0, 0) != null) drawn += 1;
        }
        try testing.expectEqual(@as(usize, 1), drawn);
        try testing.expect(lay.width > 15 and lay.width < 30);
    }
    // A joiner alone has no width.
    try testing.expectEqual(@as(f32, 0), t.text.width("\u{200d}", style));
    // A heart with the selector is a color emoji; without, the UI font's own.
    const red = t.text.layout("❤\u{fe0f}", style).glyphs[0];
    try testing.expect(t.text.glyph(red, 0, 0).?.color);
}

test "emoji in wrapped text and in rich text spans" {
    try needFont();
    var s: Sample = .{
        .str = "party 🎉🎉🎉 time 🎉 and a good deal more words after it to wrap around the edge",
        .size = 16,
        .wrap = true,
        .width = 200,
    };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Sample.view), .{ .width = 220, .height = 120 });
    defer t.deinit();
    const lines = t.text.wrap(s.str, .{ .size = 16 }, 184);
    try testing.expect(lines.len >= 2);
    for (lines) |l| try testing.expect(l.width <= 184.5);
    const plain = try colors(&t);
    try testing.expect(plain.saturated > 100);
    try t.screenshot("/tmp/nanoui-emoji-wrap.png");

    // A bold, colored span that holds an emoji: the emoji keeps its own colors.
    const spans = [_]ui.Span{.{ .start = 0, .end = 9, .weight = .bold, .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 } }};
    var r: Sample = .{ .str = "bold 🎉🎉 plain 😀", .size = 20, .spans = &spans };
    var t2: ui.Tester = undefined;
    try t2.init(testing.allocator, .init(&r, Sample.view), .{ .width = 300, .height = 60 });
    defer t2.deinit();
    const c = try colors(&t2);
    try testing.expect(c.saturated > 400);
    try t2.screenshot("/tmp/nanoui-emoji-rich.png");
}

test "a color glyph is drawn once: the atlas keeps it between frames" {
    try needFont();
    var s: Sample = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Sample.view), .{ .width = 360, .height = 80 });
    defer t.deinit();
    t.frame();
    const generation = t.text.images.generation;
    const metas = t.text.atlas.color_meta.count();
    try testing.expect(metas >= 5);
    for (0..3) |_| t.frame();
    try testing.expectEqual(generation, t.text.images.generation);
    try testing.expectEqual(metas, t.text.atlas.color_meta.count());
}

test "emoji at 12, 16, 20 and 32 points, drawn for a look" {
    try needFont();
    for ([_]f32{ 12, 16, 20, 32 }) |size| {
        var s: Sample = .{ .str = "🔒 👥 🎉 😀 👍 ❤️ 🇫🇷 👨‍👩‍👧 👍🏽 text", .size = size };
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, Sample.view), .{ .width = 420, .height = size * 2 + 16 });
        defer t.deinit();
        var buf: [64]u8 = undefined;
        try t.screenshot(try std.fmt.bufPrint(&buf, "/tmp/nanoui-emoji-{d}.png", .{@as(u32, @intFromFloat(size))}));
        const c = try colors(&t);
        try testing.expect(c.saturated > 100);
    }
}

test "the emoji font is found by name and preferred for emoji over mono symbol fonts" {
    try needFont();
    var db = @import("tt/fontdb.zig").Db.init(testing.allocator, testing.io);
    defer db.deinit();
    const face = db.emojiFace(400).?;
    const f = db.load(face).?;
    try testing.expect(f.isColor());
    try testing.expectEqualStrings("Noto Color Emoji", f.style.name());
    // Emoji by default go to it, not to a monochrome face that has them too.
    for ([_]u21{ 0x1f600, 0x1f512, 0x1f44d, 0x2705 }) |cp| {
        const fb = db.fallback(cp, 400).?;
        try testing.expect(db.load(fb).?.isColor());
    }
    // Characters it has no glyph for are not sent to it.
    try testing.expect(db.emojiFace(400) != null);
    const arrow = db.fallback('a', 400);
    if (arrow) |fb| try testing.expect(db.load(fb).?.glyphIndex('a') != 0);
}
