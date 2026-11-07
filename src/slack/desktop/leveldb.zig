//! Minimal read-only LevelDB reader: just enough to find the newest value for
//! a key in Chromium's Local Storage. Reads `.ldb`/`.sst` tables and `.log`
//! write-ahead logs and keeps the highest-sequence entry per matching key.
//! Formats: table_format.md and log_format.md in google/leveldb.
const std = @import("std");
const snappy = @import("snappy.zig");

pub const Error = error{Corrupt} || snappy.Error;

pub const Kind = enum(u8) { deletion = 0, value = 1, _ };

pub const Entry = struct {
    key: []u8,
    value: []u8,
    seq: u64,
};

/// Tracks the newest live entry whose user key ends with `suffix`
pub const Scanner = struct {
    gpa: std.mem.Allocator,
    suffix: []const u8,
    best: ?Entry = null,
    /// Sequence of the newest deletion seen for a matching key, so a
    /// tombstone newer than the best value hides it
    best_deleted_seq: u64 = 0,

    pub fn deinit(s: *Scanner) void {
        if (s.best) |e| {
            s.gpa.free(e.key);
            s.gpa.free(e.value);
        }
    }

    /// The winning value, or null if absent or deleted. Caller owns it.
    pub fn take(s: *Scanner) ?Entry {
        const e = s.best orelse return null;
        s.best = null;
        if (s.best_deleted_seq > e.seq) {
            s.gpa.free(e.key);
            s.gpa.free(e.value);
            return null;
        }
        return e;
    }

    fn offer(s: *Scanner, key: []const u8, seq: u64, kind: Kind, value: []const u8) std.mem.Allocator.Error!void {
        if (!std.mem.endsWith(u8, key, s.suffix)) return;
        if (kind == .deletion) {
            s.best_deleted_seq = @max(s.best_deleted_seq, seq);
            return;
        }
        if (kind != .value) return;
        if (s.best) |old| {
            if (old.seq >= seq) return;
            s.gpa.free(old.key);
            s.gpa.free(old.value);
        }
        const k = try s.gpa.dupe(u8, key);
        errdefer s.gpa.free(k);
        s.best = .{ .key = k, .value = try s.gpa.dupe(u8, value), .seq = seq };
    }

    fn offerInternal(s: *Scanner, internal_key: []const u8, value: []const u8) Error!void {
        if (internal_key.len < 8) return error.Corrupt;
        const split = internal_key.len - 8;
        const tag = std.mem.readInt(u64, internal_key[split..][0..8], .little);
        try s.offer(internal_key[0..split], tag >> 8, @enumFromInt(@as(u8, @truncate(tag))), value);
    }
};

fn varint(data: []const u8, pos: *usize) Error!u64 {
    var result: u64 = 0;
    var shift: u7 = 0;
    while (pos.* < data.len and shift < 64) {
        const b = data[pos.*];
        pos.* += 1;
        result |= @as(u64, b & 0x7f) << @intCast(shift);
        if (b & 0x80 == 0) return result;
        shift += 7;
    }
    return error.Corrupt;
}

fn take(data: []const u8, pos: *usize, n: u64) Error![]const u8 {
    if (n > data.len - pos.*) return error.Corrupt;
    const out = data[pos.*..][0..@intCast(n)];
    pos.* += @intCast(n);
    return out;
}

const table_magic: u64 = 0xdb4775248b80fb57;
const footer_len = 48;

const Handle = struct { offset: u64, size: u64 };

fn readHandle(data: []const u8, pos: *usize) Error!Handle {
    return .{ .offset = try varint(data, pos), .size = try varint(data, pos) };
}

/// Returns block contents; allocated from `arena`
fn readBlock(arena: std.mem.Allocator, file: []const u8, h: Handle) Error![]const u8 {
    if (h.offset > file.len or h.size > file.len - h.offset) return error.Corrupt;
    const off: usize = @intCast(h.offset);
    const size: usize = @intCast(h.size);
    if (off + size + 5 > file.len) return error.Corrupt;
    const raw = file[off..][0..size];
    return switch (file[off + size]) {
        0 => raw,
        1 => try snappy.decompress(arena, raw),
        else => error.Corrupt,
    };
}

const BlockIter = struct {
    data: []const u8,
    pos: usize = 0,
    key: std.ArrayList(u8) = .empty,

    fn init(block: []const u8) Error!BlockIter {
        if (block.len < 4) return error.Corrupt;
        const restarts = std.mem.readInt(u32, block[block.len - 4 ..][0..4], .little);
        const tail = 4 + 4 * @as(usize, restarts);
        if (tail > block.len) return error.Corrupt;
        return .{ .data = block[0 .. block.len - tail] };
    }

    const Item = struct { key: []const u8, value: []const u8 };

    fn next(it: *BlockIter, arena: std.mem.Allocator) Error!?Item {
        if (it.pos >= it.data.len) return null;
        const shared = try varint(it.data, &it.pos);
        const non_shared = try varint(it.data, &it.pos);
        const value_len = try varint(it.data, &it.pos);
        if (shared > it.key.items.len) return error.Corrupt;
        const delta = try take(it.data, &it.pos, non_shared);
        const value = try take(it.data, &it.pos, value_len);
        it.key.shrinkRetainingCapacity(@intCast(shared));
        it.key.appendSlice(arena, delta) catch return error.OutOfMemory;
        return .{ .key = it.key.items, .value = value };
    }
};

pub fn scanTable(s: *Scanner, file: []const u8) Error!void {
    if (file.len < footer_len) return error.Corrupt;
    const footer = file[file.len - footer_len ..];
    if (std.mem.readInt(u64, footer[40..48], .little) != table_magic) return error.Corrupt;
    var fp: usize = 0;
    _ = try readHandle(footer, &fp); // metaindex, unused
    const index_handle = try readHandle(footer, &fp);

    var arena_state = std.heap.ArenaAllocator.init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var index = try BlockIter.init(try readBlock(arena, file, index_handle));
    while (try index.next(arena)) |entry| {
        var hp: usize = 0;
        const h = try readHandle(entry.value, &hp);
        // Per-block scratch so decompressed blocks don't pile up
        var block_arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer block_arena_state.deinit();
        const block_arena = block_arena_state.allocator();
        var it = try BlockIter.init(try readBlock(block_arena, file, h));
        while (try it.next(block_arena)) |kv| try s.offerInternal(kv.key, kv.value);
    }
}

const log_block = 32768;
const log_header = 7;

pub fn scanLog(s: *Scanner, file: []const u8) Error!void {
    var batch: std.ArrayList(u8) = .empty;
    defer batch.deinit(s.gpa);
    var pos: usize = 0;
    while (pos < file.len) {
        const block_left = log_block - (pos % log_block);
        if (block_left < log_header) {
            pos += block_left;
            continue;
        }
        if (pos + log_header > file.len) break;
        const len = std.mem.readInt(u16, file[pos + 4 ..][0..2], .little);
        const kind = file[pos + 6];
        if (kind == 0 and len == 0) {
            // Zero padding to the end of the block
            pos += block_left;
            continue;
        }
        pos += log_header;
        if (len > block_left - log_header or pos + len > file.len) break; // torn tail write
        const frag = file[pos..][0..len];
        pos += len;
        switch (kind) {
            1 => {
                batch.clearRetainingCapacity();
                try scanBatch(s, frag);
            },
            2 => {
                batch.clearRetainingCapacity();
                batch.appendSlice(s.gpa, frag) catch return error.OutOfMemory;
            },
            3 => batch.appendSlice(s.gpa, frag) catch return error.OutOfMemory,
            4 => {
                batch.appendSlice(s.gpa, frag) catch return error.OutOfMemory;
                try scanBatch(s, batch.items);
                batch.clearRetainingCapacity();
            },
            else => return error.Corrupt,
        }
    }
}

fn scanBatch(s: *Scanner, data: []const u8) Error!void {
    if (data.len < 12) return error.Corrupt;
    var seq = std.mem.readInt(u64, data[0..8], .little);
    const count = std.mem.readInt(u32, data[8..12], .little);
    var pos: usize = 12;
    for (0..count) |_| {
        if (pos >= data.len) return error.Corrupt;
        const kind: Kind = @enumFromInt(data[pos]);
        pos += 1;
        const key = try take(data, &pos, try varint(data, &pos));
        const value: []const u8 = if (kind == .value) try take(data, &pos, try varint(data, &pos)) else &.{};
        try s.offer(key, seq, kind, value);
        seq += 1;
    }
}

test "log batch: newest put wins, delete hides" {
    const gpa = std.testing.allocator;
    var s: Scanner = .{ .gpa = gpa, .suffix = "cfg" };
    defer s.deinit();
    // One FULL record holding a batch: seq 10, two puts of "cfg"
    var batch: std.ArrayList(u8) = .empty;
    defer batch.deinit(gpa);
    try batch.appendSlice(gpa, &.{ 10, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0 });
    try batch.appendSlice(gpa, &.{ 1, 3, 'c', 'f', 'g', 2, 'o', 'l' });
    try batch.appendSlice(gpa, &.{ 1, 3, 'c', 'f', 'g', 3, 'n', 'e', 'w' });
    var rec: std.ArrayList(u8) = .empty;
    defer rec.deinit(gpa);
    try rec.appendSlice(gpa, &.{ 0, 0, 0, 0 });
    try rec.appendSlice(gpa, &.{ @intCast(batch.items.len), 0, 1 });
    try rec.appendSlice(gpa, batch.items);
    try scanLog(&s, rec.items);
    const e = s.take().?;
    defer gpa.free(e.key);
    defer gpa.free(e.value);
    try std.testing.expectEqualStrings("new", e.value);
    try std.testing.expectEqual(@as(u64, 11), e.seq);
}
