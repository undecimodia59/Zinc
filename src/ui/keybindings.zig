//! Keyboard shortcuts and keybinding management
//!
//! This module handles all keyboard shortcuts for the Zinc editor.
//! Keybindings are processed in a single handler attached to the main window.
//!
//! ## Current Keybindings
//!
//! | Shortcut | Action | Description |
//! |----------|--------|-------------|
//! | Ctrl+S   | Save   | Save the current file to disk |
//! | Ctrl+E   | Toggle Tree | Show/hide file tree (focuses tree when shown, editor when hidden) |
//! | Ctrl+=   | Zoom In | Increase font size |
//! | Ctrl+-   | Zoom Out | Decrease font size |
//! | Tab      | Insert | Inserts spaces or tab based on config (use_spaces setting) |
//!
//! ## Adding New Keybindings
//!
//! To add a new keybinding:
//! 1. Add a new case in `handleKeyPress`
//! 2. Document it in the table above
//! 3. Implement the action function or call existing module functions

const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk4");

const app = @import("app.zig");
const editor = @import("editor/root.zig");
const file_tree = @import("file_tree.zig");

/// Attach the key controller to the main window.
/// Call this once during app initialization.
pub fn attach(window: *gtk.ApplicationWindow) void {
    const controller = gtk.EventControllerKey.new();
    controller.as(gtk.EventController).setPropagationPhase(.capture);
    window.as(gtk.Widget).addController(controller.as(gtk.EventController));

    _ = gtk.EventControllerKey.signals.key_pressed.connect(
        controller,
        *gtk.EventControllerKey,
        &handleKeyPress,
        controller,
        .{},
    );
}

/// Main key press handler.
/// Returns 1 if the key was handled, 0 to propagate to other handlers.
fn handleKeyPress(
    _: *gtk.EventControllerKey,
    keyval: c_uint,
    _: c_uint,
    modifiers: gdk.ModifierType,
    _: *gtk.EventControllerKey,
) callconv(.c) c_int {
    const key = gdk.keyvalToLower(keyval);
    _ = gdk.keyvalToUnicode(keyval);

    // Ctrl+S: Save current file
    if (modifiers.control_mask and ctrlKeyMatches(key, keyval, 's')) {
        editor.saveCurrentFile();
        return 1;
    }

    // Ctrl+E: Toggle file tree visibility
    if (modifiers.control_mask and ctrlKeyMatches(key, keyval, 'e')) {
        toggleFileTree();
        return 1;
    }

    // Ctrl+=: Increase font size (= is same key as +)
    if (modifiers.control_mask and (key == '=' or key == '+' or keyval == 0xffab)) {
        changeFontSize(1);
        return 1;
    }

    // Ctrl+-: Decrease font size
    if (modifiers.control_mask and (key == '-' or keyval == 0xffad)) {
        changeFontSize(-1);
        return 1;
    }

    // Key not handled, let GTK process it
    return 0;
}

fn ctrlKeyMatches(key_lower: c_uint, raw_keyval: c_uint, ascii_lower: u8) bool {
    if (key_lower == ascii_lower) return true;
    const uni = gdk.keyvalToUnicode(raw_keyval);
    if (uni >= 1 and uni <= 26) {
        return @as(u8, @intCast(uni - 1 + 'a')) == ascii_lower;
    }
    return false;
}

// ============================================================================
// Action implementations
// ============================================================================

/// Change font size by delta (positive to increase, negative to decrease).
fn changeFontSize(delta: i16) void {
    const state = app.state orelse return;
    const cfg = state.config;

    const current: i16 = @intCast(cfg.editor.font_size);
    const new_size = @max(8, @min(48, current + delta));
    cfg.editor.font_size = @intCast(new_size);

    // Apply changes to editor and file tree
    editor.applyConfig(cfg);
    file_tree.applyConfig(state.file_tree, cfg);
    cfg.save() catch {};

    // Show status
    var buf: [64:0]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, "Font size: {d}pt", .{cfg.editor.font_size}) catch "Font size changed";
    state.setStatus(msg);
}

/// Toggle the file tree sidebar visibility.
/// Remembers the previous width when hiding so it can be restored.
/// When showing: focuses the file tree for keyboard navigation.
/// When hiding: focuses the editor.
fn toggleFileTree() void {
    const state = app.state orelse return;
    const paned = state.paned;

    const current = paned.getStartChild();
    if (current != null) {
        // Hide: save position, remove child, focus editor
        state.file_tree_position = paned.getPosition();
        paned.setStartChild(null);
        _ = state.code_view.as(gtk.Widget).grabFocus();
        return;
    }

    // Show: restore child and position, focus file tree
    paned.setStartChild(state.file_tree_scroll.as(gtk.Widget));
    if (state.file_tree_position <= 0) {
        state.file_tree_position = 250;
    }
    paned.setPosition(state.file_tree_position);
    _ = state.file_tree.as(gtk.Widget).grabFocus();
}
