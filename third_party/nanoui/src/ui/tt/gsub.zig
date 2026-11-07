//! Glyph substitution, as far as emoji need it: the ligatures of the
//! `ccmp`, `liga` and `rlig` features, which join a ZWJ sequence, a flag,
//! a skin tone or a keycap into the one glyph a color font draws for it.
//! Other lookup kinds (contextual, multiple, single) are skipped.
const std = @import("std");
const font = @import("font.zig");

fn be16(d: []const u8, at: usize) u16 {
    if (at + 2 > d.len) return 0;
    return std.mem.readInt(u16, d[at..][0..2], .big);
}

fn be32(d: []const u8, at: usize) usize {
    if (at + 4 > d.len) return 0;
    return std.mem.readInt(u32, d[at..][0..4], .big);
}

fn tag(s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

/// The index of `g` in a coverage table, null when it is not covered.
fn coverage(d: []const u8, at: usize, g: u16) ?usize {
    const count = be16(d, at + 2);
    var lo: usize = 0;
    var hi: usize = count;
    switch (be16(d, at)) {
        1 => while (lo < hi) {
            const mid = (lo + hi) / 2;
            const v = be16(d, at + 4 + 2 * mid);
            if (g < v) hi = mid else if (g > v) lo = mid + 1 else return mid;
        },
        2 => while (lo < hi) {
            const mid = (lo + hi) / 2;
            const r = at + 4 + 6 * mid;
            if (g < be16(d, r)) hi = mid else if (g > be16(d, r + 2)) lo = mid + 1 else return be16(d, r + 4) + (g - be16(d, r));
        },
        else => {},
    }
    return null;
}

/// Joins the glyphs of `glyphs[0..len]` by the font's ligatures; returns
/// the new length. Within a lookup the first ligature that matches wins.
pub fn ligate(f: *const font.Font, glyphs: []u16, len_in: usize) usize {
    const g = f.t.gsub;
    if (g == 0) return len_in;
    const d = f.data;
    const features = g + be16(d, g + 6);
    const lookups = g + be16(d, g + 8);
    // The lookups of the features wanted, in index order.
    var wanted: [32]u16 = undefined;
    var n: usize = 0;
    for (0..be16(d, features)) |i| {
        const rec = features + 2 + 6 * i;
        const t = be32(d, rec);
        if (t != tag("ccmp") and t != tag("liga") and t != tag("rlig")) continue;
        const ft = features + be16(d, rec + 4);
        for (0..be16(d, ft + 2)) |k| {
            const index = be16(d, ft + 4 + 2 * k);
            if (std.mem.indexOfScalar(u16, wanted[0..n], index) != null or n == wanted.len) continue;
            var at = n;
            while (at > 0 and wanted[at - 1] > index) : (at -= 1) wanted[at] = wanted[at - 1];
            wanted[at] = index;
            n += 1;
        }
    }
    var len = len_in;
    for (wanted[0..n]) |index| {
        const lookup = lookups + be16(d, lookups + 2 + 2 * index);
        const kind = be16(d, lookup);
        for (0..be16(d, lookup + 4)) |s| {
            var sub: usize = lookup + be16(d, lookup + 6 + 2 * s);
            var sub_kind = kind;
            // An extension subtable points at the real one.
            if (kind == 7) {
                sub_kind = be16(d, sub + 2);
                sub += be32(d, sub + 4);
            }
            if (sub_kind == 4 and be16(d, sub) == 1) len = substitute(d, sub, glyphs, len);
        }
    }
    return len;
}

fn substitute(d: []const u8, sub: usize, glyphs: []u16, len_in: usize) usize {
    const cov = sub + be16(d, sub + 2);
    const sets = be16(d, sub + 4);
    var len = len_in;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const ci = coverage(d, cov, glyphs[i]) orelse continue;
        if (ci >= sets) continue;
        const set = sub + be16(d, sub + 6 + 2 * ci);
        for (0..be16(d, set)) |j| {
            const lig = set + be16(d, set + 2 + 2 * j);
            const count: usize = be16(d, lig + 2);
            if (count == 0 or i + count > len) continue;
            var match = true;
            for (1..count) |k| {
                if (be16(d, lig + 4 + 2 * (k - 1)) != glyphs[i + k]) {
                    match = false;
                    break;
                }
            }
            if (!match) continue;
            glyphs[i] = be16(d, lig);
            std.mem.copyForwards(u16, glyphs[i + 1 .. len - (count - 1)], glyphs[i + count .. len]);
            len -= count - 1;
            break;
        }
    }
    return len;
}
