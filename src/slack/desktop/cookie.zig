//! Chromium cookie decryption (Linux and macOS: AES-128-CBC).
//!
//! Verified live against Slack 4.53 (Flatpak) on Linux: values are `v11`
//! prefixed, key = PBKDF2-HMAC-SHA1(keyring password, "saltysalt", 1 round,
//! 16 bytes), IV = 16 spaces, and the plaintext starts with SHA-256(host_key)
//! (Chromium cookie DB v24+). macOS uses 1003 rounds, Linux uses 1.
const std = @import("std");
const builtin = @import("builtin");
const aes = std.crypto.core.aes;

pub const Error = error{ BadFormat, DecryptFailed } || std.mem.Allocator.Error;

pub const rounds: u32 = if (builtin.os.tag == .macos) 1003 else 1;

/// Decrypts one `encrypted_value`. Caller owns the result.
pub fn decrypt(gpa: std.mem.Allocator, encrypted: []const u8, host_key: []const u8, password: []const u8) Error![]u8 {
    if (encrypted.len < 3 + 16) return error.BadFormat;
    const version = encrypted[0..3];
    if (!std.mem.eql(u8, version, "v10") and !std.mem.eql(u8, version, "v11")) return error.BadFormat;
    return decryptCbc(gpa, encrypted[3..], host_key, password, rounds);
}

pub fn decryptCbc(gpa: std.mem.Allocator, ct: []const u8, host_key: []const u8, password: []const u8, n_rounds: u32) Error![]u8 {
    if (ct.len == 0 or ct.len % 16 != 0) return error.BadFormat;
    var key: [16]u8 = undefined;
    std.crypto.pwhash.pbkdf2(&key, password, "saltysalt", n_rounds, std.crypto.auth.hmac.HmacSha1) catch return error.DecryptFailed;
    const ctx = aes.Aes128.initDec(key);

    const out = try gpa.alloc(u8, ct.len);
    errdefer gpa.free(out);
    var prev: [16]u8 = @splat(' ');
    var i: usize = 0;
    while (i < ct.len) : (i += 16) {
        var block: [16]u8 = undefined;
        ctx.decrypt(&block, ct[i..][0..16]);
        for (&block, prev) |*b, p| b.* ^= p;
        @memcpy(out[i..][0..16], &block);
        @memcpy(&prev, ct[i..][0..16]);
    }

    const pad = out[out.len - 1];
    if (pad == 0 or pad > 16 or pad > out.len) return error.DecryptFailed;
    var plain: []u8 = out[0 .. out.len - pad];
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(host_key, &digest, .{});
    if (plain.len >= 32 and std.mem.eql(u8, plain[0..32], &digest)) plain = plain[32..];

    const result = try gpa.dupe(u8, plain);
    @memset(out, 0);
    gpa.free(out);
    return result;
}

test "round trip with host-key hash prefix" {
    const gpa = std.testing.allocator;
    const password = "hunter2";
    var key: [16]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&key, password, "saltysalt", 1, std.crypto.auth.hmac.HmacSha1);
    const ctx = aes.Aes128.initEnc(key);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(".slack.com", &digest, .{});
    // 32-byte hash + "xoxd-test" (9 bytes) + 7 bytes PKCS#7 padding = 48
    var plain: [48]u8 = undefined;
    @memcpy(plain[0..32], &digest);
    @memcpy(plain[32..41], "xoxd-test");
    @memset(plain[41..], 7);
    var ct: [48]u8 = undefined;
    var prev: [16]u8 = @splat(' ');
    var i: usize = 0;
    while (i < 48) : (i += 16) {
        var block: [16]u8 = plain[i..][0..16].*;
        for (&block, prev) |*b, p| b.* ^= p;
        ctx.encrypt(ct[i..][0..16], &block);
        prev = ct[i..][0..16].*;
    }
    const out = try decryptCbc(gpa, &ct, ".slack.com", password, 1);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("xoxd-test", out);
}
