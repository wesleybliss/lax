//! Slack's mrkdwn to plain text plus style runs. The UI maps runs to its own
//! text spans. Handles `*bold*`, `_italic_`, `~strike~`, `code`, ```blocks```,
//! `&gt;` quotes, `<@U123>`, `<#C123|name>`, `<!here>`, `<url|label>` and the
//! `&lt; &gt; &amp;` escapes.
const std = @import("std");
const emoji = @import("emoji.zig");

pub const Style = enum { bold, italic, strike, code, code_block, link, mention, quote };

pub const Run = struct {
    start: u32,
    end: u32,
    style: Style,
    /// Where a `link` run goes (unescaped); empty for other styles
    target: []const u8 = "",
};

pub const Rendered = struct {
    text: []const u8,
    runs: []const Run,
};

/// Name lookups. Unknown ids fall back to the id itself.
pub const Resolver = struct {
    ctx: *const anyopaque,
    user: *const fn (ctx: *const anyopaque, id: []const u8) ?[]const u8,
    channel: *const fn (ctx: *const anyopaque, id: []const u8) ?[]const u8,
    /// `:name:` to unicode, if known
    emoji: *const fn (name: []const u8) ?[]const u8 = emoji.lookup,

    pub const none: Resolver = .{ .ctx = &none_ctx, .user = noName, .channel = noName };
};

const none_ctx: u8 = 0;

fn noName(_: *const anyopaque, _: []const u8) ?[]const u8 {
    return null;
}

const Parser = struct {
    arena: std.mem.Allocator,
    res: Resolver,
    out: std.ArrayList(u8) = .empty,
    runs: std.ArrayList(Run) = .empty,

    fn pos(p: *const Parser) u32 {
        return @intCast(p.out.items.len);
    }

    fn run(p: *Parser, start: u32, style: Style) std.mem.Allocator.Error!void {
        if (p.pos() > start) try p.runs.append(p.arena, .{ .start = start, .end = p.pos(), .style = style });
    }

    fn linkRun(p: *Parser, start: u32, target: []const u8) std.mem.Allocator.Error!void {
        if (p.pos() <= start) return;
        var url: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < target.len) {
            inline for (.{ .{ "&amp;", '&' }, .{ "&lt;", '<' }, .{ "&gt;", '>' } }) |e| {
                if (std.mem.startsWith(u8, target[i..], e[0])) {
                    try url.append(p.arena, e[1]);
                    i += e[0].len;
                    break;
                }
            } else {
                try url.append(p.arena, target[i]);
                i += 1;
            }
        }
        try p.runs.append(p.arena, .{ .start = start, .end = p.pos(), .style = .link, .target = url.items });
    }

    fn entity(p: *Parser, raw: []const u8, i: *usize) std.mem.Allocator.Error!bool {
        inline for (.{ .{ "&lt;", '<' }, .{ "&gt;", '>' }, .{ "&amp;", '&' } }) |e| {
            if (std.mem.startsWith(u8, raw[i.*..], e[0])) {
                try p.out.append(p.arena, e[1]);
                i.* += e[0].len;
                return true;
            }
        }
        return false;
    }

    /// `<...>` at raw[i]: link, mention, channel or special. Returns false
    /// if it isn't one (a stray `<` is just text).
    fn token(p: *Parser, raw: []const u8, i: *usize) std.mem.Allocator.Error!bool {
        const close = std.mem.indexOfScalarPos(u8, raw, i.*, '>') orelse return false;
        const body = raw[i.* + 1 .. close];
        if (body.len == 0 or std.mem.indexOfScalar(u8, body, '\n') != null) return false;
        const bar = std.mem.indexOfScalar(u8, body, '|');
        const target = if (bar) |b| body[0..b] else body;
        const label: ?[]const u8 = if (bar) |b| body[b + 1 ..] else null;
        const start = p.pos();
        switch (target[0]) {
            '@' => {
                const id = target[1..];
                try p.out.append(p.arena, '@');
                try p.out.appendSlice(p.arena, label orelse p.res.user(p.res.ctx, id) orelse id);
                try p.run(start, .mention);
            },
            '#' => {
                const id = target[1..];
                try p.out.append(p.arena, '#');
                try p.out.appendSlice(p.arena, label orelse p.res.channel(p.res.ctx, id) orelse id);
                try p.run(start, .mention);
            },
            '!' => {
                const special = target[1..];
                try p.out.append(p.arena, '@');
                if (label) |l| {
                    try p.out.appendSlice(p.arena, std.mem.trimStart(u8, l, "@"));
                } else {
                    const caret = std.mem.indexOfScalar(u8, special, '^') orelse special.len;
                    try p.out.appendSlice(p.arena, special[0..caret]);
                }
                try p.run(start, .mention);
            },
            else => {
                try p.appendUnescaped(label orelse target);
                try p.linkRun(start, target);
            },
        }
        i.* = close + 1;
        return true;
    }

    fn appendUnescaped(p: *Parser, s: []const u8) std.mem.Allocator.Error!void {
        var i: usize = 0;
        while (i < s.len) {
            if (try p.entity(s, &i)) continue;
            try p.out.append(p.arena, s[i]);
            i += 1;
        }
    }

    fn isBoundary(c: u8) bool {
        return std.ascii.isWhitespace(c) or std.mem.indexOfScalar(u8, ".,;:!?()[]{}\"'-/", c) != null;
    }

    fn closer(raw: []const u8, from: usize, marker: u8) ?usize {
        var j = from;
        while (j < raw.len) : (j += 1) {
            if (raw[j] == '\n') return null;
            if (raw[j] == '<') { // skip tokens whole: they may contain markers
                if (std.mem.indexOfScalarPos(u8, raw, j, '>')) |end| j = end;
                continue;
            }
            if (raw[j] != marker) continue;
            if (j == from) continue;
            if (std.ascii.isWhitespace(raw[j - 1])) continue;
            if (j + 1 < raw.len and !isBoundary(raw[j + 1])) continue;
            return j;
        }
        return null;
    }

    /// Inline content of one line (or a span within it)
    fn inline_(p: *Parser, raw: []const u8) std.mem.Allocator.Error!void {
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c == '<' and try p.token(raw, &i)) continue;
            if (c == '&' and try p.entity(raw, &i)) continue;
            if (c == ':') {
                if (std.mem.indexOfScalarPos(u8, raw, i + 1, ':')) |end| {
                    const name = raw[i + 1 .. end];
                    if (name.len > 0 and name.len < 40 and std.mem.indexOfAny(u8, name, " <>&") == null) {
                        if (p.res.emoji(name)) |glyph| {
                            i = end + 1;
                            // `:+1::skin-tone-3:` is two shortcodes in a row
                            const tone_prefix = ":skin-tone-";
                            if (std.mem.startsWith(u8, raw[i..], tone_prefix) and i + tone_prefix.len + 1 < raw.len and raw[i + tone_prefix.len + 1] == ':') {
                                if (emoji.toneModifier(raw[i + tone_prefix.len] -% '0')) |mod| {
                                    const first = std.unicode.utf8ByteSequenceLength(glyph[0]) catch glyph.len;
                                    try p.out.appendSlice(p.arena, glyph[0..first]);
                                    try p.out.appendSlice(p.arena, mod);
                                    try p.out.appendSlice(p.arena, glyph[first..]);
                                    i += tone_prefix.len + 2;
                                    continue;
                                }
                            }
                            try p.out.appendSlice(p.arena, glyph);
                            continue;
                        }
                    }
                }
            }
            if (c == '`') {
                if (std.mem.indexOfScalarPos(u8, raw, i + 1, '`')) |end| if (end > i + 1) {
                    const start = p.pos();
                    try p.appendUnescaped(raw[i + 1 .. end]);
                    try p.run(start, .code);
                    i = end + 1;
                    continue;
                };
            }
            if (c == '*' or c == '_' or c == '~') {
                const can_open = (i == 0 or isBoundary(raw[i - 1])) and i + 1 < raw.len and !std.ascii.isWhitespace(raw[i + 1]) and raw[i + 1] != c;
                if (can_open) if (closer(raw, i + 1, c)) |end| {
                    const start = p.pos();
                    try p.inline_(raw[i + 1 .. end]);
                    try p.run(start, switch (c) {
                        '*' => .bold,
                        '_' => .italic,
                        else => .strike,
                    });
                    i = end + 1;
                    continue;
                };
            }
            try p.out.append(p.arena, c);
            i += 1;
        }
    }

    fn lines(p: *Parser, raw: []const u8) std.mem.Allocator.Error!void {
        var it = std.mem.splitScalar(u8, raw, '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first) try p.out.append(p.arena, '\n');
            first = false;
            const start = p.pos();
            if (std.mem.startsWith(u8, line, "&gt;")) {
                const rest = std.mem.trimStart(u8, line[4..], " ");
                try p.inline_(rest);
                try p.run(start, .quote);
            } else try p.inline_(line);
        }
    }

    fn blocks(p: *Parser, raw: []const u8) std.mem.Allocator.Error!void {
        var rest = raw;
        while (std.mem.indexOf(u8, rest, "```")) |open| {
            const after = open + 3;
            const end = std.mem.indexOfPos(u8, rest, after, "```") orelse break;
            try p.lines(rest[0..open]);
            const start = p.pos();
            try p.appendUnescaped(std.mem.trim(u8, rest[after..end], "\n"));
            try p.run(start, .code_block);
            rest = rest[end + 3 ..];
            // The newline after a block would add an empty line
            if (std.mem.startsWith(u8, rest, "\n")) rest = rest[1..];
            if (rest.len > 0) try p.out.append(p.arena, '\n');
        }
        try p.lines(rest);
    }
};

/// Renders `raw` mrkdwn. Everything is allocated from `arena`.
pub fn render(arena: std.mem.Allocator, raw: []const u8, res: Resolver) std.mem.Allocator.Error!Rendered {
    var p: Parser = .{ .arena = arena, .res = res };
    try p.blocks(raw);
    return .{ .text = p.out.items, .runs = p.runs.items };
}

fn expectRun(r: Rendered, style: Style, text: []const u8) !void {
    for (r.runs) |run| if (run.style == style and std.mem.eql(u8, r.text[run.start..run.end], text)) return;
    std.debug.print("no {s} run for \"{s}\" in \"{s}\" runs={any}\n", .{ @tagName(style), text, r.text, r.runs });
    return error.RunNotFound;
}

const test_res: Resolver = .{
    .ctx = &none_ctx,
    .user = struct {
        fn f(_: *const anyopaque, id: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, id, "U1")) "ada" else null;
        }
    }.f,
    .channel = struct {
        fn f(_: *const anyopaque, id: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, id, "C1")) "general" else null;
        }
    }.f,
    .emoji = struct {
        fn f(name: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, name, "tada")) "🎉" else null;
        }
    }.f,
};

test "inline styles" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const r = try render(a.allocator(), "hi *bold* and _it_ ~gone~ `x &lt; y`", Resolver.none);
    try std.testing.expectEqualStrings("hi bold and it gone x < y", r.text);
    try expectRun(r, .bold, "bold");
    try expectRun(r, .italic, "it");
    try expectRun(r, .strike, "gone");
    try expectRun(r, .code, "x < y");
}

test "snake_case and math are not styled" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const r = try render(a.allocator(), "my_var_name and 2 * 3 * 4", Resolver.none);
    try std.testing.expectEqualStrings("my_var_name and 2 * 3 * 4", r.text);
    try std.testing.expectEqual(@as(usize, 0), r.runs.len);
}

test "mentions, channels, links, specials, entities" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const r = try render(a.allocator(), "<@U1> in <#C1|general> see <https://x.io/a?b=1&amp;c=2|docs> or <https://y.io> <!here> <@U9> a &amp; b", test_res);
    try std.testing.expectEqualStrings("@ada in #general see docs or https://y.io @here @U9 a & b", r.text);
    try expectRun(r, .mention, "@ada");
    try expectRun(r, .mention, "#general");
    try expectRun(r, .link, "docs");
    try expectRun(r, .link, "https://y.io");
    for (r.runs) |run| if (run.style == .link and std.mem.eql(u8, r.text[run.start..run.end], "docs")) {
        try std.testing.expectEqualStrings("https://x.io/a?b=1&c=2", run.target);
    };
}

test "nested styles, quotes, blocks, emoji" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const r = try render(a.allocator(), "*bold _both_* :tada:\n&gt; quoted\n```\ncode here\n```\nafter", test_res);
    try std.testing.expectEqualStrings("bold both 🎉\nquoted\ncode here\nafter", r.text);
    try expectRun(r, .bold, "bold both");
    try expectRun(r, .italic, "both");
    try expectRun(r, .quote, "quoted");
    try expectRun(r, .code_block, "code here");
}

test "skin tones and the built-in table" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const r = try render(a.allocator(), "nice :+1::skin-tone-4: and :fire: but :not_a_real_one:", Resolver.none);
    try std.testing.expectEqualStrings("nice 👍🏽 and 🔥 but :not_a_real_one:", r.text);
}
