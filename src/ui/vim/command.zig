//! Vim command mode (:w, :q, :!cmd, etc.)

const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk4");

const app = @import("../app.zig");
const root = @import("root.zig");

/// Enter command mode
pub fn enter(view: *gtk.TextView) void {
    _ = view;
    root.state.mode = .command;
    root.state.clearCommand();
    root.updateStatusBar();
}

/// Handle key press in command mode
pub fn handleKey(view: *gtk.TextView, keyval: c_uint) bool {
    // Enter executes command
    if (keyval == gdk.KEY_Return or keyval == gdk.KEY_KP_Enter) {
        execute(view, root.state.getCommand());
        root.enterNormalMode(view);
        return true;
    }

    // Backspace
    if (keyval == gdk.KEY_BackSpace) {
        if (root.state.command_len == 0) {
            root.enterNormalMode(view);
        } else {
            root.state.backspaceCommand();
            root.updateStatusBar();
        }
        return true;
    }

    // Printable ASCII characters
    if (keyval >= 0x20 and keyval <= 0x7e) {
        root.state.appendCommand(@intCast(keyval));
        root.updateStatusBar();
        return true;
    }

    return true; // Block all other keys in command mode
}

/// Execute a vim command
pub fn execute(view: *gtk.TextView, cmd: []const u8) void {
    if (cmd.len == 0) return;

    // :w - save
    if (std.mem.eql(u8, cmd, "w")) {
        const editor = @import("../editor/root.zig");
        editor.saveCurrentFile();
        return;
    }

    // :q - quit
    if (std.mem.eql(u8, cmd, "q")) {
        const s = app.state orelse return;
        s.window.as(gtk.Window).close();
        return;
    }

    // :wq - save and quit
    if (std.mem.eql(u8, cmd, "wq")) {
        const editor = @import("../editor/root.zig");
        editor.saveCurrentFile();
        const s = app.state orelse return;
        s.window.as(gtk.Window).close();
        return;
    }

    // :q! - force quit (no save check)
    if (std.mem.eql(u8, cmd, "q!")) {
        const s = app.state orelse return;
        s.window.as(gtk.Window).close();
        return;
    }

    // :!<cmd> - shell command
    if (cmd.len > 1 and cmd[0] == '!') {
        executeShell(view, cmd[1..]);
        return;
    }

    // :e <file> - open file
    if (cmd.len > 2 and std.mem.startsWith(u8, cmd, "e ")) {
        const path = std.mem.trim(u8, cmd[2..], " ");
        if (path.len > 0) {
            const editor = @import("../editor/root.zig");
            editor.loadFile(path);
        }
        return;
    }

    // Unknown command
    root.showStatus("Unknown command: {s}", .{cmd});
}

/// Execute a shell command and show output in popup
fn executeShell(view: *gtk.TextView, cmd: []const u8) void {
    _ = view;

    // Execute command
    const result = std.process.Child.run(.{
        .allocator = app.allocator,
        .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
    }) catch |err| {
        root.showStatus("Failed to run command: {}", .{err});
        return;
    };
    defer {
        app.allocator.free(result.stdout);
        app.allocator.free(result.stderr);
    }

    // Show output in dialog
    const output = if (result.stdout.len > 0) result.stdout else result.stderr;
    showOutputDialog(output, cmd);
}

/// Show command output in a popup dialog
fn showOutputDialog(output: []const u8, cmd: []const u8) void {
    const s = app.state orelse return;

    // Create dialog
    const dialog = gtk.Window.new();
    dialog.setTitle("Command Output");
    dialog.setDefaultSize(600, 400);
    dialog.setTransientFor(s.window.as(gtk.Window));
    dialog.setModal(1);

    const vbox = gtk.Box.new(gtk.Orientation.vertical, 8);
    vbox.as(gtk.Widget).setMarginStart(12);
    vbox.as(gtk.Widget).setMarginEnd(12);
    vbox.as(gtk.Widget).setMarginTop(12);
    vbox.as(gtk.Widget).setMarginBottom(12);

    // Command label
    var title_buf: [256:0]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "$ {s}", .{cmd}) catch ":!command";
    const label = gtk.Label.new(title.ptr);
    label.as(gtk.Widget).setHalign(gtk.Align.start);
    vbox.append(label.as(gtk.Widget));

    // Scrolled text view for output
    const scroll = gtk.ScrolledWindow.new();
    scroll.as(gtk.Widget).setVexpand(1);
    scroll.as(gtk.Widget).setHexpand(1);

    const text_view = gtk.TextView.new();
    text_view.setEditable(0);
    text_view.setMonospace(1);

    // Set output text
    const buffer = text_view.getBuffer();
    if (output.len > 0) {
        const output_z = app.allocator.dupeZ(u8, output) catch return;
        defer app.allocator.free(output_z);
        buffer.setText(output_z.ptr, @intCast(output.len));
    } else {
        buffer.setText("(no output)", -1);
    }

    scroll.setChild(text_view.as(gtk.Widget));
    vbox.append(scroll.as(gtk.Widget));

    // Close button
    const close_btn = gtk.Button.newWithLabel("Close (Enter)");
    close_btn.as(gtk.Widget).setHalign(gtk.Align.end);
    _ = gtk.Button.signals.clicked.connect(close_btn, *gtk.Window, &onDialogClose, dialog, .{});
    vbox.append(close_btn.as(gtk.Widget));

    // Add key controller for Enter/Escape to close
    const key_controller = gtk.EventControllerKey.new();
    dialog.as(gtk.Widget).addController(key_controller.as(gtk.EventController));
    _ = gtk.EventControllerKey.signals.key_pressed.connect(
        key_controller,
        *gtk.Window,
        &onDialogKeyPress,
        dialog,
        .{},
    );

    dialog.setChild(vbox.as(gtk.Widget));
    dialog.as(gtk.Widget).setVisible(1);
}

fn onDialogClose(_: *gtk.Button, dialog: *gtk.Window) callconv(.c) void {
    dialog.close();
}

fn onDialogKeyPress(
    _: *gtk.EventControllerKey,
    keyval: c_uint,
    _: c_uint,
    _: gdk.ModifierType,
    dialog: *gtk.Window,
) callconv(.c) c_int {
    // Close on Enter or Escape
    if (keyval == gdk.KEY_Return or keyval == gdk.KEY_KP_Enter or keyval == gdk.KEY_Escape) {
        dialog.close();
        return 1;
    }
    return 0;
}
