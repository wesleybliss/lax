//! Which characters are emoji, and where an emoji sequence ends: a flag
//! (two regional indicators), a base with a variation selector, a skin
//! tone, a keycap or tag characters, joined by zero width joiners.
const std = @import("std");

pub const zwj: u21 = 0x200d;
pub const vs15: u21 = 0xfe0e;
pub const vs16: u21 = 0xfe0f;
pub const keycap: u21 = 0x20e3;

/// Characters drawn as emoji unless asked for text (Emoji_Presentation),
/// as ranges in order.
const presentation_ranges = [_][2]u21{
    .{ 0x231a, 0x231b },   .{ 0x23e9, 0x23ec },   .{ 0x23f0, 0x23f0 },   .{ 0x23f3, 0x23f3 },
    .{ 0x25fd, 0x25fe },   .{ 0x2614, 0x2615 },   .{ 0x2648, 0x2653 },   .{ 0x267f, 0x267f },
    .{ 0x2693, 0x2693 },   .{ 0x26a1, 0x26a1 },   .{ 0x26aa, 0x26ab },   .{ 0x26bd, 0x26be },
    .{ 0x26c4, 0x26c5 },   .{ 0x26ce, 0x26ce },   .{ 0x26d4, 0x26d4 },   .{ 0x26ea, 0x26ea },
    .{ 0x26f2, 0x26f3 },   .{ 0x26f5, 0x26f5 },   .{ 0x26fa, 0x26fa },   .{ 0x26fd, 0x26fd },
    .{ 0x2705, 0x2705 },   .{ 0x270a, 0x270b },   .{ 0x2728, 0x2728 },   .{ 0x274c, 0x274c },
    .{ 0x274e, 0x274e },   .{ 0x2753, 0x2755 },   .{ 0x2757, 0x2757 },   .{ 0x2795, 0x2797 },
    .{ 0x27b0, 0x27b0 },   .{ 0x27bf, 0x27bf },   .{ 0x2b1b, 0x2b1c },   .{ 0x2b50, 0x2b50 },
    .{ 0x2b55, 0x2b55 },   .{ 0x1f004, 0x1f004 }, .{ 0x1f0cf, 0x1f0cf }, .{ 0x1f18e, 0x1f18e },
    .{ 0x1f191, 0x1f19a }, .{ 0x1f1e6, 0x1f1ff }, .{ 0x1f201, 0x1f201 }, .{ 0x1f21a, 0x1f21a },
    .{ 0x1f22f, 0x1f22f }, .{ 0x1f232, 0x1f236 }, .{ 0x1f238, 0x1f23a }, .{ 0x1f250, 0x1f251 },
    .{ 0x1f300, 0x1f320 }, .{ 0x1f32d, 0x1f335 }, .{ 0x1f337, 0x1f37c }, .{ 0x1f37e, 0x1f393 },
    .{ 0x1f3a0, 0x1f3ca }, .{ 0x1f3cf, 0x1f3d3 }, .{ 0x1f3e0, 0x1f3f0 }, .{ 0x1f3f4, 0x1f3f4 },
    .{ 0x1f3f8, 0x1f43e }, .{ 0x1f440, 0x1f440 }, .{ 0x1f442, 0x1f4fc }, .{ 0x1f4ff, 0x1f53d },
    .{ 0x1f54b, 0x1f54e }, .{ 0x1f550, 0x1f567 }, .{ 0x1f57a, 0x1f57a }, .{ 0x1f595, 0x1f596 },
    .{ 0x1f5a4, 0x1f5a4 }, .{ 0x1f5fb, 0x1f64f }, .{ 0x1f680, 0x1f6c5 }, .{ 0x1f6cc, 0x1f6cc },
    .{ 0x1f6d0, 0x1f6d2 }, .{ 0x1f6d5, 0x1f6d7 }, .{ 0x1f6dc, 0x1f6df }, .{ 0x1f6eb, 0x1f6ec },
    .{ 0x1f6f4, 0x1f6fc }, .{ 0x1f7e0, 0x1f7eb }, .{ 0x1f7f0, 0x1f7f0 }, .{ 0x1f90c, 0x1f93a },
    .{ 0x1f93c, 0x1f945 }, .{ 0x1f947, 0x1f9ff }, .{ 0x1fa70, 0x1fa7c }, .{ 0x1fa80, 0x1fa88 },
    .{ 0x1fa90, 0x1fabd }, .{ 0x1fabf, 0x1fac5 }, .{ 0x1face, 0x1fadb }, .{ 0x1fae0, 0x1fae8 },
    .{ 0x1faf0, 0x1faf8 },
};

pub fn presentation(cp: u21) bool {
    if (cp < 0x231a) return false;
    var lo: usize = 0;
    var hi: usize = presentation_ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const r = presentation_ranges[mid];
        if (cp < r[0]) hi = mid else if (cp > r[1]) lo = mid + 1 else return true;
    }
    return false;
}

fn regional(cp: u21) bool {
    return cp >= 0x1f1e6 and cp <= 0x1f1ff;
}

fn modifier(cp: u21) bool {
    return cp >= 0x1f3fb and cp <= 0x1f3ff;
}

fn tagChar(cp: u21) bool {
    return cp >= 0xe0020 and cp <= 0xe007f;
}

pub const max = 24;

pub const Cluster = struct {
    /// Its length in bytes, and its characters.
    bytes: usize,
    n: usize,
};

const Next = struct { cp: u21, len: usize };

fn isSelector(cp: u21) bool {
    return cp == vs16 or cp == vs15;
}

fn isKeycap(cp: u21) bool {
    return cp == keycap;
}

/// Characters taken from `s` while they suit, into `cps`.
const Take = struct {
    s: []const u8,
    cps: *[max]u21,
    n: usize,
    pos: usize,

    fn one(t: *Take, suits: *const fn (u21) bool) bool {
        const x = next(t.s, t.pos) orelse return false;
        if (!suits(x.cp) or t.n >= max) return false;
        t.cps[t.n] = x.cp;
        t.n += 1;
        t.pos += x.len;
        return true;
    }
};

fn next(s: []const u8, at: usize) ?Next {
    if (at >= s.len) return null;
    const want = std.unicode.utf8ByteSequenceLength(s[at]) catch return null;
    if (at + want > s.len) return null;
    const cp = std.unicode.utf8Decode(s[at..][0..want]) catch return null;
    return .{ .cp = cp, .len = want };
}

/// The emoji sequence `s` starts with, its characters put in `cps`; null
/// when it starts with none. A character that is emoji only when a variation
/// selector follows it (or a keycap, for digits) starts one only then.
pub fn cluster(s: []const u8, cps: *[max]u21) ?Cluster {
    const first = next(s, 0) orelse return null;
    const c0 = first.cp;
    const second = next(s, first.len);
    const digit = (c0 >= '0' and c0 <= '9') or c0 == '#' or c0 == '*';
    const asked = if (second) |x| x.cp == vs16 or (digit and x.cp == keycap) else false;
    if (!presentation(c0) and !asked) return null;
    cps[0] = c0;
    var n: usize = 1;
    var pos = first.len;
    if (regional(c0)) {
        if (second) |x| if (regional(x.cp)) {
            cps[1] = x.cp;
            return .{ .bytes = pos + x.len, .n = 2 };
        };
        return .{ .bytes = pos, .n = 1 };
    }
    while (true) {
        // What may follow a base: a selector, a skin tone, a keycap, tags.
        var st: Take = .{ .s = s, .cps = cps, .n = n, .pos = pos };
        _ = st.one(isSelector);
        _ = st.one(modifier);
        _ = st.one(isKeycap);
        while (st.one(tagChar)) {}
        n = st.n;
        pos = st.pos;
        // Joined to the next, when a symbol or emoji follows the joiner.
        const joiner = next(s, pos) orelse break;
        if (joiner.cp != zwj) break;
        const after = next(s, pos + joiner.len) orelse break;
        if (after.cp < 0x2190 or n + 2 > max) break;
        cps[n] = zwj;
        cps[n + 1] = after.cp;
        n += 2;
        pos += joiner.len + after.len;
    }
    return .{ .bytes = pos, .n = n };
}

test "emoji sequences" {
    var cps: [max]u21 = undefined;
    // A plain emoji, then the text after it.
    var c = cluster("😀 x", &cps).?;
    try std.testing.expectEqual(@as(usize, 4), c.bytes);
    try std.testing.expectEqual(@as(usize, 1), c.n);
    try std.testing.expect(cluster("x😀", &cps) == null);
    try std.testing.expect(cluster("1", &cps) == null);
    // A flag: two regional indicators; a third starts the next flag.
    c = cluster("🇺🇸🇫", &cps).?;
    try std.testing.expectEqual(@as(usize, 8), c.bytes);
    // A skin tone, a variation selector, a ZWJ family, a keycap, a tag flag.
    c = cluster("👍🏽", &cps).?;
    try std.testing.expectEqual(@as(usize, 2), c.n);
    c = cluster("❤\u{fe0f}", &cps).?;
    try std.testing.expectEqual(@as(usize, 2), c.n);
    try std.testing.expect(cluster("❤", &cps) == null);
    c = cluster("👨\u{200d}👩\u{200d}👧!", &cps).?;
    try std.testing.expectEqual(@as(usize, 5), c.n);
    c = cluster("1\u{fe0f}\u{20e3}", &cps).?;
    try std.testing.expectEqual(@as(usize, 3), c.n);
    c = cluster("🏴\u{e0067}\u{e0062}\u{e0065}\u{e006e}\u{e0067}\u{e007f}", &cps).?;
    try std.testing.expectEqual(@as(usize, 7), c.n);
    // A joiner with nothing after it is left alone.
    c = cluster("👨\u{200d}", &cps).?;
    try std.testing.expectEqual(@as(usize, 1), c.n);
}
