//! Pictures other than PNG (JPEG, GIF, WebP, ...) on Linux: GTK 4 is loaded
//! anyway, and its `GdkTexture` reads what the system can. The pixels come
//! back as premultiplied BGRA, as the PNG decoder's do.
const std = @import("std");
const gtk = @import("gtk.zig");

pub const Raw = struct { width: u32, height: u32, bgra: []u8 };

/// Largest picture taken, in pixels
const max_pixels = 64 * 1024 * 1024;

fn open(bytes: []const u8) ?*anyopaque {
    // GTK 3 has no texture to give
    if (!gtk.v4 or bytes.len == 0) return null;
    const g = &gtk.v4api;
    const blob = g.g_bytes_new(bytes.ptr, bytes.len);
    defer g.g_bytes_unref(blob);
    var err: ?*anyopaque = null;
    const texture = g.gdk_texture_new_from_bytes(blob, &err);
    if (err) |e| g.g_error_free(e);
    return texture;
}

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) error{ InvalidImage, OutOfMemory }!Raw {
    const texture = open(bytes) orelse return error.InvalidImage;
    defer gtk.api.g_object_unref(texture);
    const g = &gtk.v4api;
    const w: u32 = @intCast(@max(0, g.gdk_texture_get_width(texture)));
    const h: u32 = @intCast(@max(0, g.gdk_texture_get_height(texture)));
    if (w == 0 or h == 0 or @as(u64, w) * h > max_pixels) return error.InvalidImage;
    const out = try gpa.alloc(u8, @as(usize, w) * h * 4);
    // GDK's default memory format: B8G8R8A8 premultiplied
    g.gdk_texture_download(texture, out.ptr, @as(usize, w) * 4);
    return .{ .width = w, .height = h, .bgra = out };
}

pub fn dimensions(bytes: []const u8) ?struct { width: u32, height: u32 } {
    const texture = open(bytes) orelse return null;
    defer gtk.api.g_object_unref(texture);
    const g = &gtk.v4api;
    const w = g.gdk_texture_get_width(texture);
    const h = g.gdk_texture_get_height(texture);
    if (w <= 0 or h <= 0 or @as(u64, @intCast(w)) * @as(u64, @intCast(h)) > max_pixels) return null;
    return .{ .width = @intCast(w), .height = @intCast(h) };
}

test "a JPEG decodes through GTK to premultiplied BGRA" {
    // Needs GTK 4 and its JPEG loader; a 40 x 20 picture of one red
    if (!gtk.ready() or !gtk.v4) return error.SkipZigTest;
    const hex = "ffd8ffe000104a46494600010100000100010000ffdb00430006040506050406060506070706080a100a0a09090a140e0f0c1017141818171416161a1d251f1a1b231c1616202c20232627292a29191f2d302d283025282928ffdb0043010707070a080a130a0a13281a161a2828282828282828282828282828282828282828282828282828282828282828282828282828282828282828282828282828ffc00011080014002803012200021101031101ffc4001f0000010501010101010100000000000000000102030405060708090a0bffc400b5100002010303020403050504040000017d01020300041105122131410613516107227114328191a1082342b1c11552d1f02433627282090a161718191a25262728292a3435363738393a434445464748494a535455565758595a636465666768696a737475767778797a838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8f9faffc4001f0100030101010101010101010000000000000102030405060708090a0bffc400b51100020102040403040705040400010277000102031104052131061241510761711322328108144291a1b1c109233352f0156272d10a162434e125f11718191a262728292a35363738393a434445464748494a535455565758595a636465666768696a737475767778797a82838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae2e3e4e5e6e7e8e9eaf2f3f4f5f6f7f8f9faffda000c03010002110311003f00e028a28af9e3f610a28a2800a28a2800a28a2800a28a2800a28a2803ffd9";
    var jpeg: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&jpeg, hex);
    const gpa = std.testing.allocator;
    const d = try decode(gpa, &jpeg);
    defer gpa.free(d.bgra);
    try std.testing.expectEqual(@as(u32, 40), d.width);
    try std.testing.expectEqual(@as(u32, 20), d.height);
    try std.testing.expect(d.bgra[2] > 150 and d.bgra[0] < 90 and d.bgra[3] == 255);
    try std.testing.expectEqual(@as(u32, 40), dimensions(&jpeg).?.width);
    try std.testing.expect(dimensions("not a picture") == null);
}
