//! Vim operators (delete, yank, change, paste)

const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk4");
const glib = @import("glib");
const gio = @import("gio");
const gobject = @import("gobject");

const app = @import("../app.zig");
const root = @import("root.zig");
const motions = @import("motions.zig");

/// Operator types
pub const Operator = enum {
    none,
    delete,
    yank,
    change,
};

/// Apply operator with motion
pub fn operatorMotion(view: *gtk.TextView, buffer: *gtk.TextBuffer, motion: motions.Motion, count: u32) void {
    var start: gtk.TextIter = undefined;
    var end: gtk.TextIter = undefined;
    buffer.getIterAtMark(&start, buffer.getInsert());
    end = start;

    motions.applyMotion(&end, motion, count);

    // Ensure start < end
    if (start.compare(&end) > 0) {
        const tmp = start;
        start = end;
        end = tmp;
    }

    const op = root.state.pending_operator;
    root.state.pending_operator = .none;

    switch (op) {
        .delete => {
            copyToClipboard(view, buffer, &start, &end);
            buffer.delete(&start, &end);
        },
        .yank => {
            copyToClipboard(view, buffer, &start, &end);
            buffer.placeCursor(&start);
        },
        .change => {
            copyToClipboard(view, buffer, &start, &end);
            buffer.delete(&start, &end);
            root.enterInsertMode(view);
        },
        .none => {},
    }
}

/// Delete entire line(s)
pub fn deleteLine(view: *gtk.TextView, buffer: *gtk.TextBuffer, count: u32) void {
    var start: gtk.TextIter = undefined;
    var end: gtk.TextIter = undefined;
    buffer.getIterAtMark(&start, buffer.getInsert());
    start.setLineOffset(0);
    end = start;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (end.forwardLine() == 0) {
            // At last line, delete to end
            _ = end.forwardToEnd();
            break;
        }
    }

    copyToClipboard(view, buffer, &start, &end);
    buffer.delete(&start, &end);
}

/// Yank (copy) entire line(s)
pub fn yankLine(view: *gtk.TextView, buffer: *gtk.TextBuffer, count: u32) void {
    var start: gtk.TextIter = undefined;
    var end: gtk.TextIter = undefined;
    buffer.getIterAtMark(&start, buffer.getInsert());
    start.setLineOffset(0);
    end = start;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (end.forwardLine() == 0) {
            _ = end.forwardToEnd();
            break;
        }
    }

    copyToClipboard(view, buffer, &start, &end);
    root.showStatus("Yanked {d} line(s)", .{count});
}

/// Change entire line(s)
pub fn changeLine(view: *gtk.TextView, buffer: *gtk.TextBuffer, count: u32) void {
    var start: gtk.TextIter = undefined;
    var end: gtk.TextIter = undefined;
    buffer.getIterAtMark(&start, buffer.getInsert());
    start.setLineOffset(0);
    end = start;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        _ = end.forwardToLineEnd();
        if (i < count - 1) {
            _ = end.forwardChar(); // Include newline except for last line
        }
    }

    copyToClipboard(view, buffer, &start, &end);
    buffer.delete(&start, &end);
    root.enterInsertMode(view);
}

/// Delete character(s) under cursor
pub fn deleteChar(view: *gtk.TextView, buffer: *gtk.TextBuffer, count: u32) void {
    var start: gtk.TextIter = undefined;
    var end: gtk.TextIter = undefined;
    buffer.getIterAtMark(&start, buffer.getInsert());
    end = start;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (end.forwardChar() == 0) break;
    }

    copyToClipboard(view, buffer, &start, &end);
    buffer.delete(&start, &end);
}

/// Delete visual selection
pub fn deleteSelection(view: *gtk.TextView, buffer: *gtk.TextBuffer) void {
    var start: gtk.TextIter = undefined;
    var end: gtk.TextIter = undefined;
    if (buffer.getSelectionBounds(&start, &end) != 0) {
        copyToClipboard(view, buffer, &start, &end);
        buffer.delete(&start, &end);
    }
}

/// Yank visual selection
pub fn yankSelection(view: *gtk.TextView, buffer: *gtk.TextBuffer) void {
    var start: gtk.TextIter = undefined;
    var end: gtk.TextIter = undefined;
    if (buffer.getSelectionBounds(&start, &end) != 0) {
        copyToClipboard(view, buffer, &start, &end);
        // Clear selection, place cursor at start
        buffer.placeCursor(&start);
    }
}

/// Copy text range to system clipboard
pub fn copyToClipboard(view: *gtk.TextView, buffer: *gtk.TextBuffer, start: *gtk.TextIter, end: *gtk.TextIter) void {
    const text = buffer.getText(start, end, 0);
    defer glib.free(text);

    const display = view.as(gtk.Widget).getDisplay();
    const clipboard = display.getClipboard();
    clipboard.setText(text);
}

/// Paste from clipboard
pub fn paste(view: *gtk.TextView, buffer: *gtk.TextBuffer, before: bool) void {
    _ = buffer;
    _ = before;
    const display = view.as(gtk.Widget).getDisplay();
    const clipboard = display.getClipboard();

    // Request clipboard content asynchronously
    clipboard.readTextAsync(null, &onClipboardRead, view);
}

fn onClipboardRead(
    source: ?*gobject.Object,
    result: *gio.AsyncResult,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = source;
    const view: *gtk.TextView = @ptrCast(@alignCast(user_data orelse return));

    const display = view.as(gtk.Widget).getDisplay();
    const clipboard = display.getClipboard();

    var err: ?*glib.Error = null;
    const text = clipboard.readTextFinish(result, &err) orelse return;
    defer glib.free(text);

    if (err) |e| {
        glib.Error.free(e);
        return;
    }

    const buffer = view.getBuffer();
    const was_editable = view.getEditable();

    // Temporarily enable editing for paste
    view.setEditable(1);
    buffer.insertAtCursor(text, -1);
    view.setEditable(was_editable);
}

/// Open new line below and enter insert mode
pub fn openLineBelow(view: *gtk.TextView, buffer: *gtk.TextBuffer) void {
    var iter: gtk.TextIter = undefined;
    buffer.getIterAtMark(&iter, buffer.getInsert());
    _ = iter.forwardToLineEnd();
    buffer.placeCursor(&iter);

    // Need to temporarily enable editing to insert
    view.setEditable(1);
    buffer.insertAtCursor("\n", 1);
    root.enterInsertMode(view);
}

/// Open new line above and enter insert mode
pub fn openLineAbove(view: *gtk.TextView, buffer: *gtk.TextBuffer) void {
    var iter: gtk.TextIter = undefined;
    buffer.getIterAtMark(&iter, buffer.getInsert());
    iter.setLineOffset(0);
    buffer.placeCursor(&iter);

    view.setEditable(1);
    buffer.insertAtCursor("\n", 1);
    // Move back to the new empty line
    buffer.getIterAtMark(&iter, buffer.getInsert());
    _ = iter.backwardChar();
    buffer.placeCursor(&iter);
    root.enterInsertMode(view);
}
