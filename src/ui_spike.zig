//! UI spike window: 10k synthetic messages and a multiline composer.
//! Usage: ui-spike [message-count]
const std = @import("std");
const nanoui = @import("nanoui");
const chat = @import("ui").chat_view;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const count: usize = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 10_000;

    const app = try nanoui.App.create(init, .{ .name = "Lax" });
    defer app.destroy();
    var state: chat.State = undefined;
    try state.init(init.gpa, count);
    defer state.deinit();
    _ = try app.newWindow(.{
        .title = "Lax",
        .width = 900,
        .height = 700,
        .content = .{ .view = .init(&state, chat.State.view) },
    });
    try app.run();
}
