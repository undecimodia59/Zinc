const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zinc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add zig-gobject dependency
    const gobject = b.dependency("gobject", .{
        .target = target,
        .optimize = optimize,
    });

    // Import GTK4 and related modules
    exe.root_module.addImport("gtk", gobject.module("gtk4"));
    exe.root_module.addImport("gdk4", gobject.module("gdk4"));
    exe.root_module.addImport("gio", gobject.module("gio2"));
    exe.root_module.addImport("glib", gobject.module("glib2"));
    exe.root_module.addImport("gobject", gobject.module("gobject2"));
    exe.root_module.addImport("cairo1", gobject.module("cairo1"));
    exe.root_module.addImport("pango1", gobject.module("pango1"));

    b.installArtifact(exe);

    // Install desktop assets
    b.installFile("resources/icons/hicolor/256x256/apps/zinc.png", "share/icons/hicolor/256x256/apps/zinc.png");
    b.installFile("resources/zinc.desktop", "share/applications/zinc.desktop");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Pass command line arguments to the executable
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Blueprint compilation step (optional, requires blueprint-compiler)
    const blueprint_step = b.step("blueprints", "Compile Blueprint files to UI XML");
    const blueprint_cmd = b.addSystemCommand(&.{
        "bash",
        "scripts/compile-blueprints.sh",
    });
    blueprint_step.dependOn(&blueprint_cmd.step);
}
