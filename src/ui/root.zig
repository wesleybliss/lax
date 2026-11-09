//! nanoui views. Reads from the store, never from the network layer.
pub const var_list = @import("var_list.zig");
pub const synthetic = @import("synthetic.zig");
pub const chat_view = @import("chat_view.zig");
pub const app_view = @import("app_view.zig");
pub const theme = @import("theme.zig");
pub const composer = @import("composer.zig");
pub const attachments = @import("attachments.zig");
pub const open_url = @import("open_url.zig");
pub const notify = @import("notify.zig");
pub const layout = @import("layout.zig");
pub const settings = @import("settings.zig");
pub const message_menu = @import("message_menu.zig");
pub const recents = @import("recents.zig");

test {
    _ = open_url;
    _ = notify;
    _ = layout;
    _ = settings;
    _ = message_menu;
    _ = recents;
    _ = theme;
    _ = composer;
    _ = attachments;
    _ = @import("tests.zig");
}
