//! Zinc IDE - A lightweight IDE written in Zig with GTK4
//!
//! Entry point for the application.

const std = @import("std");
const gtk = @import("gtk");
const gio = @import("gio");
const gobject = @import("gobject");

const ui_app = @import("ui/app.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Set the global allocator for the app module
    ui_app.setAllocator(alloc);

    // Parse command line arguments
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var initial_path: ?[]const u8 = null;
    defer if (initial_path) |p| alloc.free(p);

    if (args.len > 1) {
        initial_path = try alloc.dupe(u8, args[1]);
    }

    // Initialize GTK application
    const app = gtk.Application.new(
        "com.udsoftware.zinc",
        gio.ApplicationFlags{},
    );
    defer app.as(gobject.Object).unref();

    // Store initial path in app data for later use
    if (initial_path) |path| {
        _ = app.as(gobject.Object).setData("initial_path", @ptrCast(@constCast(path.ptr)));
        _ = app.as(gobject.Object).setData("initial_path_len", @ptrFromInt(path.len));
    }

    // Connect activate signal
    _ = gio.Application.signals.activate.connect(
        app,
        *gtk.Application,
        &ui_app.onActivate,
        app,
        .{},
    );

    // Run the application
    var run_argv = [_][*:0]const u8{std.os.argv[0]};
    _ = app.as(gio.Application).run(1, @ptrCast(&run_argv));

    // Cleanup
    if (ui_app.state) |s| s.deinit();
}
