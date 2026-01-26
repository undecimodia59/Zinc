//! Vim motion and movement functions

const std = @import("std");
const gtk = @import("gtk");

const root = @import("root.zig");

/// Bracket/quote pairs for % matching
const pairs = [_][2]u32{
    .{ '(', ')' },
    .{ '[', ']' },
    .{ '{', '}' },
    .{ '<', '>' },
    .{ '"', '"' },
    .{ '\'', '\'' },
};

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

/// Jump to matching bracket/quote (%)
pub fn matchBracket(buffer: *gtk.TextBuffer) bool {
    var iter: gtk.TextIter = undefined;
    buffer.getIterAtMark(&iter, buffer.getInsert());

    const char = iter.getChar();

    // Find which pair this character belongs to
    for (pairs) |pair| {
        if (char == pair[0]) {
            // Opening bracket - search forward
            if (findMatchingForward(&iter, pair[0], pair[1])) {
                buffer.placeCursor(&iter);
                return true;
            }
            return false;
        } else if (char == pair[1]) {
            // Closing bracket - search backward
            if (findMatchingBackward(&iter, pair[0], pair[1])) {
                buffer.placeCursor(&iter);
                return true;
            }
            return false;
        }
    }

    // Not on a bracket - search forward on line for one
    const line_end = iter.getLine();
    while (iter.getLine() == line_end) {
        const c = iter.getChar();
        for (pairs) |pair| {
            if (c == pair[0] or c == pair[1]) {
                buffer.placeCursor(&iter);
                return matchBracket(buffer);
            }
        }
        if (iter.forwardChar() == 0) break;
    }

    return false;
}

fn findMatchingForward(iter: *gtk.TextIter, open: u32, close: u32) bool {
    var depth: i32 = 1;

    // For quotes, just find next occurrence
    if (open == close) {
        if (iter.forwardChar() == 0) return false;
        while (true) {
            if (iter.getChar() == close) return true;
            if (iter.forwardChar() == 0) return false;
        }
    }

    // For brackets, track nesting
    while (iter.forwardChar() != 0) {
        const c = iter.getChar();
        if (c == open) {
            depth += 1;
        } else if (c == close) {
            depth -= 1;
            if (depth == 0) return true;
        }
    }
    return false;
}

fn findMatchingBackward(iter: *gtk.TextIter, open: u32, close: u32) bool {
    var depth: i32 = 1;

    // For quotes, just find previous occurrence
    if (open == close) {
        if (iter.backwardChar() == 0) return false;
        while (true) {
            if (iter.getChar() == open) return true;
            if (iter.backwardChar() == 0) return false;
        }
    }

    // For brackets, track nesting
    while (iter.backwardChar() != 0) {
        const c = iter.getChar();
        if (c == close) {
            depth += 1;
        } else if (c == open) {
            depth -= 1;
            if (depth == 0) return true;
        }
    }
    return false;
}

/// Find character on current line (f command)
pub fn findCharForward(buffer: *gtk.TextBuffer, char: u32, count: u32, before: bool) bool {
    var iter: gtk.TextIter = undefined;
    buffer.getIterAtMark(&iter, buffer.getInsert());

    const start_line = iter.getLine();
    var found: u32 = 0;

    while (iter.forwardChar() != 0 and iter.getLine() == start_line) {
        if (iter.getChar() == char) {
            found += 1;
            if (found >= count) {
                if (before) {
                    _ = iter.backwardChar();
                }
                buffer.placeCursor(&iter);
                return true;
            }
        }
    }
    return false;
}

/// Find character backward on current line (F command)
pub fn findCharBackward(buffer: *gtk.TextBuffer, char: u32, count: u32, after: bool) bool {
    var iter: gtk.TextIter = undefined;
    buffer.getIterAtMark(&iter, buffer.getInsert());

    const start_line = iter.getLine();
    var found: u32 = 0;

    while (iter.backwardChar() != 0 and iter.getLine() == start_line) {
        if (iter.getChar() == char) {
            found += 1;
            if (found >= count) {
                if (after) {
                    _ = iter.forwardChar();
                }
                buffer.placeCursor(&iter);
                return true;
            }
        }
    }
    return false;
}

/// Move to first non-blank character on line (^)
pub fn moveToFirstNonBlank(buffer: *gtk.TextBuffer) void {
    var iter: gtk.TextIter = undefined;
    buffer.getIterAtMark(&iter, buffer.getInsert());
    iter.setLineOffset(0);

    while (iter.endsLine() == 0) {
        const c = iter.getChar();
        if (c != ' ' and c != '\t') break;
        if (iter.forwardChar() == 0) break;
    }

    buffer.placeCursor(&iter);
}

/// Move to end of word (e command)
pub fn moveToWordEnd(buffer: *gtk.TextBuffer, count: u32) void {
    var iter: gtk.TextIter = undefined;
    buffer.getIterAtMark(&iter, buffer.getInsert());

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // Skip current position
        if (iter.forwardChar() == 0) break;

        // Skip whitespace
        while (iter.isEnd() == 0) {
            const c = iter.getChar();
            if (c != ' ' and c != '\t' and c != '\n') break;
            if (iter.forwardChar() == 0) break;
        }

        // Move to end of word
        while (iter.isEnd() == 0) {
            var next = iter;
            if (next.forwardChar() == 0) break;
            const c = next.getChar();
            if (c == ' ' or c == '\t' or c == '\n') break;
            iter = next;
        }
    }

    buffer.placeCursor(&iter);
}
