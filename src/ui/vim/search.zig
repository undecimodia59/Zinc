//! Vim search functionality (/, n, N, *, #)

const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk4");

const app = @import("../app.zig");
const root = @import("root.zig");

/// Search state
pub var pattern: [256]u8 = undefined;
pub var pattern_len: usize = 0;
pub var search_forward: bool = true;

/// Enter search mode
pub fn enter(forward: bool) void {
    root.state.mode = .search;
    root.state.clearCommand();
    search_forward = forward;
    updateSearchStatus();
}

/// Handle key press in search mode
pub fn handleKey(view: *gtk.TextView, keyval: c_uint) bool {
    // Enter executes search
    if (keyval == gdk.KEY_Return or keyval == gdk.KEY_KP_Enter) {
        const query = root.state.getCommand();
        if (query.len > 0) {
            // Save pattern for n/N
            @memcpy(pattern[0..query.len], query);
            pattern_len = query.len;

            // Execute search
            const buffer = view.getBuffer();
            if (search_forward) {
                _ = findNext(buffer);
            } else {
                _ = findPrev(buffer);
            }
        }
        root.enterNormalMode(view);
        return true;
    }

    // Backspace
    if (keyval == gdk.KEY_BackSpace) {
        if (root.state.command_len == 0) {
            root.enterNormalMode(view);
        } else {
            root.state.backspaceCommand();
            updateSearchStatus();
        }
        return true;
    }

    // Printable ASCII characters
    if (keyval >= 0x20 and keyval <= 0x7e) {
        root.state.appendCommand(@intCast(keyval));
        updateSearchStatus();
        return true;
    }

    return true;
}

fn updateSearchStatus() void {
    const s = app.state orelse return;
    var buf: [280:0]u8 = undefined;
    const prefix: u8 = if (search_forward) '/' else '?';
    const cmd = root.state.getCommand();
    const msg = std.fmt.bufPrintZ(&buf, "{c}{s}", .{ prefix, cmd }) catch "/";
    s.setStatus(msg);
}

/// Find next occurrence of saved pattern
pub fn findNext(buffer: *gtk.TextBuffer) bool {
    if (pattern_len == 0) {
        root.showStatus("No search pattern", .{});
        return false;
    }

    var cursor: gtk.TextIter = undefined;
    buffer.getIterAtMark(&cursor, buffer.getInsert());

    // Move one char forward to avoid matching current position
    _ = cursor.forwardChar();

    var match_start: gtk.TextIter = undefined;
    var match_end: gtk.TextIter = undefined;

    const pat = pattern[0..pattern_len];
    const pat_z = app.allocator.allocSentinel(u8, pat.len, 0) catch return false;
    defer app.allocator.free(pat_z);
    @memcpy(pat_z, pat);

    // Search forward from cursor (TEXT_ONLY = 0x2)
    const search_flags = gtk.TextSearchFlags{ .text_only = true };
    if (cursor.forwardSearch(pat_z.ptr, search_flags, &match_start, &match_end, null) != 0) {
        buffer.placeCursor(&match_start);
        buffer.selectRange(&match_start, &match_end);
        root.showStatus("/{s}", .{pat});
        return true;
    }

    // Wrap around to beginning
    var start: gtk.TextIter = undefined;
    buffer.getStartIter(&start);
    if (start.forwardSearch(pat_z.ptr, search_flags, &match_start, &match_end, null) != 0) {
        buffer.placeCursor(&match_start);
        buffer.selectRange(&match_start, &match_end);
        root.showStatus("/{s} [wrapped]", .{pat});
        return true;
    }

    root.showStatus("Pattern not found: {s}", .{pat});
    return false;
}

/// Find previous occurrence of saved pattern
pub fn findPrev(buffer: *gtk.TextBuffer) bool {
    if (pattern_len == 0) {
        root.showStatus("No search pattern", .{});
        return false;
    }

    var cursor: gtk.TextIter = undefined;
    buffer.getIterAtMark(&cursor, buffer.getInsert());

    var match_start: gtk.TextIter = undefined;
    var match_end: gtk.TextIter = undefined;

    const pat = pattern[0..pattern_len];
    const pat_z = app.allocator.allocSentinel(u8, pat.len, 0) catch return false;
    defer app.allocator.free(pat_z);
    @memcpy(pat_z, pat);

    // Search backward from cursor
    const search_flags = gtk.TextSearchFlags{ .text_only = true };
    if (cursor.backwardSearch(pat_z.ptr, search_flags, &match_start, &match_end, null) != 0) {
        buffer.placeCursor(&match_start);
        buffer.selectRange(&match_start, &match_end);
        root.showStatus("?{s}", .{pat});
        return true;
    }

    // Wrap around to end
    var end_iter: gtk.TextIter = undefined;
    buffer.getEndIter(&end_iter);
    if (end_iter.backwardSearch(pat_z.ptr, search_flags, &match_start, &match_end, null) != 0) {
        buffer.placeCursor(&match_start);
        buffer.selectRange(&match_start, &match_end);
        root.showStatus("?{s} [wrapped]", .{pat});
        return true;
    }

    root.showStatus("Pattern not found: {s}", .{pat});
    return false;
}

/// Search for word under cursor (*)
pub fn searchWordUnderCursor(buffer: *gtk.TextBuffer, forward: bool) bool {
    var cursor: gtk.TextIter = undefined;
    buffer.getIterAtMark(&cursor, buffer.getInsert());

    // Find word boundaries
    var word_start = cursor;
    var word_end = cursor;

    // Move to word start
    while (word_start.startsLine() == 0) {
        var prev = word_start;
        if (prev.backwardChar() == 0) break;
        const c = prev.getChar();
        if (!isWordChar(c)) break;
        word_start = prev;
    }

    // Move to word end
    while (word_end.endsLine() == 0) {
        const c = word_end.getChar();
        if (!isWordChar(c)) break;
        if (word_end.forwardChar() == 0) break;
    }

    // Extract word
    const text = buffer.getText(&word_start, &word_end, 0);
    const word = std.mem.span(text);
    defer {
        const glib = @import("glib");
        glib.free(@ptrCast(text));
    }

    if (word.len == 0 or word.len > pattern.len) return false;

    // Save as search pattern
    @memcpy(pattern[0..word.len], word);
    pattern_len = word.len;
    search_forward = forward;

    // Execute search
    if (forward) {
        return findNext(buffer);
    } else {
        return findPrev(buffer);
    }
}

fn isWordChar(c: u32) bool {
    if (c >= 'a' and c <= 'z') return true;
    if (c >= 'A' and c <= 'Z') return true;
    if (c >= '0' and c <= '9') return true;
    if (c == '_') return true;
    return false;
}
