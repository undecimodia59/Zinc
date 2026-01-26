//! Vim motion and movement functions

const std = @import("std");
const gtk = @import("gtk");

const root = @import("root.zig");

/// Movement types
pub const Motion = enum {
    left,
    right,
    up,
    down,
    word_forward,
    word_backward,
    line_start,
    line_end,
    file_start,
    file_end,
};

/// Move cursor by motion
pub fn move(buffer: *gtk.TextBuffer, motion: Motion, count: u32) void {
    var iter: gtk.TextIter = undefined;
    buffer.getIterAtMark(&iter, buffer.getInsert());
    applyMotion(&iter, motion, count);
    buffer.placeCursor(&iter);
}

/// Move cursor to absolute position
pub fn moveTo(buffer: *gtk.TextBuffer, motion: Motion, count: u32) void {
    var iter: gtk.TextIter = undefined;

    switch (motion) {
        .file_start => buffer.getStartIter(&iter),
        .file_end => buffer.getEndIter(&iter),
        else => {
            buffer.getIterAtMark(&iter, buffer.getInsert());
            applyMotion(&iter, motion, count);
        },
    }
    buffer.placeCursor(&iter);
}

/// Go to specific line number
pub fn gotoLine(buffer: *gtk.TextBuffer, line: u32) void {
    var iter: gtk.TextIter = undefined;
    const total_lines = buffer.getLineCount();
    const target_line: i32 = @intCast(@min(line, @as(u32, @intCast(total_lines))));
    _ = buffer.getIterAtLine(&iter, target_line - 1); // 0-indexed
    buffer.placeCursor(&iter);
}

/// Apply motion to iterator
pub fn applyMotion(iter: *gtk.TextIter, motion: Motion, count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        switch (motion) {
            .left => {
                _ = iter.backwardChar();
            },
            .right => {
                _ = iter.forwardChar();
            },
            .up => {
                _ = iter.backwardLine();
            },
            .down => {
                _ = iter.forwardLine();
            },
            .word_forward => {
                _ = iter.forwardWordEnd();
                _ = iter.forwardChar();
            },
            .word_backward => {
                _ = iter.backwardWordStart();
            },
            .line_start => {
                iter.setLineOffset(0);
            },
            .line_end => {
                _ = iter.forwardToLineEnd();
            },
            .file_start => {
                iter.setOffset(0);
            },
            .file_end => {
                _ = iter.forwardToEnd();
            },
        }
    }
}

/// Extend visual selection by motion
pub fn extendSelection(view: *gtk.TextView, buffer: *gtk.TextBuffer, motion: Motion, count: u32) void {
    _ = view;

    // Get the anchor (visual start) - this stays fixed
    var anchor = root.state.visual_start orelse {
        // Shouldn't happen, but fallback to cursor
        var iter: gtk.TextIter = undefined;
        buffer.getIterAtMark(&iter, buffer.getInsert());
        root.state.visual_start = iter;
        return;
    };

    // Get current cursor position and move it
    var cursor: gtk.TextIter = undefined;
    buffer.getIterAtMark(&cursor, buffer.getInsert());
    applyMotion(&cursor, motion, count);

    // In visual line mode, extend to full lines
    if (root.state.mode == .visual_line) {
        if (anchor.compare(&cursor) <= 0) {
            // Cursor is after anchor
            anchor.setLineOffset(0);
            _ = cursor.forwardToLineEnd();
            _ = cursor.forwardChar();
        } else {
            // Cursor is before anchor
            cursor.setLineOffset(0);
            _ = anchor.forwardToLineEnd();
            _ = anchor.forwardChar();
        }
    }

    // Select from anchor to cursor (order matters for cursor position)
    buffer.selectRange(&anchor, &cursor);
}
