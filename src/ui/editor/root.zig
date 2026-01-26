const std = @import("std");
const gtk = @import("gtk");
const cairo = @import("cairo1");
const gdk = @import("gdk4");
const gobject = @import("gobject");
const pango = @import("pango1");

const app = @import("../app.zig");
const gutter = @import("gutter.zig");
const io = @import("io.zig");
const static = @import("static.zig");
const vim = @import("../vim/root.zig");
const config = @import("../../utils/config.zig");

const current_line_alpha: f64 = 0.35;
const pango_scale: c_int = 1024;
const editor_css_class: [:0]const u8 = "zinc-editor";

// Track CSS provider to avoid leaking on repeated applyConfig calls
var editor_css_provider: ?*gtk.CssProvider = null;

// Track vim mode state
var vim_mode_enabled: bool = false;

/// Result of creating an editor widget.
pub const EditorResult = struct {
    root: *gtk.Box,
    scroll: *gtk.ScrolledWindow,
    text_view: *gtk.TextView,
    gutter: *gtk.DrawingArea,
    line_highlight: *gtk.DrawingArea,
};

/// Create the editor widget.
pub fn create(cfg: *const config.Config) EditorResult {
    const root = gtk.Box.new(gtk.Orientation.horizontal, 0);

    const line_gutter = gtk.DrawingArea.new();
    line_gutter.setContentWidth(54);
    line_gutter.as(gtk.Widget).setVexpand(1);
    line_gutter.as(gtk.Widget).setHexpand(0);

    const code_scroll = gtk.ScrolledWindow.new();
    code_scroll.as(gtk.Widget).setHexpand(1);
    code_scroll.as(gtk.Widget).setVexpand(1);

    const code_view = gtk.TextView.new();
    code_view.setMonospace(1);
    code_view.setEditable(1);
    code_view.setLeftMargin(8);
    code_view.setRightMargin(8);
    code_view.setTopMargin(8);
    code_view.setBottomMargin(8);

    const buffer = code_view.getBuffer();
    buffer.setText(static.title, -1);

    // Track dirty state for title updates.
    _ = gtk.TextBuffer.signals.changed.connect(
        buffer,
        *gtk.TextBuffer,
        &onBufferChanged,
        buffer,
        .{},
    );

    // Handle Tab key for spaces/tabs preference
    const key_controller = gtk.EventControllerKey.new();
    code_view.as(gtk.Widget).addController(key_controller.as(gtk.EventController));
    _ = gtk.EventControllerKey.signals.key_pressed.connect(
        key_controller,
        *gtk.TextView,
        &onEditorKeyPress,
        code_view,
        .{},
    );

    applyEditorConfig(code_view, line_gutter, cfg);

    gutter.setWidthForView(code_view, line_gutter, cfg);
    gutter.queueRedrawSoon();

    const overlay = gtk.Overlay.new();
    overlay.setChild(code_view.as(gtk.Widget));
    code_scroll.setChild(overlay.as(gtk.Widget));

    const line_highlight = gtk.DrawingArea.new();
    line_highlight.setContentWidth(1);
    line_highlight.setContentHeight(1);
    line_highlight.as(gtk.Widget).setHexpand(1);
    line_highlight.as(gtk.Widget).setVexpand(1);
    line_highlight.as(gtk.Widget).setHalign(.fill);
    line_highlight.as(gtk.Widget).setValign(.fill);
    line_highlight.as(gtk.Widget).setCanTarget(0);
    line_highlight.as(gtk.Widget).setCanFocus(0);
    overlay.addOverlay(line_highlight.as(gtk.Widget));
    overlay.setMeasureOverlay(line_highlight.as(gtk.Widget), 1);
    overlay.setClipOverlay(line_highlight.as(gtk.Widget), 0);

    initLineHighlight(line_highlight, code_view, code_scroll);
    line_highlight.as(gtk.Widget).setVisible(@intFromBool(cfg.editor.highlight_current_line));

    root.append(line_gutter.as(gtk.Widget));
    root.append(code_scroll.as(gtk.Widget));

    // Draw func + invalidation hooks live in the gutter module.
    gutter.init(line_gutter, code_view, code_scroll);

    return .{
        .root = root,
        .scroll = code_scroll,
        .text_view = code_view,
        .gutter = line_gutter,
        .line_highlight = line_highlight,
    };
}

/// Load a file into the editor.
pub fn loadFile(path: []const u8) void {
    const state = app.state orelse return;

    const content = io.readUtf8File(state.allocator, path, io.max_file_size) catch |err| {
        std.debug.print("Error reading file: {}\n", .{err});
        switch (err) {
            error.FileTooLarge => state.setStatus("Error: File too large"),
            error.InvalidUtf8 => state.setStatus("Error: File is not valid UTF-8"),
            else => state.setStatus("Error: Cannot read file"),
        }
        return;
    };
    defer state.allocator.free(content);

    const buffer = state.code_view.getBuffer();

    // GTK expects a null-terminated string.
    const content_z = state.allocator.allocSentinel(u8, content.len, 0) catch {
        state.setStatus("Error: Out of memory");
        return;
    };
    defer state.allocator.free(content_z);
    @memcpy(content_z, content);

    buffer.setText(@ptrCast(content_z.ptr), @intCast(content.len));

    // Move cursor to beginning of file
    var start_iter: gtk.TextIter = undefined;
    buffer.getStartIter(&start_iter);
    buffer.placeCursor(&start_iter);

    // Scroll to top
    state.code_view.scrollToMark(buffer.getInsert(), 0.0, 1, 0.0, 0.0);

    if (state.current_file) |f| state.allocator.free(f);
    state.current_file = state.allocator.dupe(u8, path) catch null;

    state.modified = false;
    updateWindowTitle();

    if (state.config.editor.show_line_numbers) {
        gutter.setWidthForView(state.code_view, state.gutter, state.config);
        gutter.queueRedrawSoon();
    }

    var status_buf: [512:0]u8 = undefined;
    const status = std.fmt.bufPrintZ(
        &status_buf,
        "Loaded: {s} ({d} bytes)",
        .{ std.fs.path.basename(path), content.len },
    ) catch "File loaded";
    state.setStatus(status);
}

/// Get current buffer content.
pub fn getContent(allocator: std.mem.Allocator) ?[]u8 {
    const state = app.state orelse return null;
    const buffer = state.code_view.getBuffer();

    var start_iter: gtk.TextIter = undefined;
    var end_iter: gtk.TextIter = undefined;
    buffer.getBounds(&start_iter, &end_iter);

    const c_text = buffer.getText(&start_iter, &end_iter, 0);
    defer {
        const glib = @import("glib");
        glib.free(@ptrCast(c_text));
    }

    const text_span = std.mem.span(c_text);
    return allocator.dupe(u8, text_span) catch null;
}

/// Clear the editor content.
pub fn clear() void {
    const state = app.state orelse return;
    const buffer = state.code_view.getBuffer();
    buffer.setText("", 0);
}

pub fn applyConfig(cfg: *const config.Config) void {
    const state = app.state orelse return;
    applyEditorConfig(state.code_view, state.gutter, cfg);
    state.line_highlight.as(gtk.Widget).setVisible(@intFromBool(cfg.editor.highlight_current_line));
    // Redraw line highlight to pick up new theme color
    if (cfg.editor.highlight_current_line) {
        state.line_highlight.as(gtk.Widget).queueDraw();
    }

    // Handle vim mode toggle
    if (cfg.editor.vim_mode != vim_mode_enabled) {
        vim_mode_enabled = cfg.editor.vim_mode;
        if (vim_mode_enabled) {
            vim.init(state.code_view);
        } else {
            vim.deinit(state.code_view);
        }
    }
}

/// Save edited file.
pub fn saveCurrentFile() void {
    const state = app.state orelse return;

    const path = state.current_file orelse {
        state.setStatus("No file to save");
        return;
    };

    const content = getContent(state.allocator) orelse {
        state.setStatus("Error: cannot read editor buffer");
        return;
    };
    defer state.allocator.free(content);

    io.writeFileAtomic(path, content) catch |err| {
        std.debug.print("Error saving file: {}\n", .{err});
        state.setStatus("Error: write failed");
        return;
    };

    state.modified = false;
    updateWindowTitle();

    var sb: [512:0]u8 = undefined;
    const msg = std.fmt.bufPrintZ(
        &sb,
        "Saved: {s} ({d} bytes)",
        .{ std.fs.path.basename(path), content.len },
    ) catch "Saved";
    state.setStatus(msg);
}

/// Update app state.modified.
fn onBufferChanged(_: *gtk.TextBuffer, _: *gtk.TextBuffer) callconv(.c) void {
    const state = app.state orelse return;
    if (!state.modified) {
        state.modified = true;
        updateWindowTitle();
    }
}

/// Handle special keys in editor (Tab, Enter, Backspace, Vim).
fn onEditorKeyPress(
    _: *gtk.EventControllerKey,
    keyval: c_uint,
    _: c_uint,
    modifiers: gdk.ModifierType,
    view: *gtk.TextView,
) callconv(.c) c_int {
    const state = app.state orelse return 0;
    const buffer = view.getBuffer();

    // Vim mode handling
    if (vim_mode_enabled) {
        if (vim.handleKey(view, keyval, modifiers)) {
            return 1;
        }
        // In insert mode, fall through to normal editing
        if (vim.state.mode != .insert) {
            return 1; // Block other keys in normal/visual mode
        }
    }

    // Tab key (GDK_KEY_Tab = 0xff09): insert spaces if use_spaces is enabled
    if (keyval == 0xff09) {
        if (state.config.editor.use_spaces) {
            const tab_width = state.config.editor.tab_width;

            // Create spaces string (sentinel-terminated)
            var spaces_z: [9:0]u8 = undefined;
            const count: usize = @min(tab_width, 8);
            @memset(spaces_z[0..count], ' ');
            spaces_z[count] = 0;

            buffer.insertAtCursor(@ptrCast(&spaces_z), @intCast(count));

            return 1; // Handled
        }
    }

    // Return/Enter key (0xff0d): auto-indent
    if (keyval == 0xff0d and state.config.editor.auto_indent) {
        handleAutoIndent(buffer);
        return 1;
    }

    // Backspace key (0xff08): smart backspace
    if (keyval == 0xff08) {
        if (handleSmartBackspace(buffer, state.config.editor.tab_width)) {
            return 1;
        }
    }

    return 0; // Let GTK handle it
}

/// Insert newline with same indentation as current line.
fn handleAutoIndent(buffer: *gtk.TextBuffer) void {
    var cursor_iter: gtk.TextIter = undefined;
    buffer.getIterAtMark(&cursor_iter, buffer.getInsert());

    // Get start of current line
    var line_start = cursor_iter;
    line_start.setLineOffset(0);

    // Find end of leading whitespace
    var ws_end = line_start;
    while (ws_end.endsLine() == 0) {
        const c = ws_end.getChar();
        if (c != ' ' and c != '\t') break;
        if (ws_end.forwardChar() == 0) break;
    }

    // Extract the indentation
    const indent_ptr = buffer.getText(&line_start, &ws_end, 0);
    defer {
        const glib = @import("glib");
        glib.free(@ptrCast(indent_ptr));
    }
    const indent = std.mem.span(indent_ptr);

    // Build newline + indent string
    var insert_buf: [256:0]u8 = undefined;
    if (indent.len + 1 < insert_buf.len) {
        insert_buf[0] = '\n';
        @memcpy(insert_buf[1 .. 1 + indent.len], indent);
        insert_buf[1 + indent.len] = 0;
        buffer.insertAtCursor(@ptrCast(&insert_buf), @intCast(1 + indent.len));
    } else {
        // Fallback: just insert newline
        buffer.insertAtCursor("\n", 1);
    }
}

/// Delete full indent level if cursor is in leading whitespace.
/// Returns true if handled, false to let GTK handle normal backspace.
fn handleSmartBackspace(buffer: *gtk.TextBuffer, tab_width: u8) bool {
    var cursor_iter: gtk.TextIter = undefined;
    buffer.getIterAtMark(&cursor_iter, buffer.getInsert());

    const col = cursor_iter.getLineOffset();
    if (col == 0) return false; // At line start, let GTK handle

    // Get start of line
    var line_start = cursor_iter;
    line_start.setLineOffset(0);

    // Check if we're in leading whitespace only
    var check = line_start;
    while (check.getLineOffset() < col) {
        const c = check.getChar();
        if (c != ' ' and c != '\t') return false; // Not in pure whitespace
        if (check.forwardChar() == 0) break;
    }

    // We're in leading whitespace. Calculate chars to delete.
    const tw: i32 = @intCast(tab_width);
    const chars_to_delete: i32 = if (@mod(col, tw) == 0) tw else @mod(col, tw);

    // Delete backwards
    var del_start = cursor_iter;
    if (del_start.backwardChars(chars_to_delete) == 0) return false;

    buffer.delete(&del_start, &cursor_iter);
    return true;
}

/// Update title when buffer changes or file is loaded.
fn updateWindowTitle() void {
    const state = app.state orelse return;

    const base = if (state.current_file) |p| std.fs.path.basename(p) else "Untitled";

    var buf: [256:0]u8 = undefined;
    const title = if (state.modified)
        (std.fmt.bufPrintZ(&buf, "Zinc IDE - {s} ●", .{base}) catch "Zinc IDE")
    else
        (std.fmt.bufPrintZ(&buf, "Zinc IDE - {s}", .{base}) catch "Zinc IDE");

    state.setTitle(title);
}

fn initLineHighlight(
    area: *gtk.DrawingArea,
    view: *gtk.TextView,
    scroll: *gtk.ScrolledWindow,
) void {
    area.setDrawFunc(&lineHighlightDraw, view, null);

    const vadj = scroll.getVadjustment();
    _ = gtk.Adjustment.signals.value_changed.connect(
        vadj,
        *gtk.DrawingArea,
        &queueLineHighlightFromAdj,
        area,
        .{},
    );

    const buffer = view.getBuffer();
    _ = gtk.TextBuffer.signals.changed.connect(
        buffer,
        *gtk.DrawingArea,
        &queueLineHighlightFromBuffer,
        area,
        .{},
    );
    _ = gtk.TextBuffer.signals.mark_set.connect(
        buffer,
        *gtk.DrawingArea,
        &queueLineHighlightFromMark,
        area,
        .{},
    );
}

fn queueLineHighlightFromAdj(_: *gtk.Adjustment, area: *gtk.DrawingArea) callconv(.c) void {
    area.as(gtk.Widget).queueDraw();
}

fn queueLineHighlightFromBuffer(_: *gtk.TextBuffer, area: *gtk.DrawingArea) callconv(.c) void {
    area.as(gtk.Widget).queueDraw();
}

fn queueLineHighlightFromMark(
    _: *gtk.TextBuffer,
    _: *gtk.TextIter,
    _: *gtk.TextMark,
    area: *gtk.DrawingArea,
) callconv(.c) void {
    area.as(gtk.Widget).queueDraw();
}

fn lineHighlightDraw(
    area: *gtk.DrawingArea,
    cr: *cairo.Context,
    width: c_int,
    height: c_int,
    view_ptr: ?*anyopaque,
) callconv(.c) void {
    _ = area;
    const view_opaque = view_ptr orelse return;
    const view: *gtk.TextView = @ptrCast(@alignCast(view_opaque));

    var rect: gdk.Rectangle = undefined;
    view.getVisibleRect(&rect);

    var iter: gtk.TextIter = undefined;
    const buffer = view.getBuffer();
    buffer.getIterAtMark(&iter, buffer.getInsert());
    iter.setLineOffset(0);

    var line_y: c_int = 0;
    var line_h: c_int = 0;
    view.getLineYrange(&iter, &line_y, &line_h);

    const y: c_int = line_y - rect.f_y;
    if (y + line_h < 0 or y > height) return;

    const color = if (app.state) |s| s.config.theme.line_highlight else 0x2d2d2d;
    const rgb = colorToRgb(color);
    cr.setSourceRgba(rgb[0], rgb[1], rgb[2], current_line_alpha);
    cr.rectangle(
        0,
        @floatFromInt(y),
        @floatFromInt(width),
        @floatFromInt(line_h),
    );
    cr.fill();
}

fn applyEditorConfig(
    view: *gtk.TextView,
    gutter_area: *gtk.DrawingArea,
    cfg: *const config.Config,
) void {
    applyFontAndTheme(view, cfg);
    applyTabWidth(view, cfg.editor.tab_width, cfg.editor.font_family, cfg.editor.font_size);

    if (cfg.editor.word_wrap) {
        view.setWrapMode(gtk.WrapMode.word_char);
    } else {
        view.setWrapMode(gtk.WrapMode.none);
    }

    if (cfg.editor.show_line_numbers) {
        gutter_area.as(gtk.Widget).setVisible(1);
        gutter.setWidthForView(view, gutter_area, cfg);
        gutter_area.as(gtk.Widget).queueDraw();
    } else {
        gutter_area.as(gtk.Widget).setVisible(0);
        gutter_area.setContentWidth(0);
    }
}

fn applyFontAndTheme(view: *gtk.TextView, cfg: *const config.Config) void {
    const display = gdk.Display.getDefault() orelse return;

    // Remove old provider if it exists
    if (editor_css_provider) |old| {
        gtk.StyleContext.removeProviderForDisplay(display, old.as(gtk.StyleProvider));
        old.as(gobject.Object).unref();
    }

    const provider = gtk.CssProvider.new();
    editor_css_provider = provider;

    // Convert theme colors to CSS hex strings
    const bg = cfg.theme.background;
    const fg = cfg.theme.foreground;
    const sel = cfg.theme.selection;
    const cursor = cfg.theme.cursor;

    const css = std.fmt.allocPrint(
        app.allocator,
        \\.zinc-editor {{
        \\  font-family: "{s}";
        \\  font-size: {d}pt;
        \\  background-color: #{X:0>6};
        \\  color: #{X:0>6};
        \\  caret-color: #{X:0>6};
        \\}}
        \\.zinc-editor text {{
        \\  background-color: #{X:0>6};
        \\}}
        \\.zinc-editor text selection {{
        \\  background-color: #{X:0>6};
        \\}}
    ,
        .{ cfg.editor.font_family, cfg.editor.font_size, bg, fg, cursor, bg, sel },
    ) catch return;
    defer app.allocator.free(css);

    const css_z = app.allocator.allocSentinel(u8, css.len, 0) catch return;
    defer app.allocator.free(css_z);
    @memcpy(css_z, css);

    view.as(gtk.Widget).addCssClass(editor_css_class.ptr);
    provider.loadFromData(css_z.ptr, @intCast(css_z.len));
    gtk.StyleContext.addProviderForDisplay(
        display,
        provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
}

fn applyTabWidth(view: *gtk.TextView, tab_width: u8, family: []const u8, size: u16) void {
    const context = view.as(gtk.Widget).getPangoContext();
    const desc = pango.FontDescription.new();
    defer pango.FontDescription.free(desc);

    const family_z = app.allocator.allocSentinel(u8, family.len, 0) catch return;
    defer app.allocator.free(family_z);
    @memcpy(family_z, family);
    pango.FontDescription.setFamily(desc, family_z.ptr);
    pango.FontDescription.setSize(desc, @as(c_int, size) * pango_scale);

    const metrics = pango.Context.getMetrics(context, desc, null);
    defer pango.FontMetrics.unref(metrics);

    const char_width_units = pango.FontMetrics.getApproximateCharWidth(metrics);
    const char_width_px = @divTrunc(char_width_units + (pango_scale / 2), pango_scale);
    const tab_px = @as(c_int, tab_width) * char_width_px;

    const tabs = pango.TabArray.new(1, 1);
    defer pango.TabArray.free(tabs);
    pango.TabArray.setTab(tabs, 0, pango.TabAlign.left, tab_px);
    view.setTabs(tabs);
}

fn colorToRgb(color: u32) [3]f64 {
    const r: f64 = @as(f64, @floatFromInt((color >> 16) & 0xff)) / 255.0;
    const g: f64 = @as(f64, @floatFromInt((color >> 8) & 0xff)) / 255.0;
    const b: f64 = @as(f64, @floatFromInt(color & 0xff)) / 255.0;
    return .{ r, g, b };
}
