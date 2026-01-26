//! Vim mode implementation for Zinc editor
//!
//! Provides modal editing with Normal, Insert, Visual, and Command modes.
//!
//! ## Supported Commands
//!
//! ### Normal Mode
//! | Key | Action |
//! |-----|--------|
//! | h, Left | Move left |
//! | j, Down | Move down |
//! | k, Up | Move up |
//! | l, Right | Move right |
//! | w | Move to next word start |
//! | b | Move to previous word start |
//! | 0 | Move to line start |
//! | $ | Move to line end |
//! | gg | Move to file start |
//! | G | Move to file end |
//! | i | Enter Insert mode |
//! | a | Enter Insert mode after cursor |
//! | A | Enter Insert mode at line end |
//! | o | Open line below, enter Insert |
//! | O | Open line above, enter Insert |
//! | v | Enter Visual mode |
//! | V | Enter Visual Line mode |
//! | d | Delete (with motion or selection) |
//! | y | Yank (copy to clipboard) |
//! | p | Paste after cursor |
//! | P | Paste before cursor |
//! | x | Delete character under cursor |
//! | dd | Delete entire line |
//! | yy | Yank entire line |
//! | : | Enter Command mode |
//! | [count] | Prefix for repeat count |
//!
//! ### Insert Mode
//! | Key | Action |
//! |-----|--------|
//! | Escape | Return to Normal mode |
//!
//! ### Visual Mode
//! | Key | Action |
//! |-----|--------|
//! | Escape | Return to Normal mode |
//! | d | Delete selection |
//! | y | Yank selection |
//! | w, b | Extend selection by word |
//!
//! ### Command Mode
//! | Command | Action |
//! |---------|--------|
//! | :w | Save file |
//! | :q | Quit |
//! | :wq | Save and quit |
//! | :q! | Force quit |
//! | :e file | Open file |
//! | :!cmd | Run shell command |

const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk4");

const app = @import("../app.zig");
const command = @import("command.zig");
const motions = @import("motions.zig");
const operators = @import("operators.zig");

// Re-export for other modules
pub const Motion = motions.Motion;
pub const Operator = operators.Operator;

pub const Mode = enum {
    normal,
    insert,
    visual,
    visual_line,
    command,
};

pub const State = struct {
    mode: Mode = .normal,
    count: u32 = 0,
    pending_operator: Operator = .none,
    pending_g: bool = false,
    visual_start: ?gtk.TextIter = null,
    command_buffer: [256]u8 = undefined,
    command_len: usize = 0,

    pub fn reset(self: *State) void {
        self.count = 0;
        self.pending_operator = .none;
        self.pending_g = false;
    }

    pub fn getCount(self: *State) u32 {
        return if (self.count == 0) 1 else self.count;
    }

    pub fn addDigit(self: *State, digit: u8) void {
        if (self.count > 100000) return;
        self.count = self.count * 10 + digit;
    }

    pub fn appendCommand(self: *State, char: u8) void {
        if (self.command_len < self.command_buffer.len - 1) {
            self.command_buffer[self.command_len] = char;
            self.command_len += 1;
        }
    }

    pub fn backspaceCommand(self: *State) void {
        if (self.command_len > 0) {
            self.command_len -= 1;
        }
    }

    pub fn getCommand(self: *State) []const u8 {
        return self.command_buffer[0..self.command_len];
    }

    pub fn clearCommand(self: *State) void {
        self.command_len = 0;
    }
};

/// Global vim state
pub var state: State = .{};

/// Handle key press in vim mode. Returns true if handled.
pub fn handleKey(
    view: *gtk.TextView,
    keyval: c_uint,
    modifiers: gdk.ModifierType,
) bool {
    const buffer = view.getBuffer();

    // Escape always returns to normal mode
    if (keyval == gdk.KEY_Escape) {
        if (state.mode != .normal) {
            enterNormalMode(view);
            return true;
        }
        state.reset();
        return true;
    }

    return switch (state.mode) {
        .normal => handleNormalMode(view, buffer, keyval, modifiers),
        .insert => false, // Let GTK handle insert mode
        .visual, .visual_line => handleVisualMode(view, buffer, keyval, modifiers),
        .command => command.handleKey(view, keyval),
    };
}

fn handleNormalMode(
    view: *gtk.TextView,
    buffer: *gtk.TextBuffer,
    keyval: c_uint,
    modifiers: gdk.ModifierType,
) bool {
    _ = modifiers;

    // Handle pending g command
    if (state.pending_g) {
        state.pending_g = false;
        if (keyval == 'g') {
            motions.moveTo(buffer, .file_start, state.getCount());
            state.reset();
            return true;
        }
        state.reset();
        return false;
    }

    // Count prefix (digits 1-9, or 0 if count already started)
    if (keyval >= '1' and keyval <= '9') {
        state.addDigit(@intCast(keyval - '0'));
        return true;
    }
    if (keyval == '0' and state.count > 0) {
        state.addDigit(0);
        return true;
    }

    // Movement keys
    switch (keyval) {
        'h', gdk.KEY_Left => {
            motions.move(buffer, .left, state.getCount());
            state.reset();
            return true;
        },
        'j', gdk.KEY_Down => {
            motions.move(buffer, .down, state.getCount());
            state.reset();
            return true;
        },
        'k', gdk.KEY_Up => {
            motions.move(buffer, .up, state.getCount());
            state.reset();
            return true;
        },
        'l', gdk.KEY_Right => {
            motions.move(buffer, .right, state.getCount());
            state.reset();
            return true;
        },
        'w' => {
            if (state.pending_operator != .none) {
                operators.operatorMotion(view, buffer, .word_forward, state.getCount());
            } else {
                motions.move(buffer, .word_forward, state.getCount());
            }
            state.reset();
            return true;
        },
        'b' => {
            if (state.pending_operator != .none) {
                operators.operatorMotion(view, buffer, .word_backward, state.getCount());
            } else {
                motions.move(buffer, .word_backward, state.getCount());
            }
            state.reset();
            return true;
        },
        '0' => {
            motions.move(buffer, .line_start, 1);
            state.reset();
            return true;
        },
        '$' => {
            motions.move(buffer, .line_end, 1);
            state.reset();
            return true;
        },
        'g' => {
            state.pending_g = true;
            return true;
        },
        'G' => {
            if (state.count > 0) {
                motions.gotoLine(buffer, state.count);
            } else {
                motions.moveTo(buffer, .file_end, 1);
            }
            state.reset();
            return true;
        },

        // Mode switching
        'i' => {
            enterInsertMode(view);
            state.reset();
            return true;
        },
        'a' => {
            motions.move(buffer, .right, 1);
            enterInsertMode(view);
            state.reset();
            return true;
        },
        'A' => {
            motions.move(buffer, .line_end, 1);
            enterInsertMode(view);
            state.reset();
            return true;
        },
        'o' => {
            operators.openLineBelow(view, buffer);
            state.reset();
            return true;
        },
        'O' => {
            operators.openLineAbove(view, buffer);
            state.reset();
            return true;
        },
        'v' => {
            enterVisualMode(view, buffer, false);
            state.reset();
            return true;
        },
        'V' => {
            enterVisualMode(view, buffer, true);
            state.reset();
            return true;
        },

        // Operators
        'd' => {
            if (state.pending_operator == .delete) {
                operators.deleteLine(view, buffer, state.getCount());
                state.reset();
                return true;
            }
            state.pending_operator = .delete;
            return true;
        },
        'y' => {
            if (state.pending_operator == .yank) {
                operators.yankLine(view, buffer, state.getCount());
                state.reset();
                return true;
            }
            state.pending_operator = .yank;
            return true;
        },
        'c' => {
            if (state.pending_operator == .change) {
                operators.changeLine(view, buffer, state.getCount());
                state.reset();
                return true;
            }
            state.pending_operator = .change;
            return true;
        },
        'x' => {
            operators.deleteChar(view, buffer, state.getCount());
            state.reset();
            return true;
        },
        'p' => {
            operators.paste(view, buffer, false);
            state.reset();
            return true;
        },
        'P' => {
            operators.paste(view, buffer, true);
            state.reset();
            return true;
        },
        ':' => {
            command.enter(view);
            state.reset();
            return true;
        },

        else => {
            state.reset();
            return false;
        },
    }
}

fn handleVisualMode(
    view: *gtk.TextView,
    buffer: *gtk.TextBuffer,
    keyval: c_uint,
    modifiers: gdk.ModifierType,
) bool {
    _ = modifiers;

    // Handle pending g command
    if (state.pending_g) {
        state.pending_g = false;
        if (keyval == 'g') {
            motions.extendSelection(view, buffer, .file_start, 1);
            state.reset();
            return true;
        }
        state.reset();
        return false;
    }

    switch (keyval) {
        // Movement extends selection
        'h', gdk.KEY_Left => {
            motions.extendSelection(view, buffer, .left, state.getCount());
            state.reset();
            return true;
        },
        'j', gdk.KEY_Down => {
            motions.extendSelection(view, buffer, .down, state.getCount());
            state.reset();
            return true;
        },
        'k', gdk.KEY_Up => {
            motions.extendSelection(view, buffer, .up, state.getCount());
            state.reset();
            return true;
        },
        'l', gdk.KEY_Right => {
            motions.extendSelection(view, buffer, .right, state.getCount());
            state.reset();
            return true;
        },
        'w' => {
            motions.extendSelection(view, buffer, .word_forward, state.getCount());
            state.reset();
            return true;
        },
        'b' => {
            motions.extendSelection(view, buffer, .word_backward, state.getCount());
            state.reset();
            return true;
        },
        '0' => {
            motions.extendSelection(view, buffer, .line_start, 1);
            state.reset();
            return true;
        },
        '$' => {
            motions.extendSelection(view, buffer, .line_end, 1);
            state.reset();
            return true;
        },
        'G' => {
            motions.extendSelection(view, buffer, .file_end, 1);
            state.reset();
            return true;
        },
        'g' => {
            state.pending_g = true;
            return true;
        },

        // Count prefix
        '1'...'9' => {
            state.addDigit(@intCast(keyval - '0'));
            return true;
        },

        // Operators on selection
        'd' => {
            operators.deleteSelection(view, buffer);
            enterNormalMode(view);
            state.reset();
            return true;
        },
        'y' => {
            operators.yankSelection(view, buffer);
            enterNormalMode(view);
            state.reset();
            return true;
        },
        'c' => {
            operators.deleteSelection(view, buffer);
            enterInsertMode(view);
            state.reset();
            return true;
        },

        else => {
            return false;
        },
    }
}

// Mode transitions

pub fn enterNormalMode(view: *gtk.TextView) void {
    state.mode = .normal;
    state.reset();
    state.visual_start = null;
    view.setEditable(0);
    updateCursor(view);
    updateStatusBar();
}

pub fn enterInsertMode(view: *gtk.TextView) void {
    state.mode = .insert;
    view.setEditable(1);
    updateCursor(view);
    updateStatusBar();
}

fn enterVisualMode(view: *gtk.TextView, buffer: *gtk.TextBuffer, line_mode: bool) void {
    state.mode = if (line_mode) .visual_line else .visual;
    view.setEditable(0);

    // Store anchor at cursor position
    var iter: gtk.TextIter = undefined;
    buffer.getIterAtMark(&iter, buffer.getInsert());
    state.visual_start = iter;

    if (line_mode) {
        var line_start = iter;
        var line_end = iter;
        line_start.setLineOffset(0);
        _ = line_end.forwardToLineEnd();
        buffer.selectRange(&line_start, &line_end);
    }

    updateCursor(view);
    updateStatusBar();
}

fn updateCursor(view: *gtk.TextView) void {
    view.setCursorVisible(1);
}

pub fn updateStatusBar() void {
    const s = app.state orelse return;

    if (state.mode == .command) {
        var buf: [280:0]u8 = undefined;
        const cmd = state.getCommand();
        const msg = std.fmt.bufPrintZ(&buf, ":{s}", .{cmd}) catch ":";
        s.setStatus(msg);
        return;
    }

    const mode_str: [:0]const u8 = switch (state.mode) {
        .normal => "-- NORMAL --",
        .insert => "-- INSERT --",
        .visual => "-- VISUAL --",
        .visual_line => "-- VISUAL LINE --",
        .command => ":",
    };
    s.setStatus(mode_str);
}

pub fn showStatus(comptime fmt: []const u8, args: anytype) void {
    const s = app.state orelse return;
    var buf: [128:0]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    s.setStatus(msg);
}

/// Initialize vim mode
pub fn init(view: *gtk.TextView) void {
    state = .{};
    enterNormalMode(view);
}

/// Disable vim mode
pub fn deinit(view: *gtk.TextView) void {
    state.mode = .insert;
    view.setEditable(1);
    view.setCursorVisible(1);
}

/// Get the current mode name
pub fn getModeName() [:0]const u8 {
    return switch (state.mode) {
        .normal => "NORMAL",
        .insert => "INSERT",
        .visual => "VISUAL",
        .visual_line => "V-LINE",
        .command => "COMMAND",
    };
}
