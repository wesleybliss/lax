//! A self-pipe: any thread calls `signal`, and the read end becomes readable
//! so the UI thread's event loop (nanoui's `fdwatch`) wakes up.
const std = @import("std");

extern "c" fn pipe2(fds: *[2]c_int, flags: c_int) c_int;
extern "c" fn write(fd: c_int, buf: *const anyopaque, n: usize) isize;
extern "c" fn read(fd: c_int, buf: *anyopaque, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;

const O_NONBLOCK: c_int = 0o4000;
const O_CLOEXEC: c_int = 0o2000000;

pub const Wake = struct {
    read_fd: c_int,
    write_fd: c_int,

    pub fn init() error{PipeFailed}!Wake {
        var fds: [2]c_int = undefined;
        if (pipe2(&fds, O_NONBLOCK | O_CLOEXEC) != 0) return error.PipeFailed;
        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }

    pub fn deinit(w: *Wake) void {
        _ = close(w.read_fd);
        _ = close(w.write_fd);
    }

    /// Safe from any thread. A full pipe already means "wake pending".
    pub fn signal(w: *const Wake) void {
        const byte: u8 = 1;
        _ = write(w.write_fd, &byte, 1);
    }

    /// Empties the pipe; call from the woken thread before draining queues
    pub fn drain(w: *const Wake) void {
        var buf: [64]u8 = undefined;
        while (read(w.read_fd, &buf, buf.len) > 0) {}
    }
};

test "signal makes the pipe readable once, drain empties it" {
    var w = try Wake.init();
    defer w.deinit();
    w.signal();
    w.signal();
    var buf: [1]u8 = undefined;
    try std.testing.expect(read(w.read_fd, &buf, 1) == 1);
    w.drain();
    try std.testing.expect(read(w.read_fd, &buf, 1) < 0);
}
