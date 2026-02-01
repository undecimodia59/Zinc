const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk4");
const gobject = @import("gobject");

const app = @import("app.zig");
const editor = @import("editor/root.zig");
const buffer_mod = @import("../core/buffer.zig");
const Buffer = buffer_mod.Buffer;
const BufferManager = buffer_mod.BufferManager;

var tabs_css_provider: ?*gtk.CssProvider = null;

pub const TabBar = struct {
    container: *gtk.Box,
    tabs_box: *gtk.Box,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator) TabBar {
        // Main container
        const container = gtk.Box.new(gtk.Orientation.horizontal, 0);
        container.as(gtk.Widget).addCssClass("zinc-tabbar");
        container.as(gtk.Widget).setVisible(0); // Hidden by default

        // Scrollable area for tabs
        const tabs_box = gtk.Box.new(gtk.Orientation.horizontal, 2);
        tabs_box.as(gtk.Widget).setHexpand(1);
        tabs_box.as(gtk.Widget).setMarginStart(4);
        tabs_box.as(gtk.Widget).setMarginEnd(4);
        tabs_box.as(gtk.Widget).setMarginTop(2);
        tabs_box.as(gtk.Widget).setMarginBottom(2);

        container.append(tabs_box.as(gtk.Widget));

        return .{
            .container = container,
            .tabs_box = tabs_box,
            .allocator = allocator,
        };
    }

    /// Refresh tabs from buffer manager
    pub fn refresh(self: *TabBar, buffers: *BufferManager) void {
        // Clear existing tabs
        var child = self.tabs_box.as(gtk.Widget).getFirstChild();
        while (child) |c| {
            self.tabs_box.remove(c);
            child = self.tabs_box.as(gtk.Widget).getFirstChild();
        }

        const buf_list = buffers.getBuffers();

        // Hide if only one buffer
        if (buf_list.len <= 1) {
            self.container.as(gtk.Widget).setVisible(0);
            return;
        }

        self.container.as(gtk.Widget).setVisible(1);

        // Create tab for each buffer
        for (buf_list, 0..) |*buf, i| {
            const tab = self.createTab(buf, i, i == buffers.active_index);
            self.tabs_box.append(tab);
        }
    }

    fn createTab(self: *TabBar, buf: *const Buffer, index: usize, active: bool) *gtk.Widget {
        _ = self;
        const btn = gtk.Button.new();
        btn.as(gtk.Widget).addCssClass("zinc-tab");
        if (active) {
            btn.as(gtk.Widget).addCssClass("zinc-tab-active");
        }

        // Build label: "filename" or "filename *" if modified
        const name = buf.getDisplayName();
        const modified_suffix: []const u8 = if (buf.modified) " •" else "";

        var label_buf: [256]u8 = undefined;
        const label_text = std.fmt.bufPrint(&label_buf, "{s}{s}", .{ name, modified_suffix }) catch name;

        var label_z: [257]u8 = undefined;
        const len = @min(label_text.len, 256);
        @memcpy(label_z[0..len], label_text[0..len]);
        label_z[len] = 0;

        const label = gtk.Label.new(@ptrCast(&label_z));
        label.as(gtk.Widget).setHalign(gtk.Align.center);
        btn.setChild(label.as(gtk.Widget));

        // Store index on the button to avoid heap allocation
        _ = btn.as(gobject.Object).setData("tab_index", @ptrFromInt(index));
        _ = gtk.Button.signals.clicked.connect(btn, ?*anyopaque, &onTabClicked, null, .{});

        return btn.as(gtk.Widget);
    }
};

fn onTabClicked(button: *gtk.Button, _: ?*anyopaque) callconv(.c) void {
    const s = app.state orelse return;
    const idx_ptr = button.as(gobject.Object).getData("tab_index") orelse return;
    const index: usize = @intFromPtr(idx_ptr);
    switchToTab(s, index);
}

/// Switch to a specific tab index
pub fn switchToTab(s: *app.AppState, index: usize) void {
    // Save current buffer state
    saveCurrentBufferState(s);

    // Switch buffer
    s.buffers.switchTo(index);

    // Load new buffer into editor
    loadActiveBuffer(s);

    // Refresh tab display
    s.tab_bar.refresh(&s.buffers);
}

/// Switch to next tab
pub fn nextTab() void {
    const s = app.state orelse return;
    if (s.buffers.count() <= 1) return;

    saveCurrentBufferState(s);
    s.buffers.nextBuffer();
    loadActiveBuffer(s);
    s.tab_bar.refresh(&s.buffers);
}

/// Create a new untitled buffer and switch to it
pub fn newUntitled() void {
    const s = app.state orelse return;

    saveCurrentBufferState(s);
    _ = s.buffers.createUntitled() catch return;
    loadActiveBuffer(s);
    s.tab_bar.refresh(&s.buffers);
}

/// Switch to previous tab
pub fn prevTab() void {
    const s = app.state orelse return;
    if (s.buffers.count() <= 1) return;

    saveCurrentBufferState(s);
    s.buffers.prevBuffer();
    loadActiveBuffer(s);
    s.tab_bar.refresh(&s.buffers);
}

/// Close current tab, returns true if should quit IDE
pub fn closeCurrentTab() bool {
    const s = app.state orelse return false;

    // Check for unsaved changes
    if (s.buffers.getActive()) |buf| {
        if (buf.modified) {
            // Show save dialog
            showSaveDialog(s, buf);
            return false;
        }
    }

    return doCloseCurrentTab(s);
}

/// Force close current tab without save prompt
pub fn closeCurrentTabForce() bool {
    const s = app.state orelse return false;
    return doCloseCurrentTab(s);
}

fn doCloseCurrentTab(s: *app.AppState) bool {
    const should_quit = s.buffers.closeActive();

    if (should_quit) {
        return true;
    }

    // Load the new active buffer
    loadActiveBuffer(s);
    s.tab_bar.refresh(&s.buffers);

    return false;
}

fn showSaveDialog(s: *app.AppState, buf: *Buffer) void {
    const name = buf.getDisplayName();

    var name_z: [256]u8 = undefined;
    const len = @min(name.len, 255);
    @memcpy(name_z[0..len], name[0..len]);
    name_z[len] = 0;

    const dialog = gtk.MessageDialog.new(
        s.window.as(gtk.Window),
        .{},
        gtk.MessageType.question,
        gtk.ButtonsType.none,
        "Save changes to %s?",
        @as([*:0]const u8, @ptrCast(&name_z)),
    );
    dialog.as(gtk.Window).setModal(1);

    _ = dialog.as(gtk.Dialog).addButton("Cancel", @intFromEnum(gtk.ResponseType.cancel));
    _ = dialog.as(gtk.Dialog).addButton("Don't Save", @intFromEnum(gtk.ResponseType.no));
    _ = dialog.as(gtk.Dialog).addButton("Save", @intFromEnum(gtk.ResponseType.yes));

    _ = gtk.Dialog.signals.response.connect(
        dialog.as(gtk.Dialog),
        *app.AppState,
        &onSaveDialogResponse,
        s,
        .{},
    );

    dialog.as(gtk.Widget).show();
}

fn onSaveDialogResponse(dialog: *gtk.Dialog, response_id: c_int, s: *app.AppState) callconv(.c) void {
    dialog.as(gtk.Window).destroy();

    const response: gtk.ResponseType = @enumFromInt(response_id);
    switch (response) {
        .yes => {
            // Save then close
            editor.saveCurrentFile();
            _ = doCloseCurrentTab(s);
        },
        .no => {
            // Close without saving
            _ = doCloseCurrentTab(s);
        },
        else => {
            // Cancel - do nothing
        },
    }
}

/// Save current buffer state (cursor, scroll position)
pub fn saveCurrentBufferState(s: *app.AppState) void {
    const buf = s.buffers.getActive() orelse return;

    // Get cursor position
    var cursor_iter: gtk.TextIter = undefined;
    const text_buf = s.code_view.getBuffer();
    text_buf.getIterAtMark(&cursor_iter, text_buf.getInsert());

    buf.cursor_line = @intCast(@max(1, cursor_iter.getLine() + 1));
    buf.cursor_col = @intCast(@max(1, cursor_iter.getLineOffset() + 1));

    // Get scroll position
    var visible: gdk.Rectangle = undefined;
    s.code_view.getVisibleRect(&visible);
    var top_iter: gtk.TextIter = undefined;
    _ = s.code_view.getIterAtLocation(&top_iter, visible.f_x, visible.f_y);
    buf.scroll_top = @intCast(@max(0, top_iter.getLine()));
}

/// Load active buffer into editor
pub fn loadActiveBuffer(s: *app.AppState) void {
    const buf = s.buffers.getActive() orelse return;


    if (buf.path) |path| {
        // Load file content
        editor.loadFileInternal(path, false); // false = don't create new buffer
    } else {
        // Untitled - clear editor
        editor.clearEditor();
    }

    // Restore cursor position
    restoreBufferState(s, buf);

    // Update title
    updateWindowTitle(s);
}

fn restoreBufferState(s: *app.AppState, buf: *const Buffer) void {
    const text_buf = s.code_view.getBuffer();

    // Set cursor position
    var iter: gtk.TextIter = undefined;
    _ = text_buf.getIterAtLineOffset(
        &iter,
        @intCast(@max(0, @as(i32, @intCast(buf.cursor_line)) - 1)),
        @intCast(@max(0, @as(i32, @intCast(buf.cursor_col)) - 1)),
    );
    text_buf.placeCursor(&iter);

    // Scroll to cursor (defer to let GTK layout first)
    _ = @import("glib").idleAdd(struct {
        fn cb(_: ?*anyopaque) callconv(.c) c_int {
            const state = app.state orelse return 0;
            state.code_view.scrollToMark(
                state.code_view.getBuffer().getInsert(),
                0.1,
                0,
                0,
                0,
            );
            return 0;
        }
    }.cb, null);
}

fn updateWindowTitle(s: *app.AppState) void {
    const buf = s.buffers.getActive() orelse return;
    const name = buf.getDisplayName();
    const modified_prefix: []const u8 = if (buf.modified) "• " else "";

    var title_buf: [512]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "{s}{s} - Zinc", .{ modified_prefix, name }) catch "Zinc";

    var title_z: [513]u8 = undefined;
    const len = @min(title.len, 512);
    @memcpy(title_z[0..len], title[0..len]);
    title_z[len] = 0;

    s.title_label.setText(@ptrCast(&title_z));
}

/// Apply tab bar styling
pub fn applyTheme(s: *app.AppState) void {
    const display = gdk.Display.getDefault() orelse return;
    const cfg = s.config;

    if (tabs_css_provider) |old| {
        gtk.StyleContext.removeProviderForDisplay(display, old.as(gtk.StyleProvider));
        old.as(gobject.Object).unref();
    }

    const provider = gtk.CssProvider.new();
    tabs_css_provider = provider;

    const bg = cfg.theme.background;
    const fg = cfg.theme.foreground;
    const sel = cfg.theme.selection;

    const css = std.fmt.allocPrint(
        s.allocator,
        \\.zinc-tabbar {{
        \\  background-color: #{X:0>6};
        \\  border-bottom: 1px solid rgba(255,255,255,0.1);
        \\}}
        \\.zinc-tab {{
        \\  background: transparent;
        \\  border: none;
        \\  border-radius: 4px;
        \\  padding: 4px 12px;
        \\  margin: 2px;
        \\  color: #{X:0>6};
        \\  opacity: 0.7;
        \\}}
        \\.zinc-tab:hover {{
        \\  opacity: 1;
        \\  background: rgba(255,255,255,0.05);
        \\}}
        \\.zinc-tab-active {{
        \\  background: #{X:0>6};
        \\  opacity: 1;
        \\}}
    ,
        .{ bg, fg, sel },
    ) catch return;
    defer s.allocator.free(css);

    const css_z = s.allocator.allocSentinel(u8, css.len, 0) catch return;
    defer s.allocator.free(css_z);
    @memcpy(css_z, css);

    provider.loadFromData(css_z.ptr, @intCast(css_z.len));
    gtk.StyleContext.addProviderForDisplay(
        display,
        provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
}

/// Mark current buffer as modified
pub fn markModified() void {
    const s = app.state orelse return;
    if (s.buffers.getActive()) |buf| {
        if (!buf.modified) {
            buf.modified = true;
            s.tab_bar.refresh(&s.buffers);
            updateWindowTitle(s);
        }
    }
}

/// Mark current buffer as saved (not modified)
pub fn markSaved() void {
    const s = app.state orelse return;
    if (s.buffers.getActive()) |buf| {
        buf.modified = false;
        s.tab_bar.refresh(&s.buffers);
        updateWindowTitle(s);
    }
}
