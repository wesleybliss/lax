//! A mutex-guarded batch queue: any thread pushes, the consumer takes
//! everything at once.
const std = @import("std");

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();
        mutex: std.Io.Mutex = .init,
        items: std.ArrayList(T) = .empty,

        pub fn deinit(q: *Self, gpa: std.mem.Allocator) void {
            q.items.deinit(gpa);
        }

        pub fn push(q: *Self, gpa: std.mem.Allocator, io: std.Io, item: T) std.mem.Allocator.Error!void {
            q.mutex.lockUncancelable(io);
            defer q.mutex.unlock(io);
            try q.items.append(gpa, item);
        }

        pub fn isEmpty(q: *Self, io: std.Io) bool {
            q.mutex.lockUncancelable(io);
            defer q.mutex.unlock(io);
            return q.items.items.len == 0;
        }

        /// Moves everything queued into `out` (appending)
        pub fn drain(q: *Self, gpa: std.mem.Allocator, io: std.Io, out: *std.ArrayList(T)) std.mem.Allocator.Error!void {
            q.mutex.lockUncancelable(io);
            defer q.mutex.unlock(io);
            try out.appendSlice(gpa, q.items.items);
            q.items.clearRetainingCapacity();
        }
    };
}

test "push and drain" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var q: Queue(u32) = .{};
    defer q.deinit(gpa);
    try q.push(gpa, io, 1);
    try q.push(gpa, io, 2);
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    try q.drain(gpa, io, &out);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, out.items);
    try q.drain(gpa, io, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
}
