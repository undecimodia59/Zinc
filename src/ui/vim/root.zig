//! Vim mode implementation for Zinc editor
//!
//! Provides modal editing with Normal, Insert, Visual, Command, and Search modes.
//!
//! ## Supported Commands
//!
//! ### Normal Mode - Movement
//! | Key | Action |
//! |-----|--------|
//! | h, Left | Move left |
//! | j, Down | Move down |
//! | k, Up | Move up |
//! | l, Right | Move right |
//! | w | Move to next word start |
//! | b | Move to previous word start |
//! | e | Move to end of word |
//! | 0 | Move to line start |
//! | ^ | Move to first non-blank |
//! | $ | Move to line end |
//! | gg | Move to file start |
//! | G | Move to file end |
//! | % | Jump to matching bracket/quote |
//! | f{c} | Find char forward |
//! | F{c} | Find char backward |
//! | t{c} | Till char forward |
//! | T{c} | Till char backward |
//! | ; | Repeat last f/F/t/T |
//! | , | Repeat f/F/t/T opposite |
//!
//! ### Normal Mode - Search
//! | Key | Action |
//! |-----|--------|
//! | / | Search forward |
//! | ? | Search backward |
//! | n | Next search result |
//! | N | Previous search result |
//! | * | Search word under cursor |
//! | # | Search word backward |
//!
//! ### Normal Mode - Editing
//! | Key | Action |
//! |-----|--------|
//! | i | Enter Insert mode |
//! | a | Insert after cursor |
//! | A | Insert at line end |
//! | o | Open line below |
//! | O | Open line above |
//! | v | Enter Visual mode |
//! | V | Enter Visual Line mode |
//! | d | Delete (with motion) |
//! | dd | Delete line |
//! | y | Yank (copy) |
//! | yy | Yank line |
//! | c | Change (delete + insert) |
//! | cc | Change line |
//! | p | Paste after |
//! | P | Paste before |
//! | x | Delete char |
//! | r{c} | Replace char |
//! | : | Command mode |
//! | [count] | Repeat count |
//!
//! ### Visual Mode
//! | Key | Action |
//! |-----|--------|
//! | Escape | Return to Normal |
//! | d | Delete selection |
//! | y | Yank selection |
//! | c | Change selection |
//! | Movement | Extend selection |
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
const gobject = @import("gobject");

const app = @import("../app.zig");
const command = @import("command.zig");
const motions = @import("motions.zig");
const operators = @import("operators.zig");
const search = @import("search.zig");

// Re-export for other modules
pub const Motion = motions.Motion;
pub const Operator = operators.Operator;

pub const Mode = enum {
    normal,
    insert,
    visual,
    visual_line,
    command,
    search,
};

/// Pending character find type (f/F/t/T)
pub const PendingFind = enum {
    none,
    f, // find forward
    F, // find backward
    t, // till forward
    T, // till backward
};

pub const State = struct {
    mode: Mode = .normal,
    count: u32 = 0,
    pending_operator: Operator = .none,
    pending_g: bool = false,
    pending_find: PendingFind = .none,
    pending_replace: bool = false,
    last_find_char: u32 = 0,
    last_find_type: PendingFind = .none,
    visual_start: ?gtk.TextIter = null,
    command_buffer: [256]u8 = undefined,
    command_len: usize = 0,

    pub fn reset(self: *State) void {
        self.count = 0;
        self.pending_operator = .none;
        self.pending_g = false;
        self.pending_find = .none;
        self.pending_replace = false;
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
        .visual, .visual_line => handleVisualMode(view, buffer, keyval),
        .command => command.handleKey(view, keyval),
        .search => search.handleKey(view, keyval),
    };
}

fn isModifierKey(keyval: c_uint) bool {
    return switch (keyval) {
        gdk.KEY_Shift_L,
        gdk.KEY_Shift_R,
        gdk.KEY_Control_L,
        gdk.KEY_Control_R,
        gdk.KEY_Alt_L,
        gdk.KEY_Alt_R,
        gdk.KEY_Meta_L,
        gdk.KEY_Meta_R,
        gdk.KEY_Super_L,
        gdk.KEY_Super_R,
        gdk.KEY_Hyper_L,
        gdk.KEY_Hyper_R,
        gdk.KEY_ISO_Level3_Shift, // AltGr
        gdk.KEY_ISO_Level5_Shift,
        gdk.KEY_Mode_switch,
        gdk.KEY_Num_Lock,
        gdk.KEY_Caps_Lock,
        gdk.KEY_Scroll_Lock,
        => true,
        else => false,
    };
}

var pending_scroll: ?ScrollRequest = null;
var scroll_idle_active: bool = false;

const ScrollRequest = struct {
    view: *gtk.TextView,
    yalign: f64,
};

pub fn scrollToCursor(view: *gtk.TextView, yalign: f64) void {
    const glib = @import("glib");
    pending_scroll = .{ .view = view, .yalign = yalign };
    if (scroll_idle_active) return;
    scroll_idle_active = true;
    _ = glib.idleAddFull(
        glib.PRIORITY_DEFAULT_IDLE,
        struct {
            fn cb(_: ?*anyopaque) callconv(.c) c_int {
                scroll_idle_active = false;
                const req = pending_scroll orelse return 0;
                pending_scroll = null;
                if (!scrollToCursorViaAdjustment(req.view, req.yalign)) {
                    const buffer = req.view.getBuffer();
                    var iter: gtk.TextIter = undefined;
                    buffer.getIterAtMark(&iter, buffer.getInsert());
                    _ = req.view.scrollToIter(&iter, 0.0, 1, 0.0, req.yalign);
                    req.view.scrollMarkOnscreen(buffer.getInsert());
                }
                return 0;
            }
        }.cb,
        null,
        null,
    );
}

fn scrollToCursorViaAdjustment(view: *gtk.TextView, yalign: f64) bool {
    const s = app.state orelse return false;
    const scroll = s.code_scroll;
    const vadj = scroll.getVadjustment();

    const buffer = view.getBuffer();
    var iter: gtk.TextIter = undefined;
    buffer.getIterAtMark(&iter, buffer.getInsert());
    iter.setLineOffset(0);

    var line_y: c_int = 0;
    var line_h: c_int = 0;
    view.getLineYrange(&iter, &line_y, &line_h);

    var rect: gdk.Rectangle = undefined;
    view.getVisibleRect(&rect);

    const visible_h: f64 = @floatFromInt(rect.f_height);
    const line_y_f: f64 = @floatFromInt(line_y);
    const line_h_f: f64 = @floatFromInt(line_h);

    const target_top = line_y_f - (visible_h - line_h_f) * yalign;

    const lower = vadj.getLower();
    const upper = vadj.getUpper();
    const page = vadj.getPageSize();
    const max = if (upper > page) upper - page else lower;

    var value = target_top;
    if (value < lower) value = lower;
    if (value > max) value = max;

    vadj.setValue(value);
    return true;
}

fn handleNormalMode(
    view: *gtk.TextView,
    buffer: *gtk.TextBuffer,
    keyval: c_uint,
    modifiers: gdk.ModifierType,
) bool {
    // Handle pending f/F/t/T command (waiting for character) BEFORE modifier check
    // because AltGr (Ctrl+Alt) is needed for characters like { } [ ] on some keyboards
    if (state.pending_find != .none) {
        if (isModifierKey(keyval)) {
            return true;
        }
        const find_type = state.pending_find;
        state.pending_find = .none;

        // Accept any printable character (keysyms < 0xff00 are regular characters,
        // >= 0xff00 are function keys, modifiers, etc.)
        if (keyval >= 0x20 and keyval < 0xff00) {
            const char: u32 = keyval;
            state.last_find_char = char;
            state.last_find_type = find_type;

            const found = switch (find_type) {
                .f => motions.findCharForward(buffer, char, state.getCount(), false),
                .t => motions.findCharForward(buffer, char, state.getCount(), true),
                .F => motions.findCharBackward(buffer, char, state.getCount(), false),
                .T => motions.findCharBackward(buffer, char, state.getCount(), true),
                .none => false,
            };
            _ = found;
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        }
        state.reset();
        return false;
    }

    // Let Ctrl/Alt modified keys pass through to global keybindings (Ctrl+S, Ctrl+E, etc.)
    if (modifiers.control_mask or modifiers.alt_mask) {
        return false;
    }

    // Handle pending g command
    if (state.pending_g) {
        state.pending_g = false;
        if (keyval == 'g') {
            motions.moveTo(buffer, .file_start, state.getCount());
            scrollToCursor(view, 0.0);
            state.reset();
            return true;
        }
        state.reset();
        return false;
    }

    if (state.pending_replace) {
        if (keyval == gdk.KEY_Escape) {
            state.reset();
            return true;
        }
        const codepoint = gdk.keyvalToUnicode(keyval);
        if (codepoint == 0) {
            state.reset();
            return true;
        }
        operators.replaceChar(view, buffer, codepoint, state.getCount());
        scrollToCursor(view, 0.5);
        state.reset();
        return true;
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
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },
        'j', gdk.KEY_Down => {
            motions.move(buffer, .down, state.getCount());
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },
        'k', gdk.KEY_Up => {
            motions.move(buffer, .up, state.getCount());
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },
        'l', gdk.KEY_Right => {
            motions.move(buffer, .right, state.getCount());
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },
        'w' => {
            if (state.pending_operator != .none) {
                operators.operatorMotion(view, buffer, .word_forward, state.getCount());
            } else {
                motions.move(buffer, .word_forward, state.getCount());
            }
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },
        'b' => {
            if (state.pending_operator != .none) {
                operators.operatorMotion(view, buffer, .word_backward, state.getCount());
            } else {
                motions.move(buffer, .word_backward, state.getCount());
            }
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },
        '0' => {
            motions.move(buffer, .line_start, 1);
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },
        '$' => {
            motions.move(buffer, .line_end, 1);
            scrollToCursor(view, 0.5);
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
                scrollToCursor(view, 0.5);
            } else {
                motions.moveTo(buffer, .file_end, 1);
                scrollToCursor(view, 1.0);
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
        'r' => {
            state.pending_replace = true;
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
            app.showCommandPalette(true);
            state.reset();
            return true;
        },

        // Search
        '/' => {
            search.enter(true);
            return true;
        },
        '?' => {
            search.enter(false);
            return true;
        },
        'n' => {
            if (search.search_forward) {
                _ = search.findNext(buffer);
            } else {
                _ = search.findPrev(buffer);
            }
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },
        'N' => {
            if (search.search_forward) {
                _ = search.findPrev(buffer);
            } else {
                _ = search.findNext(buffer);
            }
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },
        '*' => {
            _ = search.searchWordUnderCursor(buffer, true);
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },
        '#' => {
            _ = search.searchWordUnderCursor(buffer, false);
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },

        // Bracket matching
        '%' => {
            _ = motions.matchBracket(buffer);
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },

        // Character find
        'f' => {
            state.pending_find = .f;
            return true;
        },
        'F' => {
            state.pending_find = .F;
            return true;
        },
        't' => {
            state.pending_find = .t;
            return true;
        },
        'T' => {
            state.pending_find = .T;
            return true;
        },
        ';' => {
            // Repeat last f/F/t/T
            if (state.last_find_type != .none and state.last_find_char != 0) {
                _ = switch (state.last_find_type) {
                    .f => motions.findCharForward(buffer, state.last_find_char, state.getCount(), false),
                    .t => motions.findCharForward(buffer, state.last_find_char, state.getCount(), true),
                    .F => motions.findCharBackward(buffer, state.last_find_char, state.getCount(), false),
                    .T => motions.findCharBackward(buffer, state.last_find_char, state.getCount(), true),
                    .none => false,
                };
                scrollToCursor(view, 0.5);
            }
            state.reset();
            return true;
        },
        ',' => {
            // Repeat last f/F/t/T in opposite direction
            if (state.last_find_type != .none and state.last_find_char != 0) {
                _ = switch (state.last_find_type) {
                    .f => motions.findCharBackward(buffer, state.last_find_char, state.getCount(), false),
                    .t => motions.findCharBackward(buffer, state.last_find_char, state.getCount(), true),
                    .F => motions.findCharForward(buffer, state.last_find_char, state.getCount(), false),
                    .T => motions.findCharForward(buffer, state.last_find_char, state.getCount(), true),
                    .none => false,
                };
                scrollToCursor(view, 0.5);
            }
            state.reset();
            return true;
        },

        // Additional motions
        '^' => {
            motions.moveToFirstNonBlank(buffer);
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },
        'e' => {
            motions.moveToWordEnd(buffer, state.getCount());
            scrollToCursor(view, 0.5);
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
) bool {
    // Handle pending f/F/t/T command (waiting for character) BEFORE modifier check
    // because AltGr (Ctrl+Alt) is needed for characters like { } [ ] on some keyboards
    if (state.pending_find != .none) {
        if (isModifierKey(keyval)) {
            return true;
        }
        const find_type = state.pending_find;
        state.pending_find = .none;

        // Accept any printable character (keysyms < 0xff00 are regular characters,
        // >= 0xff00 are function keys, modifiers, etc.)
        if (keyval >= 0x20 and keyval < 0xff00) {
            const char: u32 = keyval;
            state.last_find_char = char;
            state.last_find_type = find_type;

            const found = switch (find_type) {
                .f => motions.extendSelectionFindChar(buffer, char, state.getCount(), true, false),
                .t => motions.extendSelectionFindChar(buffer, char, state.getCount(), true, true),
                .F => motions.extendSelectionFindChar(buffer, char, state.getCount(), false, false),
                .T => motions.extendSelectionFindChar(buffer, char, state.getCount(), false, true),
                .none => false,
            };
            _ = found;
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        }
        state.reset();
        return false;
    }

    // Handle pending g command
    if (state.pending_g) {
        state.pending_g = false;
        if (keyval == 'g') {
            motions.extendSelection(view, buffer, .file_start, 1);
            scrollToCursor(view, 0.0);
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
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },
        'j', gdk.KEY_Down => {
            motions.extendSelection(view, buffer, .down, state.getCount());
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },
        'k', gdk.KEY_Up => {
            motions.extendSelection(view, buffer, .up, state.getCount());
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },
        'l', gdk.KEY_Right => {
            motions.extendSelection(view, buffer, .right, state.getCount());
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },
        'w' => {
            motions.extendSelection(view, buffer, .word_forward, state.getCount());
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },
        'b' => {
            motions.extendSelection(view, buffer, .word_backward, state.getCount());
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },
        '0' => {
            motions.extendSelection(view, buffer, .line_start, 1);
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },
        '$' => {
            motions.extendSelection(view, buffer, .line_end, 1);
            scrollToCursor(view, 0.5);
            state.reset();
            return true;
        },
        'G' => {
            motions.extendSelection(view, buffer, .file_end, 1);
            scrollToCursor(view, 1.0);
            state.reset();
            return true;
        },
        'g' => {
            state.pending_g = true;
            return true;
        },

        // Character find
        'f' => {
            state.pending_find = .f;
            return true;
        },
        'F' => {
            state.pending_find = .F;
            return true;
        },
        't' => {
            state.pending_find = .t;
            return true;
        },
        'T' => {
            state.pending_find = .T;
            return true;
        },
        ';' => {
            // Repeat last f/F/t/T
            if (state.last_find_type != .none and state.last_find_char != 0) {
                _ = switch (state.last_find_type) {
                    .f => motions.extendSelectionFindChar(buffer, state.last_find_char, state.getCount(), true, false),
                    .t => motions.extendSelectionFindChar(buffer, state.last_find_char, state.getCount(), true, true),
                    .F => motions.extendSelectionFindChar(buffer, state.last_find_char, state.getCount(), false, false),
                    .T => motions.extendSelectionFindChar(buffer, state.last_find_char, state.getCount(), false, true),
                    .none => false,
                };
                scrollToCursor(view, 0.5);
            }
            state.reset();
            return true;
        },
        ',' => {
            // Repeat last f/F/t/T in opposite direction
            if (state.last_find_type != .none and state.last_find_char != 0) {
                _ = switch (state.last_find_type) {
                    .f => motions.extendSelectionFindChar(buffer, state.last_find_char, state.getCount(), false, false),
                    .t => motions.extendSelectionFindChar(buffer, state.last_find_char, state.getCount(), false, true),
                    .F => motions.extendSelectionFindChar(buffer, state.last_find_char, state.getCount(), true, false),
                    .T => motions.extendSelectionFindChar(buffer, state.last_find_char, state.getCount(), true, true),
                    .none => false,
                };
                scrollToCursor(view, 0.5);
            }
            state.reset();
            return true;
        },

        // Bracket matching
        '%' => {
            _ = motions.extendSelectionMatchBracket(buffer);
            scrollToCursor(view, 0.5);
            state.reset();
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
    //view.setEditable(0);

    // Clear any selection by placing cursor at current insert position
    const buffer = view.getBuffer();
    var iter: gtk.TextIter = undefined;
    buffer.getIterAtMark(&iter, buffer.getInsert());
    buffer.placeCursor(&iter);

    updateCursor(view);
    updateStatusBar();
}

pub fn enterInsertMode(view: *gtk.TextView) void {
    state.mode = .insert;
    //view.setEditable(1);
    updateCursor(view);
    updateStatusBar();
}

fn enterVisualMode(view: *gtk.TextView, buffer: *gtk.TextBuffer, line_mode: bool) void {
    state.mode = if (line_mode) .visual_line else .visual;
    //view.setEditable(0);

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
    // 1. Immediate state change
    const is_insert = (state.mode == .insert);
    view.setOverwrite(if (is_insert) 0 else 1);
    view.setCursorVisible(1);

    // 2. Schedule a single high-priority refresh
    // This ensures that even if GTK was busy, the visual update is forced.
    const glib = @import("glib");
    _ = glib.idleAddFull(
        glib.PRIORITY_HIGH_IDLE,
        struct {
            fn cb(data: ?*anyopaque) callconv(.c) c_int {
                const v: *gtk.TextView = @ptrCast(@alignCast(data orelse return 0));

                // Final sync of state
                const current_insert = (state.mode == .insert);
                v.setOverwrite(if (current_insert) 0 else 1);
                v.setCursorVisible(1);

                // Force the redraw on the Widget interface
                v.as(gtk.Widget).queueDraw();

                return 0; // G_SOURCE_REMOVE
            }
        }.cb,
        view,
        null,
    );
}

fn applyCursorStyle(view: *gtk.TextView) void {
    const provider = gtk.CssProvider.new();

    // We target .zinc-editor to match the class added in editor/root.zig.
    // We set min-width on the cursor node to force it to be a block.
    const css =
        \\ .zinc-editor {
        \\   -GtkWidget-cursor-aspect-ratio: 1.0;
        \\ }
        \\ .zinc-editor text > cursor {
        \\   background-color: #f1be16;
        \\   color: #000000;
        \\   min-width: 1ch;  /* Force width to 1 character width */
        \\   min-height: 1em; /* Ensure height covers the line */
        \\ }
    ;

    provider.loadFromData(css, @intCast(css.len));

    // Use .as(gtk.Widget) to get the style context
    const context = view.as(gtk.Widget).getStyleContext();

    // Use .as(gtk.StyleProvider) for the cast
    context.addProvider(provider.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
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

    if (state.mode == .search) {
        // Search status is handled by search module
        return;
    }

    const mode_str: [:0]const u8 = switch (state.mode) {
        .normal => "-- NORMAL --",
        .insert => "-- INSERT --",
        .visual => "-- VISUAL --",
        .visual_line => "-- VISUAL LINE --",
        .command => ":",
        .search => "/",
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
    applyCursorStyle(view);
    enterNormalMode(view);
}

/// Disable vim mode
pub fn deinit(view: *gtk.TextView) void {
    state.mode = .insert;
    view.setEditable(1);
    view.setCursorVisible(1);
    view.setOverwrite(0);
}

/// Get the current mode name
pub fn getModeName() [:0]const u8 {
    return switch (state.mode) {
        .normal => "NORMAL",
        .insert => "INSERT",
        .visual => "VISUAL",
        .visual_line => "V-LINE",
        .command => "COMMAND",
        .search => "SEARCH",
    };
}
