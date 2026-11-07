//! Color glyphs from the `COLR` and `CPAL` tables: version 0 (a glyph is a
//! stack of solid colored outlines) and version 1 (a tree of paints:
//! solids, linear, radial and sweep gradients, outlines that clip what is
//! under them, transforms, nested glyphs, layer stacks and compositing).
//! Each outline is rasterized by `raster.zig` (so coverage is as exact as
//! text's), then colored through its coverage, and the glyph is composited
//! into one premultiplied RGBA bitmap at the size asked. Palette 0 is used.
//! Variable fonts' deltas (the `Var` paints' variation indexes) are not
//! applied: their default values are drawn.
const std = @import("std");
const font = @import("font.zig");
const tt_raster = @import("raster.zig");

fn be16(d: []const u8, at: usize) u16 {
    if (at + 2 > d.len) return 0;
    return std.mem.readInt(u16, d[at..][0..2], .big);
}

fn bei16(d: []const u8, at: usize) f32 {
    return @floatFromInt(@as(i16, @bitCast(be16(d, at))));
}

fn be24(d: []const u8, at: usize) usize {
    if (at + 3 > d.len) return 0;
    return (@as(usize, d[at]) << 16) | (@as(usize, d[at + 1]) << 8) | d[at + 2];
}

fn be32(d: []const u8, at: usize) usize {
    if (at + 4 > d.len) return 0;
    return std.mem.readInt(u32, d[at..][0..4], .big);
}

/// A 2.14 fixed point number.
fn f2dot14(d: []const u8, at: usize) f32 {
    return bei16(d, at) / 16384;
}

/// A 16.16 fixed point number.
fn fixed(d: []const u8, at: usize) f32 {
    return @as(f32, @floatFromInt(@as(i32, @bitCast(@as(u32, @intCast(be32(d, at))))))) / 65536;
}

/// x' = a x + c y + e, y' = b x + d y + f.
const Affine = [6]f32;

const identity: Affine = .{ 1, 0, 0, 1, 0, 0 };

/// `a` after `b`: points go through `b` first.
fn mul(a: Affine, b: Affine) Affine {
    return .{
        a[0] * b[0] + a[2] * b[1],
        a[1] * b[0] + a[3] * b[1],
        a[0] * b[2] + a[2] * b[3],
        a[1] * b[2] + a[3] * b[3],
        a[0] * b[4] + a[2] * b[5] + a[4],
        a[1] * b[4] + a[3] * b[5] + a[5],
    };
}

fn invert(m: Affine) ?Affine {
    const det = m[0] * m[3] - m[1] * m[2];
    if (@abs(det) < 1e-12) return null;
    const k = 1 / det;
    return .{
        m[3] * k,
        -m[1] * k,
        -m[2] * k,
        m[0] * k,
        (m[2] * m[5] - m[3] * m[4]) * k,
        (m[1] * m[4] - m[0] * m[5]) * k,
    };
}

fn translation(x: f32, y: f32) Affine {
    return .{ 1, 0, 0, 1, x, y };
}

/// A transform applied about the point (`cx`, `cy`).
fn about(local: Affine, cx: f32, cy: f32) Affine {
    return mul(mul(translation(cx, cy), local), translation(-cx, -cy));
}

/// The tables of a font that has color glyphs, read in place.
pub const Table = struct {
    d: []const u8,
    cpal: usize,
    /// Version 0: base glyph records and layer records.
    num_base: usize,
    base_recs: usize,
    layer_recs: usize,
    /// Version 1 (0 when absent): the lists, as absolute offsets.
    base_list: usize = 0,
    layer_list: usize = 0,
    clip_list: usize = 0,

    pub fn init(f: *const font.Font) ?Table {
        if (!f.isColor()) return null;
        const d = f.data;
        const c: usize = f.t.colr;
        if (c + 14 > d.len) return null;
        var t: Table = .{
            .d = d,
            .cpal = f.t.cpal,
            .num_base = be16(d, c + 2),
            .base_recs = c + be32(d, c + 4),
            .layer_recs = c + be32(d, c + 8),
        };
        if (be16(d, c) >= 1 and c + 34 <= d.len) {
            if (be32(d, c + 14) != 0) t.base_list = c + be32(d, c + 14);
            if (be32(d, c + 18) != 0) t.layer_list = c + be32(d, c + 18);
            if (be32(d, c + 22) != 0) t.clip_list = c + be32(d, c + 22);
        }
        return t;
    }

    /// The paint of glyph `g`, version 1: its offset.
    fn paintOf(t: Table, g: u16) ?usize {
        if (t.base_list == 0) return null;
        const d = t.d;
        var lo: usize = 0;
        var hi: usize = be32(d, t.base_list);
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const rec = t.base_list + 4 + 6 * mid;
            const id = be16(d, rec);
            if (g < id) hi = mid else if (g > id) lo = mid + 1 else return t.base_list + be32(d, rec + 2);
        }
        return null;
    }

    /// The layers of glyph `g`, version 0: the first one's index and how many.
    fn layersOf(t: Table, g: u16) ?[2]usize {
        const d = t.d;
        var lo: usize = 0;
        var hi: usize = t.num_base;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const rec = t.base_recs + 6 * mid;
            const id = be16(d, rec);
            if (g < id) hi = mid else if (g > id) lo = mid + 1 else return .{ be16(d, rec + 2), be16(d, rec + 4) };
        }
        return null;
    }

    /// Whether glyph `g` is drawn in color.
    pub fn has(t: Table, g: u16) bool {
        return t.paintOf(g) != null or t.layersOf(g) != null;
    }

    /// Where glyph `g` is drawn, in font units: x0, y0, x1, y1.
    fn clipBox(t: Table, g: u16) ?[4]f32 {
        if (t.clip_list == 0) return null;
        const d = t.d;
        const n = be32(d, t.clip_list + 1);
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const rec = t.clip_list + 5 + 7 * mid;
            if (g < be16(d, rec)) hi = mid else if (g > be16(d, rec + 2)) lo = mid + 1 else {
                const box = t.clip_list + be24(d, rec + 4);
                return .{ bei16(d, box + 1), bei16(d, box + 3), bei16(d, box + 5), bei16(d, box + 7) };
            }
        }
        return null;
    }

    /// Entry `index` of palette 0: straight RGBA.
    fn color(t: Table, index: u16, fg: [4]f32) [4]f32 {
        if (index == 0xffff) return fg;
        const d = t.d;
        if (index >= be16(d, t.cpal + 2)) return .{ 0, 0, 0, 0 };
        const rec = t.cpal + be32(d, t.cpal + 8) + 4 * (@as(usize, be16(d, t.cpal + 12)) + index);
        if (rec + 4 > d.len) return .{ 0, 0, 0, 0 };
        return .{
            @as(f32, @floatFromInt(d[rec + 2])) / 255,
            @as(f32, @floatFromInt(d[rec + 1])) / 255,
            @as(f32, @floatFromInt(d[rec])) / 255,
            @as(f32, @floatFromInt(d[rec + 3])) / 255,
        };
    }
};

/// A glyph drawn: premultiplied BGRA, `w` × `h`, its top left corner `left`
/// pixels right of the pen and `top` above the baseline.
pub const Bitmap = struct {
    left: i32,
    top: i32,
    w: u32,
    h: u32,
    bgra: []u8,
};

/// The most a bitmap may be on a side, in pixels.
const max_side = 1024;

/// Glyph `g` of `f` drawn in color at `ps` pixels per font unit, with `pad`
/// clear pixels round it; null when it is not a color glyph or draws nothing.
pub fn render(gpa: std.mem.Allocator, f: *const font.Font, g: u16, ps: f32, pad: u32) !?Bitmap {
    const t = Table.init(f) orelse return null;
    const v1 = t.paintOf(g);
    const v0 = if (v1 == null) t.layersOf(g) else null;
    if (v1 == null and v0 == null) return null;
    const box = t.clipBox(g) orelse extent(f, t, g, v0);
    const x0 = @floor(box[0] * ps);
    const top = @ceil(box[3] * ps);
    const w_f = @ceil(box[2] * ps) - x0 + @as(f32, @floatFromInt(2 * pad));
    const h_f = top - @floor(box[1] * ps) + @as(f32, @floatFromInt(2 * pad));
    if (!(w_f >= 1 and h_f >= 1 and w_f <= max_side and h_f <= max_side)) return null;
    const w: usize = @intFromFloat(w_f);
    const h: usize = @intFromFloat(h_f);
    const p: f32 = @floatFromInt(pad);
    var painter: Painter = .{ .gpa = gpa, .f = f, .t = t, .w = w, .h = h, .raster = try tt_raster.Raster.init(gpa, w, h) };
    defer painter.raster.deinit(gpa);
    const layer = try gpa.alloc(f32, w * h * 4);
    defer gpa.free(layer);
    @memset(layer, 0);
    const m: Affine = .{ ps, 0, 0, -ps, p - x0, top + p };
    if (v1) |po| {
        try painter.paint(po, m, null, layer, 0);
    } else if (v0) |r| try painter.paintV0(r, m, layer);
    const out = try gpa.alloc(u8, w * h * 4);
    errdefer gpa.free(out);
    var any = false;
    for (0..w * h) |i| {
        const px = layer[i * 4 ..][0..4];
        any = any or px[3] > 0;
        out[i * 4] = unit(px[2]);
        out[i * 4 + 1] = unit(px[1]);
        out[i * 4 + 2] = unit(px[0]);
        out[i * 4 + 3] = unit(px[3]);
    }
    if (!any) {
        gpa.free(out);
        return null;
    }
    return .{ .left = @as(i32, @intFromFloat(x0)) - @as(i32, @intCast(pad)), .top = @as(i32, @intFromFloat(top)) + @as(i32, @intCast(pad)), .w = @intCast(w), .h = @intCast(h), .bgra = out };
}

fn unit(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0, 1) * 255 + 0.5);
}

/// Where a glyph with no clip box draws: its layers' outlines (version 0),
/// else the em box with the font's ascent and descent.
fn extent(f: *const font.Font, t: Table, g: u16, v0: ?[2]usize) [4]f32 {
    if (v0) |r| {
        var box: [4]f32 = .{ 1e9, 1e9, -1e9, -1e9 };
        for (0..r[1]) |k| {
            const rec = t.layer_recs + 4 * (r[0] + k);
            const b = f.bounds(be16(t.d, rec)) orelse continue;
            box = .{ @min(box[0], b[0]), @min(box[1], b[1]), @max(box[2], b[2]), @max(box[3], b[3]) };
        }
        if (box[0] <= box[2]) return box;
    }
    return .{ 0, -f.descent, @max(f.advance(g), f.units_per_em), f.ascent };
}

/// Where a paint may draw: coverage, and the rows and columns it touches.
const Mask = struct {
    cov: []u8,
    x0: usize,
    y0: usize,
    x1: usize,
    y1: usize,
};

const Stop = struct { t: f32, c: [4]f32 };

/// A gradient's colors along its line, as a color line gives them.
const Line = struct {
    stops: [32]Stop = undefined,
    n: usize = 0,
    extend: u8 = 0,

    fn read(p: *const Painter, start: usize, is_var: bool) ?Line {
        const d = p.t.d;
        var l: Line = .{ .extend = if (start < d.len) d[start] else 0 };
        const count = be16(d, start + 1);
        const stride: usize = if (is_var) 10 else 6;
        for (0..@min(count, l.stops.len)) |i| {
            const s = start + 3 + stride * i;
            if (s + 6 > d.len) break;
            var c = p.t.color(be16(d, s + 2), p.fg);
            c[3] *= f2dot14(d, s + 4);
            l.stops[l.n] = .{ .t = f2dot14(d, s), .c = c };
            l.n += 1;
        }
        if (l.n == 0) return null;
        // Sorted by offset, keeping the order of equal ones.
        for (1..l.n) |i| {
            var j = i;
            while (j > 0 and l.stops[j - 1].t > l.stops[j].t) : (j -= 1) std.mem.swap(Stop, &l.stops[j - 1], &l.stops[j]);
        }
        return l;
    }

    fn premultiplied(c: [4]f32) [4]f32 {
        return .{ c[0] * c[3], c[1] * c[3], c[2] * c[3], c[3] };
    }

    /// The color at `t0` along the line, premultiplied, its ends extended.
    fn at(l: *const Line, t0: f32) [4]f32 {
        const lo = l.stops[0].t;
        const hi = l.stops[l.n - 1].t;
        var t = t0;
        if (hi > lo) {
            var u = (t - lo) / (hi - lo);
            switch (l.extend) {
                1 => u -= @floor(u),
                2 => {
                    const v = @mod(u, 2);
                    u = if (v > 1) 2 - v else v;
                },
                else => {},
            }
            t = lo + u * (hi - lo);
        }
        if (t <= lo) return premultiplied(l.stops[0].c);
        for (1..l.n) |i| {
            const a = l.stops[i - 1];
            const b = l.stops[i];
            if (t > b.t) continue;
            const k = if (b.t > a.t) (t - a.t) / (b.t - a.t) else 1;
            var c: [4]f32 = undefined;
            for (&c, a.c, b.c) |*o, x, y| o.* = x + (y - x) * k;
            return premultiplied(c);
        }
        return premultiplied(l.stops[l.n - 1].c);
    }
};

const Painter = struct {
    gpa: std.mem.Allocator,
    f: *const font.Font,
    t: Table,
    w: usize,
    h: usize,
    raster: tt_raster.Raster,
    /// What `0xffff` palette entries are: the text's color, black here.
    fg: [4]f32 = .{ 0, 0, 0, 1 },
    /// Paints visited, to end a malformed or cyclic tree.
    visits: u32 = 0,

    const Error = error{OutOfMemory};

    /// Version 0: each layer's outline in its solid color, bottom first.
    fn paintV0(p: *Painter, r: [2]usize, m: Affine, dst: []f32) Error!void {
        for (0..r[1]) |k| {
            const rec = p.t.layer_recs + 4 * (r[0] + k);
            const mask = try p.outlineMask(be16(p.t.d, rec), m, null) orelse continue;
            defer p.gpa.free(mask.cov);
            p.fill(dst, &mask, Solid{ .c = Line.premultiplied(p.t.color(be16(p.t.d, rec + 2), p.fg)) });
        }
    }

    fn paint(p: *Painter, off: usize, m: Affine, clip: ?*const Mask, dst: []f32, depth: u8) Error!void {
        const d = p.t.d;
        if (depth > 24 or p.visits > 100_000 or off >= d.len) return;
        p.visits += 1;
        const format = d[off];
        const child = off + be24(d, off + 1);
        switch (format) {
            1 => {
                if (p.t.layer_list == 0) return;
                const first = be32(d, off + 2);
                const total = be32(d, p.t.layer_list);
                for (0..d[off + 1]) |k| {
                    if (first + k >= total) return;
                    try p.paint(p.t.layer_list + be32(d, p.t.layer_list + 4 + 4 * (first + k)), m, clip, dst, depth + 1);
                }
            },
            2, 3 => {
                var c = p.t.color(be16(d, off + 1), p.fg);
                c[3] *= f2dot14(d, off + 3);
                p.fill(dst, clip, Solid{ .c = Line.premultiplied(c) });
            },
            4, 5 => try p.linear(off, m, clip, dst),
            6, 7 => try p.radial(off, m, clip, dst),
            8, 9 => try p.sweep(off, m, clip, dst),
            10 => {
                const mask = try p.outlineMask(be16(d, off + 4), m, clip) orelse return;
                defer p.gpa.free(mask.cov);
                try p.paint(child, m, &mask, dst, depth + 1);
            },
            11 => if (p.t.paintOf(be16(d, off + 1))) |po| try p.paint(po, m, clip, dst, depth + 1),
            12, 13 => {
                const a = off + be24(d, off + 4);
                try p.paint(child, mul(m, .{ fixed(d, a), fixed(d, a + 4), fixed(d, a + 8), fixed(d, a + 12), fixed(d, a + 16), fixed(d, a + 20) }), clip, dst, depth + 1);
            },
            14, 15 => try p.paint(child, mul(m, translation(bei16(d, off + 4), bei16(d, off + 6))), clip, dst, depth + 1),
            16, 17 => try p.paint(child, mul(m, .{ f2dot14(d, off + 4), 0, 0, f2dot14(d, off + 6), 0, 0 }), clip, dst, depth + 1),
            18, 19 => {
                const s: Affine = .{ f2dot14(d, off + 4), 0, 0, f2dot14(d, off + 6), 0, 0 };
                try p.paint(child, mul(m, about(s, bei16(d, off + 8), bei16(d, off + 10))), clip, dst, depth + 1);
            },
            20, 21 => {
                const k = f2dot14(d, off + 4);
                try p.paint(child, mul(m, .{ k, 0, 0, k, 0, 0 }), clip, dst, depth + 1);
            },
            22, 23 => {
                const k = f2dot14(d, off + 4);
                try p.paint(child, mul(m, about(.{ k, 0, 0, k, 0, 0 }, bei16(d, off + 6), bei16(d, off + 8))), clip, dst, depth + 1);
            },
            24, 25 => try p.paint(child, mul(m, rotation(f2dot14(d, off + 4))), clip, dst, depth + 1),
            26, 27 => try p.paint(child, mul(m, about(rotation(f2dot14(d, off + 4)), bei16(d, off + 6), bei16(d, off + 8))), clip, dst, depth + 1),
            28, 29 => try p.paint(child, mul(m, skew(f2dot14(d, off + 4), f2dot14(d, off + 6))), clip, dst, depth + 1),
            30, 31 => try p.paint(child, mul(m, about(skew(f2dot14(d, off + 4), f2dot14(d, off + 6)), bei16(d, off + 8), bei16(d, off + 10))), clip, dst, depth + 1),
            32 => try p.composite(off, m, clip, dst, depth),
            else => {},
        }
    }

    /// A source over a backdrop by a compositing mode, each drawn alone
    /// first, then the result laid over `dst` through the clip.
    fn composite(p: *Painter, off: usize, m: Affine, clip: ?*const Mask, dst: []f32, depth: u8) Error!void {
        const d = p.t.d;
        const src = try p.gpa.alloc(f32, dst.len);
        defer p.gpa.free(src);
        const back = try p.gpa.alloc(f32, dst.len);
        defer p.gpa.free(back);
        @memset(src, 0);
        @memset(back, 0);
        try p.paint(off + be24(d, off + 5), m, null, back, depth + 1);
        try p.paint(off + be24(d, off + 1), m, null, src, depth + 1);
        const mode = d[off + 4];
        for (0..p.w * p.h) |i| {
            const s = src[i * 4 ..][0..4];
            const b = back[i * 4 ..][0..4];
            b.* = compositePixel(mode, s.*, b.*);
        }
        p.fill(dst, clip, Layer{ .px = back });
    }

    /// `outline` of glyph `g` through `m`, as coverage inside `clip`; null when it covers nothing.
    fn outlineMask(p: *Painter, g: u16, m: Affine, clip: ?*const Mask) Error!?Mask {
        const cov = try p.gpa.alloc(u8, p.w * p.h);
        errdefer p.gpa.free(cov);
        @memset(p.raster.acc, 0);
        p.f.outline(g, m, p.raster.sink());
        p.raster.coverage(cov);
        var mask: Mask = .{ .cov = cov, .x0 = p.w, .y0 = p.h, .x1 = 0, .y1 = 0 };
        const r = bounds(p, clip);
        for (r.y0..r.y1) |y| for (r.x0..r.x1) |x| {
            const i = y * p.w + x;
            if (clip) |c| cov[i] = @intCast((@as(u32, cov[i]) * c.cov[i] + 127) / 255);
            if (cov[i] == 0) continue;
            mask.x0 = @min(mask.x0, x);
            mask.x1 = @max(mask.x1, x + 1);
            mask.y0 = @min(mask.y0, y);
            mask.y1 = @max(mask.y1, y + 1);
        };
        // Outside the clip's box the coverage is zero, however it was drawn.
        for (0..p.h) |y| if (y < r.y0 or y >= r.y1) @memset(cov[y * p.w ..][0..p.w], 0) else {
            @memset(cov[y * p.w ..][0..r.x0], 0);
            @memset(cov[y * p.w + r.x1 ..][0 .. p.w - r.x1], 0);
        };
        if (mask.x0 >= mask.x1 or mask.y0 >= mask.y1) {
            p.gpa.free(cov);
            return null;
        }
        return mask;
    }

    fn bounds(p: *const Painter, clip: ?*const Mask) Mask {
        if (clip) |c| return c.*;
        return .{ .cov = &.{}, .x0 = 0, .y0 = 0, .x1 = p.w, .y1 = p.h };
    }

    /// Lays what `shader` gives over `dst`, where `clip` covers.
    fn fill(p: *Painter, dst: []f32, clip: anytype, shader: anytype) void {
        const mask: ?*const Mask = switch (@TypeOf(clip)) {
            *const Mask, *Mask => clip,
            ?*const Mask => clip,
            else => @compileError("a mask"),
        };
        const r = p.bounds(mask);
        for (r.y0..r.y1) |y| for (r.x0..r.x1) |x| {
            const i = y * p.w + x;
            const cov: f32 = if (mask) |c| @as(f32, @floatFromInt(c.cov[i])) / 255 else 1;
            if (cov == 0) continue;
            const s = shader.at(i, @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5) orelse continue;
            const out = dst[i * 4 ..][0..4];
            const k = 1 - s[3] * cov;
            for (out, s) |*o, c| o.* = c * cov + o.* * k;
        };
    }

    fn linear(p: *Painter, off: usize, m: Affine, clip: ?*const Mask, dst: []f32) Error!void {
        const d = p.t.d;
        const line = Line.read(p, off + be24(d, off + 1), d[off] == 5) orelse return;
        const inv = invert(m) orelse return;
        const x0 = bei16(d, off + 4);
        const y0 = bei16(d, off + 6);
        // The gradient runs along p0→p1 as seen across p0→p2: its lines of
        // constant color are parallel to p0→p2.
        const nx = -(bei16(d, off + 14) - y0);
        const ny = bei16(d, off + 12) - x0;
        const nn = nx * nx + ny * ny;
        if (nn == 0) return;
        const k = ((bei16(d, off + 8) - x0) * nx + (bei16(d, off + 10) - y0) * ny) / nn;
        const vx = nx * k;
        const vy = ny * k;
        const vv = vx * vx + vy * vy;
        if (vv == 0) return;
        p.fill(dst, clip, Linear{ .line = line, .inv = inv, .x0 = x0, .y0 = y0, .vx = vx, .vy = vy, .vv = vv });
    }

    fn radial(p: *Painter, off: usize, m: Affine, clip: ?*const Mask, dst: []f32) Error!void {
        const d = p.t.d;
        const line = Line.read(p, off + be24(d, off + 1), d[off] == 7) orelse return;
        const inv = invert(m) orelse return;
        p.fill(dst, clip, Radial{
            .line = line,
            .inv = inv,
            .x0 = bei16(d, off + 4),
            .y0 = bei16(d, off + 6),
            .r0 = @floatFromInt(be16(d, off + 8)),
            .x1 = bei16(d, off + 10),
            .y1 = bei16(d, off + 12),
            .r1 = @floatFromInt(be16(d, off + 14)),
        });
    }

    fn sweep(p: *Painter, off: usize, m: Affine, clip: ?*const Mask, dst: []f32) Error!void {
        const d = p.t.d;
        const line = Line.read(p, off + be24(d, off + 1), d[off] == 9) orelse return;
        const inv = invert(m) orelse return;
        p.fill(dst, clip, Sweep{
            .line = line,
            .inv = inv,
            .cx = bei16(d, off + 4),
            .cy = bei16(d, off + 6),
            .start = f2dot14(d, off + 8) * 180,
            .end = f2dot14(d, off + 10) * 180,
        });
    }
};

fn rotation(turns: f32) Affine {
    const a = turns * std.math.pi;
    return .{ @cos(a), @sin(a), -@sin(a), @cos(a), 0, 0 };
}

fn skew(x: f32, y: f32) Affine {
    return .{ 1, @tan(y * std.math.pi), -@tan(x * std.math.pi), 1, 0, 0 };
}

const Solid = struct {
    c: [4]f32,

    fn at(s: Solid, i: usize, x: f32, y: f32) ?[4]f32 {
        _ = .{ i, x, y };
        return s.c;
    }
};

/// A group's pixels, as a paint.
const Layer = struct {
    px: []const f32,

    fn at(l: Layer, i: usize, x: f32, y: f32) ?[4]f32 {
        _ = .{ x, y };
        const s = l.px[i * 4 ..][0..4];
        if (s[3] == 0) return null;
        return s.*;
    }
};

const Linear = struct {
    line: Line,
    inv: Affine,
    x0: f32,
    y0: f32,
    vx: f32,
    vy: f32,
    vv: f32,

    fn at(s: *const Linear, i: usize, px: f32, py: f32) ?[4]f32 {
        _ = i;
        const x = s.inv[0] * px + s.inv[2] * py + s.inv[4];
        const y = s.inv[1] * px + s.inv[3] * py + s.inv[5];
        return s.line.at(((x - s.x0) * s.vx + (y - s.y0) * s.vy) / s.vv);
    }
};

const Radial = struct {
    line: Line,
    inv: Affine,
    x0: f32,
    y0: f32,
    r0: f32,
    x1: f32,
    y1: f32,
    r1: f32,

    /// Two circles (a cone): t is the largest value whose circle, between
    /// the two (or past either), passes through the point with a radius
    /// that is not negative.
    fn at(s: *const Radial, i: usize, px: f32, py: f32) ?[4]f32 {
        _ = i;
        const x = s.inv[0] * px + s.inv[2] * py + s.inv[4];
        const y = s.inv[1] * px + s.inv[3] * py + s.inv[5];
        const cdx = s.x1 - s.x0;
        const cdy = s.y1 - s.y0;
        const pdx = x - s.x0;
        const pdy = y - s.y0;
        const dr = s.r1 - s.r0;
        const a = cdx * cdx + cdy * cdy - dr * dr;
        const b = pdx * cdx + pdy * cdy + s.r0 * dr;
        const c = pdx * pdx + pdy * pdy - s.r0 * s.r0;
        var t: f32 = undefined;
        if (@abs(a) < 1e-6) {
            if (@abs(b) < 1e-9) return null;
            t = c / (2 * b);
            if (s.r0 + t * dr < 0) return null;
        } else {
            const disc = b * b - a * c;
            if (disc < 0) return null;
            const q = @sqrt(disc);
            const t1 = (b + q) / a;
            const t2 = (b - q) / a;
            const hi = @max(t1, t2);
            const lo = @min(t1, t2);
            if (s.r0 + hi * dr >= 0) t = hi else if (s.r0 + lo * dr >= 0) t = lo else return null;
        }
        return s.line.at(t);
    }
};

const Sweep = struct {
    line: Line,
    inv: Affine,
    cx: f32,
    cy: f32,
    /// Degrees, counter-clockwise from the x axis.
    start: f32,
    end: f32,

    fn at(s: *const Sweep, i: usize, px: f32, py: f32) ?[4]f32 {
        _ = i;
        const x = s.inv[0] * px + s.inv[2] * py + s.inv[4] - s.cx;
        const y = s.inv[1] * px + s.inv[3] * py + s.inv[5] - s.cy;
        var deg = std.math.radiansToDegrees(std.math.atan2(y, x));
        if (deg < 0) deg += 360;
        if (s.end == s.start) return s.line.at(if (deg < s.start) 0 else 1);
        return s.line.at((deg - s.start) / (s.end - s.start));
    }
};

// Compositing, on premultiplied pixels.

fn compositePixel(mode: u8, s: [4]f32, b: [4]f32) [4]f32 {
    const sa = s[3];
    const ba = b[3];
    const pd: ?[2]f32 = switch (mode) {
        0 => .{ 0, 0 },
        1 => .{ 1, 0 },
        2 => .{ 0, 1 },
        3 => .{ 1, 1 - sa },
        4 => .{ 1 - ba, 1 },
        5 => .{ ba, 0 },
        6 => .{ 0, sa },
        7 => .{ 1 - ba, 0 },
        8 => .{ 0, 1 - sa },
        9 => .{ ba, 1 - sa },
        10 => .{ 1 - ba, sa },
        11 => .{ 1 - ba, 1 - sa },
        12 => .{ 1, 1 },
        else => null,
    };
    if (pd) |f| {
        var out: [4]f32 = undefined;
        for (&out, s, b) |*o, sc, bc| o.* = std.math.clamp(sc * f[0] + bc * f[1], 0, 1);
        return out;
    }
    if (mode > 27) return compositePixel(3, s, b);
    const alpha = sa + ba - sa * ba;
    if (sa == 0 or ba == 0) return compositePixel(3, s, b);
    const cs: [3]f32 = .{ s[0] / sa, s[1] / sa, s[2] / sa };
    const cb: [3]f32 = .{ b[0] / ba, b[1] / ba, b[2] / ba };
    var mixed: [3]f32 = undefined;
    if (mode >= 24) {
        mixed = nonSeparable(mode, cb, cs);
    } else for (&mixed, cb, cs) |*o, bb, ss| o.* = separable(mode, bb, ss);
    var out: [4]f32 = undefined;
    for (0..3) |k| out[k] = std.math.clamp(s[k] * (1 - ba) + b[k] * (1 - sa) + sa * ba * mixed[k], 0, 1);
    out[3] = alpha;
    return out;
}

fn separable(mode: u8, cb: f32, cs: f32) f32 {
    return switch (mode) {
        13 => cb + cs - cb * cs,
        14 => hardLight(cs, cb),
        15 => @min(cb, cs),
        16 => @max(cb, cs),
        17 => if (cb == 0) 0 else if (cs >= 1) 1 else @min(1, cb / (1 - cs)),
        18 => if (cb >= 1) 1 else if (cs <= 0) 0 else 1 - @min(1, (1 - cb) / cs),
        19 => hardLight(cb, cs),
        20 => blk: {
            if (cs <= 0.5) break :blk cb - (1 - 2 * cs) * cb * (1 - cb);
            const dd = if (cb <= 0.25) ((16 * cb - 12) * cb + 4) * cb else @sqrt(cb);
            break :blk cb + (2 * cs - 1) * (dd - cb);
        },
        21 => @abs(cb - cs),
        22 => cb + cs - 2 * cb * cs,
        else => cb * cs,
    };
}

fn hardLight(cb: f32, cs: f32) f32 {
    if (cs <= 0.5) return cb * 2 * cs;
    const s2 = 2 * cs - 1;
    return cb + s2 - cb * s2;
}

fn lum(c: [3]f32) f32 {
    return 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2];
}

fn clipColor(c: [3]f32) [3]f32 {
    const l = lum(c);
    const n = @min(c[0], @min(c[1], c[2]));
    const x = @max(c[0], @max(c[1], c[2]));
    var out = c;
    if (n < 0) for (&out) |*v| {
        v.* = l + (v.* - l) * l / (l - n);
    };
    if (x > 1) for (&out) |*v| {
        v.* = l + (v.* - l) * (1 - l) / (x - l);
    };
    return out;
}

fn setLum(c: [3]f32, l: f32) [3]f32 {
    const dl = l - lum(c);
    return clipColor(.{ c[0] + dl, c[1] + dl, c[2] + dl });
}

fn sat(c: [3]f32) f32 {
    return @max(c[0], @max(c[1], c[2])) - @min(c[0], @min(c[1], c[2]));
}

fn setSat(c: [3]f32, s: f32) [3]f32 {
    const n = @min(c[0], @min(c[1], c[2]));
    const x = @max(c[0], @max(c[1], c[2]));
    if (x <= n) return .{ 0, 0, 0 };
    return .{ (c[0] - n) * s / (x - n), (c[1] - n) * s / (x - n), (c[2] - n) * s / (x - n) };
}

fn nonSeparable(mode: u8, cb: [3]f32, cs: [3]f32) [3]f32 {
    return switch (mode) {
        24 => setLum(setSat(cs, sat(cb)), lum(cb)),
        25 => setLum(setSat(cb, sat(cs)), lum(cb)),
        26 => setLum(cs, lum(cb)),
        else => setLum(cb, lum(cs)),
    };
}

const noto = "/usr/share/fonts/google-noto-color-emoji-fonts/Noto-COLRv1.ttf";

/// A COLR font to test with, if one is installed.
pub fn testFont(gpa: std.mem.Allocator) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, noto, gpa, .limited(64 << 20)) catch null;
}

test "affine maths: composing, inverting, turning about a point" {
    const m = mul(translation(10, 0), .{ 2, 0, 0, 3, 0, 0 });
    try std.testing.expectEqual(@as(f32, 12), m[0] * 1 + m[2] * 1 + m[4]);
    const inv = invert(m).?;
    const p = mul(inv, m);
    for (p, identity) |a, b| try std.testing.expectApproxEqAbs(b, a, 1e-5);
    // A half turn (1.0) about (5, 5) sends (6, 5) to (4, 5).
    const r = about(rotation(1), 5, 5);
    try std.testing.expectApproxEqAbs(@as(f32, 4), r[0] * 6 + r[2] * 5 + r[4], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 5), r[1] * 6 + r[3] * 5 + r[5], 1e-4);
    try std.testing.expect(invert(.{ 1, 2, 2, 4, 0, 0 }) == null);
}

test "compositing modes on premultiplied pixels" {
    const red: [4]f32 = .{ 1, 0, 0, 1 };
    const half_blue: [4]f32 = .{ 0, 0, 0.5, 0.5 };
    try std.testing.expectEqual(red, compositePixel(1, red, half_blue));
    try std.testing.expectEqual(red, compositePixel(3, red, half_blue));
    // Source in backdrop: the source where the backdrop is, by its alpha.
    try std.testing.expectEqual([4]f32{ 0.5, 0, 0, 0.5 }, compositePixel(5, red, half_blue));
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, compositePixel(0, red, half_blue));
    // Multiply of opaque colors multiplies them.
    const m = compositePixel(23, .{ 0.5, 0.5, 0.5, 1 }, .{ 0.5, 1, 0, 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), m[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), m[1], 1e-6);
    try std.testing.expectEqual(@as(f32, 1), m[3]);
}

test "a color line's stops, extended" {
    var l: Line = .{ .n = 2, .extend = 0 };
    l.stops[0] = .{ .t = 0, .c = .{ 1, 0, 0, 1 } };
    l.stops[1] = .{ .t = 1, .c = .{ 0, 0, 1, 1 } };
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 1 }, l.at(-3));
    try std.testing.expectEqual([4]f32{ 0, 0, 1, 1 }, l.at(7));
    const mid = l.at(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mid[0], 1e-6);
    l.extend = 1;
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), l.at(1.25)[2], 1e-5);
    try std.testing.expectApproxEqAbs(l.at(0.25)[0], l.at(1.25)[0], 1e-5);
    l.extend = 2;
    try std.testing.expectApproxEqAbs(l.at(0.25)[0], l.at(1.75)[0], 1e-5);
}

test "Noto Color Emoji: the palette, the paint tree and the bitmap of a face" {
    const gpa = std.testing.allocator;
    const data = testFont(gpa) orelse return error.SkipZigTest;
    defer gpa.free(data);
    const f = try font.Font.init(data, 0);
    try std.testing.expect(f.isColor());
    const t = Table.init(&f).?;
    const smile = f.glyphIndex(0x1f600);
    try std.testing.expect(smile != 0);
    try std.testing.expect(t.has(smile));
    // Glyph 0 and the joiner are not drawn in color.
    try std.testing.expect(!t.has(f.glyphIndex(0x200d)));
    try std.testing.expect(t.paintOf(smile) != null);
    // Its clip box is in font units, inside the em square's neighborhood.
    const box = t.clipBox(smile).?;
    try std.testing.expect(box[0] < box[2] and box[1] < box[3]);
    try std.testing.expect(box[3] - box[1] < 1.5 * f.units_per_em);
    // Palette 0's first color is a real one.
    try std.testing.expect(t.color(0, .{ 0, 0, 0, 1 })[3] >= 0);
    try std.testing.expectEqual([4]f32{ 1, 0.5, 0.25, 1 }, t.color(0xffff, .{ 1, 0.5, 0.25, 1 }));

    // At 40 pixels: a bitmap as large as the box, mostly yellow in its middle.
    const ps = 40 / f.units_per_em;
    const bm = (try render(gpa, &f, smile, ps, 1)).?;
    defer gpa.free(bm.bgra);
    try std.testing.expect(bm.w >= 40 and bm.w <= 48 and bm.h >= 40 and bm.h <= 48);
    try std.testing.expect(bm.top > 0);
    var opaque_px: usize = 0;
    var yellow: usize = 0;
    for (0..bm.w * bm.h) |i| {
        const b = bm.bgra[i * 4 ..][0..4];
        if (b[3] == 255) opaque_px += 1;
        if (b[3] == 255 and b[2] > 200 and b[1] > 150 and b[0] < 120) yellow += 1;
    }
    try std.testing.expect(opaque_px > bm.w * bm.h / 2);
    try std.testing.expect(yellow > opaque_px / 3);
    // The corners of the box are clear: coverage, not a filled square.
    try std.testing.expectEqual(@as(u8, 0), bm.bgra[3]);
    // Not a color glyph: nothing.
    try std.testing.expect((try render(gpa, &f, f.glyphIndex(0x200d), ps, 1)) == null);
}

test "Noto Color Emoji: every kind of paint it uses draws, none outside its box" {
    const gpa = std.testing.allocator;
    const data = testFont(gpa) orelse return error.SkipZigTest;
    defer gpa.free(data);
    const f = try font.Font.init(data, 0);
    const t = Table.init(&f).?;
    // A sample across the glyph list: layers, solids, gradients (linear and
    // radial), transforms, scales, nested glyphs and composites included.
    const n = be32(t.d, t.base_list);
    var drawn: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 97) {
        const g = be16(t.d, t.base_list + 4 + 6 * i);
        const bm = (try render(gpa, &f, g, 24 / f.units_per_em, 1)) orelse continue;
        defer gpa.free(bm.bgra);
        drawn += 1;
        var ink: usize = 0;
        for (0..bm.w * bm.h) |k| ink += @intFromBool(bm.bgra[k * 4 + 3] > 0);
        try std.testing.expect(ink > 0);
        // Premultiplied: no channel above its alpha.
        for (0..bm.w * bm.h) |k| {
            const px = bm.bgra[k * 4 ..][0..4];
            try std.testing.expect(px[0] <= px[3] and px[1] <= px[3] and px[2] <= px[3]);
        }
    }
    try std.testing.expect(drawn > 30);
}

test "a gradient face is shaded: more than one color across the glyph" {
    const gpa = std.testing.allocator;
    const data = testFont(gpa) orelse return error.SkipZigTest;
    defer gpa.free(data);
    const f = try font.Font.init(data, 0);
    // The red heart and the lock are shaded with gradients.
    for ([_]u21{ 0x2764, 0x1f512 }) |cp| {
        const bm = (try render(gpa, &f, f.glyphIndex(cp), 48 / f.units_per_em, 1)).?;
        defer gpa.free(bm.bgra);
        var lo: [3]u8 = .{ 255, 255, 255 };
        var hi: [3]u8 = .{ 0, 0, 0 };
        for (0..bm.w * bm.h) |k| {
            const px = bm.bgra[k * 4 ..][0..4];
            if (px[3] != 255) continue;
            for (0..3) |ch| {
                lo[ch] = @min(lo[ch], px[ch]);
                hi[ch] = @max(hi[ch], px[ch]);
            }
        }
        // Some channel changes a lot across the glyph.
        try std.testing.expect(@max(hi[0] - lo[0], @max(hi[1] - lo[1], hi[2] - lo[2])) > 60);
    }
}
