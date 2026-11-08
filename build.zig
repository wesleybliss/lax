const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Protocol layer: no UI imports, ever
    const websocket = b.dependency("websocket", .{ .target = target, .optimize = optimize });
    const slack = b.addModule("slack", .{
        .root_source_file = b.path("src/slack/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "websocket", .module = websocket.module("websocket") }},
    });

    const spike = b.addExecutable(.{
        .name = "spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spike.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "slack", .module = slack }},
        }),
    });
    b.installArtifact(spike);

    const run = b.addRunArtifact(spike);
    run.addPassthruArgs();
    b.step("spike", "Run the protocol spike CLI").dependOn(&run.step);

    // In-memory cache between the network thread and the UI
    const store = b.addModule("store", .{
        .root_source_file = b.path("src/store/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // The running version, for the updater
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", zon.version);

    // Network thread: protocol layer feeding the store
    const app_mod = b.addModule("app", .{
        .root_source_file = b.path("src/app/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "slack", .module = slack },
            .{ .name = "store", .module = store },
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });

    // UI layer: nanoui views over the store. Never imports slack/ directly
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    const ui = b.addModule("ui", .{
        .root_source_file = b.path("src/ui/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "nanoui", .module = nanoui },
            .{ .name = "slack", .module = slack },
            .{ .name = "store", .module = store },
        },
    });

    const lax = b.addExecutable(.{
        .name = "lax",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ui", .module = ui },
                .{ .name = "nanoui", .module = nanoui },
                .{ .name = "app", .module = app_mod },
                .{ .name = "store", .module = store },
            },
        }),
    });
    b.installArtifact(lax);
    const run_lax = b.addRunArtifact(lax);
    run_lax.addPassthruArgs();
    b.step("run", "Run Lax").dependOn(&run_lax.step);

    const net_check = b.addExecutable(.{
        .name = "net-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/net_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "app", .module = app_mod },
                .{ .name = "store", .module = store },
            },
        }),
    });
    b.installArtifact(net_check);
    const run_check = b.addRunArtifact(net_check);
    run_check.addPassthruArgs();
    b.step("net-check", "Headless live check of the network thread").dependOn(&run_check.step);

    const ui_spike = b.addExecutable(.{
        .name = "ui-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui_spike.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ui", .module = ui },
                .{ .name = "nanoui", .module = nanoui },
            },
        }),
    });
    b.installArtifact(ui_spike);
    const run_ui = b.addRunArtifact(ui_spike);
    run_ui.addPassthruArgs();
    b.step("ui-spike", "Open the UI spike window").dependOn(&run_ui.step);

    const tests = b.addTest(.{ .root_module = slack });
    const ui_tests = b.addTest(.{ .root_module = ui });
    const app_tests = b.addTest(.{ .root_module = app_mod });
    const store_tests = b.addTest(.{ .root_module = store });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(store_tests).step);
    test_step.dependOn(&b.addRunArtifact(app_tests).step);
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(ui_tests).step);
}
