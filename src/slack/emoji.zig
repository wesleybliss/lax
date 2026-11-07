//! Slack emoji shortcodes to Unicode. The table is generated from
//! iamcal/emoji-data v16.0.0 (MIT, Copyright (c) 2013 Cal Henderson), the
//! same set Slack's web client bundles: see THIRD_PARTY_NOTICES.md.
const std = @import("std");

pub const Entry = struct { name: []const u8, glyph: []const u8 };

/// Sorted by name
pub const entries: []const Entry = blk: {
    @setEvalBranchQuota(4_000_000);
    const text = @embedFile("emoji_table.tsv");
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    var out: [count]Entry = undefined;
    var i: usize = 0;
    lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t').?;
        out[i] = .{ .name = line[0..tab], .glyph = line[tab + 1 ..] };
        i += 1;
    }
    const final = out;
    break :blk &final;
};

fn nameLess(_: void, a: Entry, b: []const u8) std.math.Order {
    return std.mem.order(u8, b, a.name).invert();
}

/// The glyph for an exact shortcode name (no colons, no skin tone)
pub fn lookup(name: []const u8) ?[]const u8 {
    const i = std.sort.binarySearch(Entry, entries, name, struct {
        fn order(key: []const u8, e: Entry) std.math.Order {
            return std.mem.order(u8, key, e.name);
        }
    }.order) orelse return null;
    return entries[i].glyph;
}

/// Fitzpatrick modifier for Slack's `skin-tone-N` (N from 2 to 6)
pub fn toneModifier(tone: u8) ?[]const u8 {
    return switch (tone) {
        2 => "\u{1F3FB}",
        3 => "\u{1F3FC}",
        4 => "\u{1F3FD}",
        5 => "\u{1F3FE}",
        6 => "\u{1F3FF}",
        else => null,
    };
}

/// `glyph` with a skin tone applied after its first codepoint. Writes to
/// `buf` (needs glyph.len + 4 bytes); null if it doesn't fit or the tone
/// is not valid.
pub fn withTone(buf: []u8, glyph: []const u8, tone: u8) ?[]const u8 {
    const modifier = toneModifier(tone) orelse return null;
    if (glyph.len == 0) return null;
    const first = std.unicode.utf8ByteSequenceLength(glyph[0]) catch return null;
    if (first > glyph.len or buf.len < glyph.len + modifier.len) return null;
    @memcpy(buf[0..first], glyph[0..first]);
    @memcpy(buf[first..][0..modifier.len], modifier);
    @memcpy(buf[first + modifier.len ..][0 .. glyph.len - first], glyph[first..]);
    return buf[0 .. glyph.len + modifier.len];
}

/// A reaction name as Slack sends it (`+1`, `+1::skin-tone-3`) to a glyph
/// in `buf` (or a static glyph); null for unknown (custom) emoji
pub fn forReaction(buf: []u8, name: []const u8) ?[]const u8 {
    const marker = "::skin-tone-";
    if (std.mem.indexOf(u8, name, marker)) |i| {
        const base = lookup(name[0..i]) orelse return null;
        const tone = std.fmt.parseInt(u8, name[i + marker.len ..], 10) catch return base;
        return withTone(buf, base, tone) orelse base;
    }
    return lookup(name);
}

/// Names starting with `prefix`, up to `out.len`; returns how many
pub fn search(prefix: []const u8, out: []Entry) usize {
    var n: usize = 0;
    // First index with name >= prefix
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (std.mem.order(u8, entries[mid].name, prefix) == .lt) lo = mid + 1 else hi = mid;
    }
    while (lo < entries.len and n < out.len and std.mem.startsWith(u8, entries[lo].name, prefix)) : (lo += 1) {
        out[n] = entries[lo];
        n += 1;
    }
    return n;
}

test "lookup, tones, reactions, search" {
    try std.testing.expectEqualStrings("🎉", lookup("tada").?);
    try std.testing.expectEqualStrings("👍", lookup("+1").?);
    try std.testing.expect(lookup("definitely_not_an_emoji") == null);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("👍🏽", forReaction(&buf, "+1::skin-tone-4").?);
    try std.testing.expectEqualStrings("🔥", forReaction(&buf, "fire").?);
    try std.testing.expect(forReaction(&buf, "my_custom_emoji") == null);
    var found: [8]Entry = undefined;
    const n = search("thumbs", &found);
    try std.testing.expect(n >= 2);
    try std.testing.expect(std.mem.startsWith(u8, found[0].name, "thumbs"));
}
