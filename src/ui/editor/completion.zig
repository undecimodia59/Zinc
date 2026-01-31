const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk4");
const glib = @import("glib");
const gobject = @import("gobject");

const app = @import("../app.zig");
const config = @import("../../utils/config.zig");
const vim = @import("../vim/root.zig");

const Allocator = std.mem.Allocator;

// Layout constants
const MAX_SUGGESTIONS: usize = 50;
const POPUP_MAX_HEIGHT: c_int = 200;
const POPUP_MIN_WIDTH: c_int = 280;
const POPUP_PADDING: c_int = 8;
const ROW_PADDING_V: c_int = 4;
const CHAR_WIDTH_ESTIMATE: c_int = 8;

const CompletionItem = struct {
    text: []u8,
    count: u32,
    last_offset: i32,
};

const CompletionState = struct {
    allocator: Allocator,
    view: *gtk.TextView,
    buffer: *gtk.TextBuffer,
    fixed: *gtk.Fixed,
    popup_box: *gtk.Box,
    scroll: *gtk.ScrolledWindow,
    list_box: *gtk.ListBox,
    items: std.ArrayList(CompletionItem),
    matches: std.ArrayList(usize),
    enabled: bool,
    visible: bool,
    applying: bool,
    cycle_active: bool,
    cycle_block_once: bool,
    cycle_prefix: ?[]u8,
    last_index: i32,
    locked_x: ?f64, // X position locked during cycling to prevent jumping

    fn deinit(self: *CompletionState) void {
        clearItems(self);
        self.items.deinit(self.allocator);
        self.matches.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

var state: ?*CompletionState = null;
var completion_css_provider: ?*gtk.CssProvider = null;

/// Initializes the completion system for a given TextView.
/// Creates the popup UI, connects buffer signals, and applies theming.
pub fn init(view: *gtk.TextView, fixed: *gtk.Fixed, cfg: *const config.Config) void {
    if (state != null) return;
    const allocator = app.allocator();

    const buffer = view.getBuffer();
    const popup_box = gtk.Box.new(gtk.Orientation.vertical, 0);
    popup_box.as(gtk.Widget).setVisible(0);
    popup_box.as(gtk.Widget).setCanTarget(0);
    popup_box.as(gtk.Widget).setCanFocus(0);
    popup_box.as(gtk.Widget).setHexpand(0);
    popup_box.as(gtk.Widget).setVexpand(0);
    popup_box.as(gtk.Widget).setHalign(gtk.Align.start);
    popup_box.as(gtk.Widget).addCssClass("zinc-completion");

    const list_box = gtk.ListBox.new();
    list_box.setSelectionMode(gtk.SelectionMode.single);
    list_box.setActivateOnSingleClick(1);
    list_box.as(gtk.Widget).setMarginStart(ROW_PADDING_V);
    list_box.as(gtk.Widget).setMarginEnd(ROW_PADDING_V);
    list_box.as(gtk.Widget).setMarginTop(ROW_PADDING_V);
    list_box.as(gtk.Widget).setMarginBottom(ROW_PADDING_V);
    list_box.as(gtk.Widget).addCssClass("zinc-completion-list");

    const scroll = gtk.ScrolledWindow.new();
    scroll.setPolicy(gtk.PolicyType.never, gtk.PolicyType.automatic);
    scroll.setPropagateNaturalHeight(1);
    scroll.setMaxContentHeight(POPUP_MAX_HEIGHT);
    scroll.setMinContentWidth(POPUP_MIN_WIDTH);
    scroll.as(gtk.Widget).setVexpand(0);
    scroll.as(gtk.Widget).setHexpand(0);
    scroll.setChild(list_box.as(gtk.Widget));

    popup_box.append(scroll.as(gtk.Widget));
    fixed.put(popup_box.as(gtk.Widget), 0, 0);

    const st = allocator.create(CompletionState) catch return;
    st.* = .{
        .allocator = allocator,
        .view = view,
        .buffer = buffer,
        .fixed = fixed,
        .popup_box = popup_box,
        .scroll = scroll,
        .list_box = list_box,
        .items = .{},
        .matches = .{},
        .enabled = cfg.editor.completion_enabled,
        .visible = false,
        .applying = false,
        .cycle_active = false,
        .cycle_block_once = false,
        .cycle_prefix = null,
        .last_index = -1,
        .locked_x = null,
    };
    state = st;

    applyTheme(st, cfg);

    _ = gtk.TextBuffer.signals.changed.connect(
        buffer,
        *gtk.TextBuffer,
        &onBufferChanged,
        buffer,
        .{},
    );

    _ = gtk.TextBuffer.signals.mark_set.connect(
        buffer,
        *gtk.TextBuffer,
        &onCursorMoved,
        buffer,
        .{},
    );

    _ = gtk.ListBox.signals.row_activated.connect(
        list_box,
        *CompletionState,
        &onRowActivated,
        st,
        .{},
    );
    _ = gtk.ListBox.signals.row_selected.connect(
        list_box,
        *CompletionState,
        &onRowSelected,
        st,
        .{},
    );
}

/// Updates completion state with new configuration.
/// Reapplies theme and disables completion popup if completion is disabled.
pub fn applyConfig(cfg: *const config.Config) void {
    const st = state orelse return;
    st.enabled = cfg.editor.completion_enabled;
    applyTheme(st, cfg);
    if (!st.enabled) {
        hidePopup(st);
    }
}

/// Cleans up completion state and removes CSS provider.
pub fn deinit() void {
    const st = state orelse return;
    state = null;
    clearItems(st);
    st.items.deinit(st.allocator);
    st.matches.deinit(st.allocator);
    if (st.cycle_prefix) |p| {
        st.allocator.free(p);
        st.cycle_prefix = null;
    }
    if (completion_css_provider) |old| {
        if (gdk.Display.getDefault()) |display| {
            gtk.StyleContext.removeProviderForDisplay(display, old.as(gtk.StyleProvider));
        }
        old.as(gobject.Object).unref();
        completion_css_provider = null;
    }
    st.allocator.destroy(st);
}

/// Handles key presses when completion popup is visible.
/// Returns true if the key was consumed by the completion system.
pub fn handleKeyPress(keyval: c_uint, modifiers: gdk.ModifierType) bool {
    const st = state orelse return false;
    if (!st.enabled or !st.visible) return false;

    if (modifiers.control_mask or modifiers.alt_mask) return false;

    if (keyval == gdk.KEY_Escape) {
        resetCycle(st);
        hidePopup(st);
        return true;
    }

    if (keyval == gdk.KEY_Down or keyval == gdk.KEY_KP_Down) {
        selectNext(st);
        return true;
    }

    if (keyval == gdk.KEY_Up or keyval == gdk.KEY_KP_Up) {
        selectPrev(st);
        return true;
    }

    if (keyval == gdk.KEY_Tab or keyval == gdk.KEY_ISO_Left_Tab) {
        if (modifiers.shift_mask) {
            selectPrev(st);
        } else {
            selectNext(st);
        }
        st.cycle_block_once = true;
        applySelectionInline(st);
        return true;
    }

    if (keyval == gdk.KEY_Return or keyval == gdk.KEY_KP_Enter) {
        resetCycle(st);
        applySelection(st);
        return true;
    }

    return false;
}

fn onBufferChanged(_: *gtk.TextBuffer, _: *gtk.TextBuffer) callconv(.c) void {
    const st = state orelse return;
    if (!st.enabled or st.applying) return;
    if (st.cycle_block_once) {
        st.cycle_block_once = false;
    } else {
        resetCycle(st);
    }
    rebuildIndex(st);
    updatePopup(st);
}

fn onCursorMoved(
    _: *gtk.TextBuffer,
    _: *gtk.TextIter,
    _: *gtk.TextMark,
    _: *gtk.TextBuffer,
) callconv(.c) void {
    const st = state orelse return;
    if (!st.enabled or st.applying) return;
    updatePopup(st);
}

fn onRowActivated(_: *gtk.ListBox, _: *gtk.ListBoxRow, st: *CompletionState) callconv(.c) void {
    applySelection(st);
}

fn onRowSelected(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, st: *CompletionState) callconv(.c) void {
    ensureSelectedVisible(st, row);
}

fn rebuildIndex(st: *CompletionState) void {
    clearItems(st);

    // TODO: Add LSP support here when language server is available.
    // For now, use buffer-based completion.

    const buffer = st.buffer;
    var start: gtk.TextIter = undefined;
    var end: gtk.TextIter = undefined;
    buffer.getBounds(&start, &end);
    const text_ptr = buffer.getText(&start, &end, 0);
    defer glib.free(@ptrCast(text_ptr));

    const text = std.mem.span(text_ptr);
    var map = std.StringHashMap(usize).init(st.allocator);
    defer map.deinit();

    var i: usize = 0;
    while (i < text.len) {
        if (!isIdentStart(text[i])) {
            i += 1;
            continue;
        }

        const start_idx = i;
        i += 1;
        while (i < text.len and isIdentChar(text[i])) : (i += 1) {}

        const token = text[start_idx..i];
        if (token.len == 0) continue;

        if (map.get(token)) |idx| {
            st.items.items[idx].count += 1;
            st.items.items[idx].last_offset = @intCast(start_idx);
        } else {
            const copy = st.allocator.dupe(u8, token) catch continue;
            const item = CompletionItem{
                .text = copy,
                .count = 1,
                .last_offset = @intCast(start_idx),
            };
            st.items.append(st.allocator, item) catch {
                st.allocator.free(copy);
                continue;
            };
            _ = map.put(copy, st.items.items.len - 1) catch {};
        }
    }
}

fn updatePopup(st: *CompletionState) void {
    if (!st.enabled) {
        hidePopup(st);
        return;
    }

    if (app.state) |app_state| {
        if (app_state.config.editor.vim_mode and vim.state.mode != .insert) {
            hidePopup(st);
            return;
        }
    }

    var prefix_start: gtk.TextIter = undefined;
    var cursor: gtk.TextIter = undefined;
    const live_prefix = getPrefix(st, &prefix_start, &cursor) orelse {
        hidePopup(st);
        return;
    };
    defer glib.free(@constCast(live_prefix.ptr));

    if (live_prefix.len == 0 or !isIdentStart(live_prefix[0])) {
        hidePopup(st);
        return;
    }

    const prefix = if (st.cycle_active and st.cycle_prefix != null) st.cycle_prefix.? else live_prefix;
    buildMatches(st, prefix, cursor.getOffset());
    if (st.matches.items.len == 0) {
        hidePopup(st);
        return;
    }

    rebuildListBox(st);
    updatePopupPosition(st, cursor);
    ensureSelection(st);
    showPopup(st);
}

fn getPrefix(st: *CompletionState, out_start: *gtk.TextIter, out_cursor: *gtk.TextIter) ?[]const u8 {
    st.buffer.getIterAtMark(out_cursor, st.buffer.getInsert());
    var start_iter = out_cursor.*;

    while (start_iter.backwardChar() != 0) {
        const c = start_iter.getChar();
        if (!isIdentCharUnicode(c)) {
            _ = start_iter.forwardChar();
            break;
        }
    }

    out_start.* = start_iter;
    const text_ptr = st.buffer.getText(&start_iter, out_cursor, 0);
    return std.mem.span(text_ptr);
}

fn buildMatches(st: *CompletionState, prefix: []const u8, cursor_offset: i32) void {
    st.matches.clearRetainingCapacity();

    for (st.items.items, 0..) |item, idx| {
        if (std.mem.startsWith(u8, item.text, prefix)) {
            st.matches.append(st.allocator, idx) catch {};
        }
    }

    const sorter = struct {
        items: []const CompletionItem,
        cursor: i32,
        prefix: []const u8,
        fn lessThan(ctx: @This(), a_idx: usize, b_idx: usize) bool {
            const a = ctx.items[a_idx];
            const b = ctx.items[b_idx];
            _ = ctx.prefix;

            const a_dist = absDiff(ctx.cursor, a.last_offset);
            const b_dist = absDiff(ctx.cursor, b.last_offset);
            if (a_dist != b_dist) return a_dist < b_dist;
            if (a.count != b.count) return a.count > b.count;
            return std.mem.lessThan(u8, a.text, b.text);
        }
    };

    std.mem.sort(
        usize,
        st.matches.items,
        sorter{ .items = st.items.items, .cursor = cursor_offset, .prefix = prefix },
        sorter.lessThan,
    );
}

fn rebuildListBox(st: *CompletionState) void {
    clearListBox(st);

    const count = @min(st.matches.items.len, MAX_SUGGESTIONS);
    var max_len: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const item = st.items.items[st.matches.items[i]];
        if (item.text.len > max_len) max_len = item.text.len;
        const label_text = st.allocator.dupeZ(u8, item.text) catch continue;
        defer st.allocator.free(label_text);
        const label = gtk.Label.new(label_text.ptr);
        label.as(gtk.Widget).setHalign(gtk.Align.start);
        label.as(gtk.Widget).setValign(gtk.Align.center);
        label.as(gtk.Widget).setMarginTop(2);
        label.as(gtk.Widget).setMarginBottom(2);

        const row = gtk.ListBoxRow.new();
        row.setChild(label.as(gtk.Widget));
        st.list_box.append(row.as(gtk.Widget));
    }

    // Calculate dimensions
    const min_width: c_int = @intCast(@max(
        POPUP_MIN_WIDTH,
        @as(c_int, @intCast(max_len)) * CHAR_WIDTH_ESTIMATE + POPUP_PADDING * 3,
    ));

    // Estimate row height (label + margins + padding from CSS)
    const row_height: usize = 28; // ~20px label + 2+2 margin + 4 CSS padding
    const list_padding: usize = 8; // ListBox margins
    const desired_height = @min(list_padding + count * row_height, @as(usize, @intCast(POPUP_MAX_HEIGHT)));

    st.scroll.setMinContentWidth(min_width);
    st.scroll.setMinContentHeight(@intCast(desired_height));
    st.popup_box.as(gtk.Widget).queueResize();
}

fn clearListBox(st: *CompletionState) void {
    var child = st.list_box.as(gtk.Widget).getFirstChild();
    while (child) |c| {
        st.list_box.remove(c);
        child = st.list_box.as(gtk.Widget).getFirstChild();
    }
}

fn ensureSelectedVisible(st: *CompletionState, row: ?*gtk.ListBoxRow) void {
    const r = row orelse return;
    const adj = st.scroll.getVadjustment();
    const idx = r.getIndex();

    // Get actual row position from GTK allocation
    var alloc: gdk.Rectangle = undefined;
    r.as(gtk.Widget).getAllocation(&alloc);

    const current = adj.getValue();
    const page_size = adj.getPageSize();

    // If allocation looks invalid (GTK hasn't laid out yet), defer to idle
    // Real rows have height ~31px, invalid ones show 8px or less
    if (page_size < 1 or alloc.f_height < 20) {
        if (idx >= 0) {
            queueEnsureSelectedVisible(st, idx);
        }
        return;
    }

    const row_top = @as(f64, @floatFromInt(alloc.f_y));
    const row_bottom = row_top + @as(f64, @floatFromInt(alloc.f_height));

    if (row_top < current) {
        adj.setValue(row_top);
    } else if (row_bottom > current + page_size) {
        adj.setValue(row_bottom - page_size);
    }
}

fn queueEnsureSelectedVisible(st: *CompletionState, idx: i32) void {
    const ctx = st.allocator.create(struct { st: *CompletionState, idx: i32 }) catch return;
    ctx.* = .{ .st = st, .idx = idx };

    _ = glib.idleAddFull(
        glib.PRIORITY_DEFAULT_IDLE,
        struct {
            fn cb(data: ?*anyopaque) callconv(.c) c_int {
                const inner: *struct { st: *CompletionState, idx: i32 } =
                    @ptrCast(@alignCast(data orelse return 0));
                if (state == null) {
                    inner.st.allocator.destroy(inner);
                    return 0;
                }
                if (inner.st.list_box.getRowAtIndex(inner.idx)) |row| {
                    ensureSelectedVisible(inner.st, row);
                }
                inner.st.allocator.destroy(inner);
                return 0;
            }
        }.cb,
        ctx,
        null,
    );
}

fn estimatedPopupHeight(st: *CompletionState) usize {
    _ = st;
    // Return max height - GTK will handle actual sizing via ScrolledWindow
    return @intCast(POPUP_MAX_HEIGHT);
}

fn resetCycle(st: *CompletionState) void {
    if (st.cycle_prefix) |p| {
        st.allocator.free(p);
    }
    st.cycle_prefix = null;
    st.cycle_active = false;
    st.last_index = -1;
    st.locked_x = null;
}

/// Applies the selected completion item.
/// If `keep_open` is true, enters cycling mode and keeps popup open.
/// If `keep_open` is false, hides the popup after applying.
fn applyCompletionItem(st: *CompletionState, keep_open: bool) void {
    const row = st.list_box.getSelectedRow() orelse return;
    const index = row.getIndex();
    if (index < 0 or @as(usize, @intCast(index)) >= st.matches.items.len) return;

    const item = st.items.items[st.matches.items[@intCast(index)]];

    var prefix_start: gtk.TextIter = undefined;
    var cursor: gtk.TextIter = undefined;
    const prefix = getPrefix(st, &prefix_start, &cursor) orelse return;
    defer glib.free(@constCast(prefix.ptr));

    // Enter cycling mode if keeping popup open
    if (keep_open and !st.cycle_active) {
        resetCycle(st);
        st.cycle_prefix = st.allocator.dupe(u8, prefix) catch null;
        st.cycle_active = true;
    }
    if (keep_open) {
        st.last_index = index;
    }

    st.applying = true;
    st.buffer.delete(&prefix_start, &cursor);
    const insert_z = st.allocator.dupeZ(u8, item.text) catch {
        st.applying = false;
        if (!keep_open) hidePopup(st);
        return;
    };
    defer st.allocator.free(insert_z);
    st.buffer.insertAtCursor(insert_z.ptr, @intCast(item.text.len));
    st.applying = false;

    rebuildIndex(st);
    if (keep_open) {
        updatePopup(st);
    } else {
        hidePopup(st);
    }
}

fn applySelectionInline(st: *CompletionState) void {
    applyCompletionItem(st, true);
}

fn updatePopupPosition(st: *CompletionState, cursor: gtk.TextIter) void {
    var iter_rect: gdk.Rectangle = undefined;
    st.view.getIterLocation(&cursor, &iter_rect);

    var visible: gdk.Rectangle = undefined;
    st.view.getVisibleRect(&visible);

    // Lock X position during cycling to prevent horizontal jumping
    const x: f64 = if (st.cycle_active and st.locked_x != null)
        st.locked_x.?
    else blk: {
        const new_x = @as(f64, @floatFromInt(iter_rect.f_x - visible.f_x));
        if (st.cycle_active) {
            st.locked_x = new_x;
        }
        break :blk new_x;
    };

    const y_below = iter_rect.f_y - visible.f_y + iter_rect.f_height;
    const popup_h = @as(c_int, @intCast(estimatedPopupHeight(st)));
    const space_below = visible.f_height - y_below;
    const y_above = iter_rect.f_y - visible.f_y - popup_h;

    const use_above = space_below < popup_h and y_above >= 0;
    const y = if (use_above) y_above else y_below;
    st.fixed.move(st.popup_box.as(gtk.Widget), x, @floatFromInt(y));
}

fn ensureSelection(st: *CompletionState) void {
    if (st.list_box.getSelectedRow() != null) return;
    if (st.cycle_active and st.last_index >= 0) {
        if (st.list_box.getRowAtIndex(st.last_index)) |row| {
            st.list_box.selectRow(row);
            ensureSelectedVisible(st, row);
            return;
        }
    }
    const first = st.list_box.getRowAtIndex(0) orelse return;
    st.list_box.selectRow(first);
    ensureSelectedVisible(st, first);
}

fn selectNext(st: *CompletionState) void {
    const selected = st.list_box.getSelectedRow();
    const count = listBoxRowCount(st);
    if (count == 0) return;

    var next_index: i32 = 0;
    if (selected) |row| {
        const idx = row.getIndex();
        next_index = if (idx + 1 < @as(i32, @intCast(count))) idx + 1 else 0;
    }
    const next = st.list_box.getRowAtIndex(next_index) orelse return;
    st.list_box.selectRow(next);
    st.last_index = next_index;
    ensureSelectedVisible(st, next);
}

fn selectPrev(st: *CompletionState) void {
    const selected = st.list_box.getSelectedRow();
    const count = listBoxRowCount(st);
    if (count == 0) return;

    var prev_index: i32 = @intCast(count - 1);
    if (selected) |row| {
        const idx = row.getIndex();
        prev_index = if (idx > 0) idx - 1 else @intCast(count - 1);
    }
    const prev = st.list_box.getRowAtIndex(prev_index) orelse return;
    st.list_box.selectRow(prev);
    st.last_index = prev_index;
    ensureSelectedVisible(st, prev);
}

fn applySelection(st: *CompletionState) void {
    applyCompletionItem(st, false);
}

fn showPopup(st: *CompletionState) void {
    if (!st.visible) {
        st.popup_box.as(gtk.Widget).setVisible(1);
        st.visible = true;
    }
}

fn hidePopup(st: *CompletionState) void {
    if (st.visible) {
        st.popup_box.as(gtk.Widget).setVisible(0);
        st.visible = false;
    }
}

fn clearItems(st: *CompletionState) void {
    for (st.items.items) |item| {
        st.allocator.free(item.text);
    }
    st.items.clearRetainingCapacity();
}

fn applyTheme(st: *CompletionState, cfg: *const config.Config) void {
    const display = gdk.Display.getDefault() orelse return;

    if (completion_css_provider) |old| {
        gtk.StyleContext.removeProviderForDisplay(display, old.as(gtk.StyleProvider));
        old.as(gobject.Object).unref();
    }

    const provider = gtk.CssProvider.new();
    completion_css_provider = provider;

    const bg = cfg.theme.background;
    const fg = cfg.theme.foreground;
    const sel = cfg.theme.selection;
    const popup_bg = mixColor(bg, fg, 0.08);

    const css = std.fmt.allocPrint(
        st.allocator,
        \\.zinc-completion {{
        \\  background-color: #{X:0>6};
        \\  color: #{X:0>6};
        \\  border: none;
        \\  border-radius: 6px;
        \\  padding: 4px;
        \\  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.35);
        \\}}
        \\.zinc-completion list {{
        \\  background-color: transparent;
        \\}}
        \\.zinc-completion row {{
        \\  padding: 4px 8px;
        \\  border-radius: 4px;
        \\}}
        \\.zinc-completion row:selected {{
        \\  background-color: #{X:0>6};
        \\  color: #{X:0>6};
        \\}}
    ,
        .{ popup_bg, fg, sel, fg },
    ) catch return;
    defer st.allocator.free(css);

    const css_z = st.allocator.allocSentinel(u8, css.len, 0) catch return;
    defer st.allocator.free(css_z);
    @memcpy(css_z, css);

    provider.loadFromData(css_z.ptr, @intCast(css_z.len));
    gtk.StyleContext.addProviderForDisplay(
        display,
        provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
}

fn isIdentStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn isIdentCharUnicode(c: u32) bool {
    if (c > 0x7f) return false;
    return isIdentChar(@intCast(c));
}

fn absDiff(a: i32, b: i32) i32 {
    return if (a >= b) a - b else b - a;
}

fn mixColor(a: u32, b: u32, t: f64) u32 {
    const ar: f64 = @floatFromInt((a >> 16) & 0xff);
    const ag: f64 = @floatFromInt((a >> 8) & 0xff);
    const ab: f64 = @floatFromInt(a & 0xff);
    const br: f64 = @floatFromInt((b >> 16) & 0xff);
    const bg: f64 = @floatFromInt((b >> 8) & 0xff);
    const bb: f64 = @floatFromInt(b & 0xff);

    const r: u32 = @intFromFloat(ar + (br - ar) * t);
    const g: u32 = @intFromFloat(ag + (bg - ag) * t);
    const bch: u32 = @intFromFloat(ab + (bb - ab) * t);
    return (r << 16) | (g << 8) | bch;
}

fn listBoxRowCount(st: *CompletionState) usize {
    var count: usize = 0;
    var child = st.list_box.as(gtk.Widget).getFirstChild();
    while (child) |c| {
        count += 1;
        child = c.getNextSibling();
    }
    return count;
}
