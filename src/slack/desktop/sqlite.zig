//! Minimal read-only SQLite reader: scans one rowid table's b-tree from an
//! in-memory database image. Enough to read Chromium's Cookies DB without
//! linking libsqlite3. Format: https://www.sqlite.org/fileformat2.html
const std = @import("std");

pub const Error = error{ Corrupt, Unsupported } || std.mem.Allocator.Error;

pub const Value = union(enum) {
    null,
    int: i64,
    real: f64,
    blob: []const u8,
    text: []const u8,
};

pub const Db = struct {
    data: []const u8,
    page_size: usize,

    pub fn init(data: []const u8) Error!Db {
        if (data.len < 100 or !std.mem.startsWith(u8, data, "SQLite format 3\x00")) return error.Corrupt;
        const raw = std.mem.readInt(u16, data[16..18], .big);
        const page_size: usize = if (raw == 1) 65536 else raw;
        if (page_size < 512 or data[20] != 0) return error.Unsupported;
        if (std.mem.readInt(u32, data[56..60], .big) != 1) return error.Unsupported; // UTF-8 only
        return .{ .data = data, .page_size = page_size };
    }

    fn page(db: Db, n: u32) Error![]const u8 {
        if (n == 0) return error.Corrupt;
        const start = (@as(usize, n) - 1) * db.page_size;
        if (start + db.page_size > db.data.len) return error.Corrupt;
        return db.data[start..][0..db.page_size];
    }

    pub const RowFn = *const fn (ctx: *anyopaque, rowid: i64, values: []const Value) Error!void;

    /// Calls `cb` for every row of the table rooted at `root`
    pub fn scan(db: Db, gpa: std.mem.Allocator, root: u32, ctx: *anyopaque, cb: RowFn) Error!void {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        try db.walk(arena_state.allocator(), root, 0, ctx, cb);
    }

    fn walk(db: Db, arena: std.mem.Allocator, n: u32, depth: u8, ctx: *anyopaque, cb: RowFn) Error!void {
        if (depth > 32) return error.Corrupt;
        const pg = try db.page(n);
        const base: usize = if (n == 1) 100 else 0;
        const kind = pg[base];
        const ncells = std.mem.readInt(u16, pg[base + 3 ..][0..2], .big);
        switch (kind) {
            0x0d => {
                for (0..ncells) |i| {
                    const ptr = std.mem.readInt(u16, pg[base + 8 + 2 * i ..][0..2], .big);
                    try db.leafCell(arena, pg, ptr, ctx, cb);
                }
            },
            0x05 => {
                for (0..ncells) |i| {
                    const ptr = std.mem.readInt(u16, pg[base + 12 + 2 * i ..][0..2], .big);
                    if (ptr + 4 > pg.len) return error.Corrupt;
                    try db.walk(arena, std.mem.readInt(u32, pg[ptr..][0..4], .big), depth + 1, ctx, cb);
                }
                try db.walk(arena, std.mem.readInt(u32, pg[base + 8 ..][0..4], .big), depth + 1, ctx, cb);
            },
            else => return error.Unsupported,
        }
    }

    fn leafCell(db: Db, arena: std.mem.Allocator, pg: []const u8, ptr: usize, ctx: *anyopaque, cb: RowFn) Error!void {
        var pos = ptr;
        const payload_len: usize = @intCast(try varint(pg, &pos));
        const rowid: i64 = @bitCast(try varint(pg, &pos));
        const u = db.page_size;
        const max_local = u - 35;
        var payload: []const u8 = undefined;
        if (payload_len <= max_local) {
            if (pos + payload_len > pg.len) return error.Corrupt;
            payload = pg[pos..][0..payload_len];
        } else {
            const min_local = ((u - 12) * 32 / 255) - 23;
            const k = min_local + ((payload_len - min_local) % (u - 4));
            const local = if (k <= max_local) k else min_local;
            if (pos + local + 4 > pg.len) return error.Corrupt;
            const buf = try arena.alloc(u8, payload_len);
            @memcpy(buf[0..local], pg[pos..][0..local]);
            var got = local;
            var next = std.mem.readInt(u32, pg[pos + local ..][0..4], .big);
            while (got < payload_len) {
                if (next == 0) return error.Corrupt;
                const op = try db.page(next);
                const take = @min(payload_len - got, u - 4);
                @memcpy(buf[got..][0..take], op[4..][0..take]);
                got += take;
                next = std.mem.readInt(u32, op[0..4], .big);
            }
            payload = buf;
        }
        try record(arena, payload, rowid, ctx, cb);
    }
};

fn varint(data: []const u8, pos: *usize) Error!u64 {
    var result: u64 = 0;
    for (0..9) |i| {
        if (pos.* >= data.len) return error.Corrupt;
        const b = data[pos.*];
        pos.* += 1;
        if (i == 8) return (result << 8) | b;
        result = (result << 7) | (b & 0x7f);
        if (b & 0x80 == 0) return result;
    }
    unreachable;
}

fn record(arena: std.mem.Allocator, payload: []const u8, rowid: i64, ctx: *anyopaque, cb: Db.RowFn) Error!void {
    var pos: usize = 0;
    const header_len: usize = @intCast(try varint(payload, &pos));
    if (header_len > payload.len) return error.Corrupt;
    var types: std.ArrayList(u64) = .empty;
    defer types.deinit(arena);
    while (pos < header_len) try types.append(arena, try varint(payload, &pos));
    var values = try arena.alloc(Value, types.items.len);
    defer arena.free(values);
    var body = header_len;
    for (types.items, 0..) |t, i| {
        const size: usize = switch (t) {
            0, 8, 9 => 0,
            1 => 1,
            2 => 2,
            3 => 3,
            4 => 4,
            5 => 6,
            6, 7 => 8,
            10, 11 => return error.Corrupt,
            else => @intCast((t - 12) / 2),
        };
        if (body + size > payload.len) return error.Corrupt;
        const bytes = payload[body..][0..size];
        values[i] = switch (t) {
            0 => .null,
            8 => .{ .int = 0 },
            9 => .{ .int = 1 },
            1...6 => .{ .int = signedBig(bytes) },
            7 => .{ .real = @bitCast(std.mem.readInt(u64, bytes[0..8], .big)) },
            else => if (t % 2 == 0) .{ .blob = bytes } else .{ .text = bytes },
        };
        body += size;
    }
    try cb(ctx, rowid, values);
}

fn signedBig(bytes: []const u8) i64 {
    var v: i64 = if (bytes[0] & 0x80 != 0) -1 else 0;
    for (bytes) |b| v = (v << 8) | b;
    return v;
}

/// Column index by name from a `CREATE TABLE` statement, or null
pub fn columnIndex(sql: []const u8, name: []const u8) ?usize {
    const open = std.mem.indexOfScalar(u8, sql, '(') orelse return null;
    var depth: usize = 0;
    var start = open + 1;
    var index: usize = 0;
    var i = open;
    while (i < sql.len) : (i += 1) {
        switch (sql[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return matchColumn(sql[start..i], name, index);
            },
            ',' => if (depth == 1) {
                if (matchColumn(sql[start..i], name, index)) |found| return found;
                if (!isConstraint(sql[start..i])) index += 1;
                start = i + 1;
            },
            else => {},
        }
    }
    return null;
}

fn firstWord(def: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, def, " \t\r\n");
    const end = std.mem.indexOfAny(u8, trimmed, " \t\r\n") orelse trimmed.len;
    return std.mem.trim(u8, trimmed[0..end], "\"`[]'");
}

fn isConstraint(def: []const u8) bool {
    const w = firstWord(def);
    inline for (.{ "PRIMARY", "UNIQUE", "CHECK", "FOREIGN", "CONSTRAINT" }) |kw| {
        if (std.ascii.eqlIgnoreCase(w, kw)) return true;
    }
    return false;
}

fn matchColumn(def: []const u8, name: []const u8, index: usize) ?usize {
    if (isConstraint(def)) return null;
    return if (std.mem.eql(u8, firstWord(def), name)) index else null;
}

test "columnIndex finds columns and skips constraints" {
    const sql = "CREATE TABLE cookies(creation_utc INTEGER NOT NULL,host_key TEXT NOT NULL,name TEXT NOT NULL,encrypted_value BLOB DEFAULT '',UNIQUE (host_key, name))";
    try std.testing.expectEqual(@as(?usize, 1), columnIndex(sql, "host_key"));
    try std.testing.expectEqual(@as(?usize, 3), columnIndex(sql, "encrypted_value"));
    try std.testing.expectEqual(@as(?usize, null), columnIndex(sql, "missing"));
}
