//! Raw Snappy block decompression (LevelDB table blocks use it).
//! Format: https://github.com/google/snappy/blob/main/format_description.txt
const std = @import("std");

pub const Error = error{Corrupt} || std.mem.Allocator.Error;

/// Refuse absurd sizes from corrupt input
const max_output = 64 * 1024 * 1024;

fn varint(src: []const u8, pos: *usize) Error!u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (pos.* < src.len) {
        const b = src[pos.*];
        pos.* += 1;
        result |= @as(u32, b & 0x7f) << shift;
        if (b & 0x80 == 0) return result;
        if (shift >= 28) return error.Corrupt;
        shift += 7;
    }
    return error.Corrupt;
}

pub fn decompress(gpa: std.mem.Allocator, src: []const u8) Error![]u8 {
    var pos: usize = 0;
    const out_len = try varint(src, &pos);
    if (out_len > max_output) return error.Corrupt;
    const out = try gpa.alloc(u8, out_len);
    errdefer gpa.free(out);
    var o: usize = 0;
    while (pos < src.len) {
        const tag = src[pos];
        pos += 1;
        switch (tag & 3) {
            0 => {
                var len: usize = tag >> 2;
                if (len >= 60) {
                    const extra = len - 59;
                    if (pos + extra > src.len) return error.Corrupt;
                    len = 0;
                    for (src[pos..][0..extra], 0..) |b, i| len |= @as(usize, b) << @intCast(8 * i);
                    pos += extra;
                }
                len += 1;
                if (pos + len > src.len or o + len > out.len) return error.Corrupt;
                @memcpy(out[o..][0..len], src[pos..][0..len]);
                pos += len;
                o += len;
            },
            else => |kind| {
                var len: usize = undefined;
                var offset: usize = undefined;
                switch (kind) {
                    1 => {
                        if (pos + 1 > src.len) return error.Corrupt;
                        len = 4 + ((tag >> 2) & 7);
                        offset = (@as(usize, tag >> 5) << 8) | src[pos];
                        pos += 1;
                    },
                    2 => {
                        if (pos + 2 > src.len) return error.Corrupt;
                        len = 1 + (tag >> 2);
                        offset = std.mem.readInt(u16, src[pos..][0..2], .little);
                        pos += 2;
                    },
                    else => {
                        if (pos + 4 > src.len) return error.Corrupt;
                        len = 1 + (tag >> 2);
                        offset = std.mem.readInt(u32, src[pos..][0..4], .little);
                        pos += 4;
                    },
                }
                if (offset == 0 or offset > o or o + len > out.len) return error.Corrupt;
                // Copies may overlap, so go byte by byte
                for (0..len) |i| out[o + i] = out[o + i - offset];
                o += len;
            },
        }
    }
    if (o != out.len) return error.Corrupt;
    return out;
}

test "literal only" {
    const gpa = std.testing.allocator;
    const out = try decompress(gpa, &.{ 5, 4 << 2, 'h', 'e', 'l', 'l', 'o' });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "overlapping copy" {
    const gpa = std.testing.allocator;
    // literal "ab" then copy len 6 offset 2 (1-byte-offset form: len-4=2)
    const out = try decompress(gpa, &.{ 8, 1 << 2, 'a', 'b', (2 << 2) | 1, 2 });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("abababab", out);
}

test "corrupt input is rejected" {
    try std.testing.expectError(error.Corrupt, decompress(std.testing.allocator, &.{ 5, 1 << 2, 'a' }));
}
