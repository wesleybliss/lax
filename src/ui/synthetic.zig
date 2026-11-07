//! Deterministic synthetic chat for the UI spike and tests.
const std = @import("std");

pub const Message = struct {
    author: u8,
    /// Seconds since the start of the synthetic day
    ts: u32,
    text: []const u8,
};

pub const authors = [_][]const u8{ "Ada", "Grace", "Linus", "Margaret", "Dennis", "Barbara", "Ken", "Frances" };

const words = [_][]const u8{
    "deploy",  "the",    "worker",  "is",     "failing", "on",     "staging", "again",  "looks",  "like",   "a",       "cache",
    "issue",   "can",    "someone", "review", "my",      "pull",   "request", "before", "lunch",  "thanks", "shipping", "now",
    "metrics", "show",   "latency", "spiking", "after",  "the",    "migration", "rolled", "back",  "client", "wants",   "another",
    "draft",   "by",     "friday",  "sounds", "good",    "to",     "me",      "I'll",   "take",   "that",   "one",     "ticket",
};

pub fn generate(arena: std.mem.Allocator, n: usize, seed: u64) std.mem.Allocator.Error![]Message {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    const out = try arena.alloc(Message, n);
    var ts: u32 = 0;
    var author: u8 = 0;
    for (out) |*m| {
        ts += rng.intRangeAtMost(u32, 5, 900);
        // Runs of one author, so the header-less continuation rows appear
        if (rng.intRangeAtMost(u8, 0, 99) < 35) author = rng.intRangeLessThan(u8, 0, authors.len);
        const kind = rng.intRangeAtMost(u8, 0, 99);
        const word_count: usize = if (kind < 60) rng.intRangeAtMost(usize, 1, 12) else if (kind < 90) rng.intRangeAtMost(usize, 15, 60) else rng.intRangeAtMost(usize, 100, 220);
        const paragraphs: usize = if (kind >= 97) rng.intRangeAtMost(usize, 2, 4) else 1;
        var text: std.ArrayList(u8) = .empty;
        for (0..paragraphs) |p| {
            if (p > 0) try text.appendSlice(arena, "\n");
            for (0..@max(1, word_count / paragraphs)) |w| {
                if (w > 0) try text.append(arena, ' ');
                try text.appendSlice(arena, words[rng.intRangeLessThan(usize, 0, words.len)]);
            }
        }
        m.* = .{ .author = author, .ts = ts, .text = text.items };
    }
    return out;
}
