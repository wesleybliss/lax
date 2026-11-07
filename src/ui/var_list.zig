//! Virtualized list of rows with different heights, anchored to the bottom.
//!
//! nanoui's `ui.list` only takes rows of one height, so this builds the same
//! thing on nanoui's scroll primitives: spacers stand for the rows out of
//! view, rows in view are built at their exact height, and `follow_end` keeps
//! a chat pinned to the newest message.
//!
//! Heights start as cheap estimates and become exact as rows are built, so
//! the scroll position is corrected when a row above the viewport changes
//! height (otherwise the content would jump under the reader).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const Source = struct {
    ptr: *anyopaque,
    count: usize,
    /// Cheap guess for a row at `width`: no text layout
    estimate: *const fn (ptr: *anyopaque, i: usize, width: f32) f32,
    /// Exact height of a row at `width`
    measure: *const fn (ptr: *anyopaque, c: *ui.Context, i: usize, width: f32) f32,
};

pub const Options = struct {
    padding: ui.Edges = .{ .top = 8, .bottom = 8 },
    /// Rows built beyond each edge of the view
    overscan: usize = 6,
};

pub const VarList = struct {
    gpa: std.mem.Allocator,
    heights: std.ArrayList(f32) = .empty,
    exact: std.ArrayList(bool) = .empty,
    /// `prefix[i]` is the top of row i; `prefix[count]` is the total
    prefix: std.ArrayList(f32) = .empty,
    prefix_dirty: bool = true,
    /// Width the heights are valid for
    width: f32 = 0,
    /// Jump to the newest row next frame (after sending a message)
    stick: bool = false,
    /// Rows built last frame, for stats
    built: usize = 0,
    /// First row in view last frame (to load older rows near the top)
    top_index: usize = 0,
    /// The scrolling box's id, set by `begin`
    id: u64 = 0,

    pub fn deinit(l: *VarList) void {
        l.heights.deinit(l.gpa);
        l.exact.deinit(l.gpa);
        l.prefix.deinit(l.gpa);
    }

    /// Forgets every cached height (different rows now)
    pub fn reset(l: *VarList) void {
        l.heights.clearRetainingCapacity();
        l.exact.clearRetainingCapacity();
        l.prefix.clearRetainingCapacity();
        l.prefix_dirty = true;
    }

    pub fn stickToEnd(l: *VarList) void {
        l.stick = true;
    }

    /// Moves the scroll offset by `delta` (after rows were prepended, so the
    /// reader's place does not change)
    pub fn shiftScroll(l: *VarList, c: *ui.Context, delta: f32) void {
        if (c.scroll.getPtr(l.id)) |off| off.* = @max(0, off.* + delta);
    }

    /// Rows were inserted at the front of the source. Shifts the cache and
    /// returns the estimated height of the new rows, which the caller adds to
    /// the scroll offset to keep the viewport still.
    pub fn prepend(l: *VarList, src: Source, n: usize) std.mem.Allocator.Error!f32 {
        const new_heights = try l.gpa.alloc(f32, n);
        defer l.gpa.free(new_heights);
        const new_exact = try l.gpa.alloc(bool, n);
        defer l.gpa.free(new_exact);
        var total: f32 = 0;
        for (new_heights, new_exact, 0..) |*h, *e, i| {
            h.* = src.estimate(src.ptr, i, l.width);
            e.* = false;
            total += h.*;
        }
        try l.heights.insertSlice(l.gpa, 0, new_heights);
        try l.exact.insertSlice(l.gpa, 0, new_exact);
        l.prefix_dirty = true;
        return total;
    }

    fn sync(l: *VarList, src: Source, width: f32) std.mem.Allocator.Error!void {
        if (@abs(width - l.width) > 0.5) {
            l.width = width;
            @memset(l.exact.items, false);
            for (l.heights.items, 0..) |*h, i| h.* = src.estimate(src.ptr, i, width);
            l.prefix_dirty = true;
        }
        const old = l.heights.items.len;
        if (src.count > old) {
            try l.heights.resize(l.gpa, src.count);
            try l.exact.resize(l.gpa, src.count);
            for (old..src.count) |i| {
                l.heights.items[i] = src.estimate(src.ptr, i, width);
                l.exact.items[i] = false;
            }
            l.prefix_dirty = true;
        } else if (src.count < old) {
            l.heights.shrinkRetainingCapacity(src.count);
            l.exact.shrinkRetainingCapacity(src.count);
            l.prefix_dirty = true;
        }
    }

    fn ensurePrefix(l: *VarList) std.mem.Allocator.Error!void {
        if (!l.prefix_dirty and l.prefix.items.len == l.heights.items.len + 1) return;
        try l.prefix.resize(l.gpa, l.heights.items.len + 1);
        var y: f32 = 0;
        for (l.heights.items, 0..) |h, i| {
            l.prefix.items[i] = y;
            y += h;
        }
        l.prefix.items[l.heights.items.len] = y;
        l.prefix_dirty = false;
    }

    /// Index of the row containing offset `y` (the last row if past the end)
    fn rowAt(l: *const VarList, y: f32) usize {
        const n = l.heights.items.len;
        if (n == 0) return 0;
        var lo: usize = 0;
        var hi: usize = n;
        while (lo + 1 < hi) {
            const mid = (lo + hi) / 2;
            if (l.prefix.items[mid] <= y) lo = mid else hi = mid;
        }
        return lo;
    }

    pub fn height(l: *const VarList, i: usize) f32 {
        return l.heights.items[i];
    }

    pub const Rows = struct {
        l: *VarList,
        c: *ui.Context,
        src: Source,
        id: u64,
        first: usize,
        next_index: usize,
        last: usize,
        first_visible: usize,
        width: f32,
        /// Height change of rows above the viewport this frame
        above_delta: f32 = 0,
        changed: bool = false,
        after: f32,

        /// The next row to draw, with its exact height in `l.height(i)`
        pub fn next(r: *Rows) ?usize {
            if (r.next_index >= r.last) return null;
            const i = r.next_index;
            r.next_index += 1;
            const l = r.l;
            if (!l.exact.items[i]) {
                const h = r.src.measure(r.src.ptr, r.c, i, r.width);
                const delta = h - l.heights.items[i];
                l.exact.items[i] = true;
                if (@abs(delta) > 0.01) {
                    l.heights.items[i] = h;
                    l.prefix_dirty = true;
                    r.changed = true;
                    if (i < r.first_visible) r.above_delta += delta;
                }
            }
            r.c.next_key_int = i;
            return i;
        }

        pub fn end(r: *Rows) void {
            const c = r.c;
            if (r.after > 0) _ = c.leaf(.{ .height = .{ .px = r.after } }, .none, "vl-after");
            c.end();
            r.l.built = r.last - r.first;
            r.l.top_index = r.first_visible;
            if (r.above_delta != 0) {
                const following = c.scroll_follow.get(r.id) orelse true;
                if (!following) if (c.scroll.getPtr(r.id)) |s| {
                    s.* = @max(0, s.* + r.above_delta);
                };
            }
            // A corrected height changes where rows sit: settle next frame
            if (r.changed) c.animationFrame();
        }
    };

    /// Opens the scrolling box and the spacer before the rows in view.
    /// Draw each `next()` row at height `height(i)`, then call `end()`.
    pub fn begin(l: *VarList, c: *ui.Context, src: Source, opts: Options) std.mem.Allocator.Error!Rows {
        const id = c.peekId(null);
        l.id = id;
        const open_i = c.open(.{
            .direction = .column,
            .width = .fill,
            .height = .fill,
            .padding = opts.padding,
            .scroll = true,
            .follow_end = true,
            .selectable = true,
        }, null);
        std.debug.assert(c.node(open_i).id == id);

        // The view as the last frame laid it out; the window's size at first
        const prev = c.rects.get(id);
        const view_h = if (prev) |r| r.h else c.size.h;
        const width = @max(1, (if (prev) |r| r.w else c.size.w) - opts.padding.horizontal());
        try l.sync(src, width);
        try l.ensurePrefix();

        const total = l.prefix.items[src.count];
        const max_scroll = @max(0, total + opts.padding.vertical() - view_h);
        if (l.stick) {
            l.stick = false;
            c.scroll.put(c.gpa, id, max_scroll) catch {};
            c.scroll_follow.put(c.gpa, id, true) catch {};
        }
        const offset: f32 = if (c.scroll.get(id)) |s| std.math.clamp(s, 0, max_scroll) else max_scroll;
        if (c.scroll.getPtr(id)) |s| s.* = offset;

        // Fewer rows than the view holds: all of them, pushed to the bottom
        if (total + opts.padding.vertical() <= view_h) {
            const gap = view_h - opts.padding.vertical() - total;
            if (gap > 0) _ = c.leaf(.{ .height = .{ .px = gap } }, .none, "vl-before");
            return .{ .l = l, .c = c, .src = src, .id = id, .first = 0, .next_index = 0, .last = src.count, .first_visible = 0, .width = width, .after = 0 };
        }

        const top = @max(0, offset - opts.padding.top);
        const first_visible = l.rowAt(top);
        const last_visible = l.rowAt(top + view_h) + 1;
        const first = first_visible -| opts.overscan;
        const last = @min(src.count, last_visible + opts.overscan);
        if (first > 0) _ = c.leaf(.{ .height = .{ .px = l.prefix.items[first] } }, .none, "vl-before");
        return .{
            .l = l,
            .c = c,
            .src = src,
            .id = id,
            .first = first,
            .next_index = first,
            .last = last,
            .first_visible = first_visible,
            .width = width,
            .after = total - l.prefix.items[last],
        };
    }
};
