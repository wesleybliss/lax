//! nanoui views. Reads from the store, never from the network layer.
pub const var_list = @import("var_list.zig");
pub const synthetic = @import("synthetic.zig");
pub const chat_view = @import("chat_view.zig");
pub const app_view = @import("app_view.zig");
pub const theme = @import("theme.zig");
pub const composer = @import("composer.zig");
pub const open_url = @import("open_url.zig");
pub const layout = @import("layout.zig");
pub const settings = @import("settings.zig");

test {
    _ = open_url;
    _ = layout;
    _ = settings;
    _ = theme;
    _ = composer;
    _ = @import("tests.zig");
}
