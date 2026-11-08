//! Glue between the Slack protocol layer and the store.
pub const net = @import("net.zig");
pub const state_file = @import("state_file.zig");
pub const updater = @import("updater.zig");

test {
    _ = net;
    _ = state_file;
    _ = updater;
}
