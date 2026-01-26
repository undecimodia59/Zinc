const std = @import("std");
const gtk = @import("gtk");
const cairo = @import("cairo1");
const gdk = @import("gdk4");
const pango = @import("pango1");

const app = @import("../app.zig");
const config = @import("../../utils/config.zig");

const GutterMode = config.LineNumberMode;
const pango_scale: c_int = 1024;

/// Attach gutter draw and invalidation handlers.
pub fn init(gutter: *gtk.DrawingArea, view: *gtk.TextView, scroll: *gtk.ScrolledWindow) void {
    gutter.setDrawFunc(&gutterDraw, view, null);

    // Redraw when scrolling.
    const vadj = scroll.getVadjustment();
    _ = gtk.Adjustment.signals.value_changed.connect(
        vadj,
        *gtk.TextView,
        &queueGutterDrawFromAdj,
        view,
        .{},
    );

    // Redraw on text changes.
    const buffer = view.getBuffer();
    _ = gtk.TextBuffer.signals.changed.connect(
        buffer,
        *gtk.TextView,
        &queueGutterDrawFromBuffer,
        view,
        .{},
    );

    _ = gtk.TextBuffer.signals.mark_set.connect(
        buffer,
        *gtk.TextView,
        &onMarkSetRedraw,
        view,
        .{},
    );

    // Redraw on cursor move: simplest is redraw on key presses.
    const keyc = gtk.EventControllerKey.new();
    view.as(gtk.Widget).addController(keyc.as(gtk.EventController));
    _ = gtk.EventControllerKey.signals.key_pressed.connect(
        keyc,
        *gtk.TextView,
        &onEditorKeypressRedraw,
        view,
        .{},
    );
}

pub fn queueRedrawSoon() void {
    const glib = @import("glib");
    const s = app.state orelse return;

    // Run after GTK finishes layout/size allocation for the newly set text.
    _ = glib.idleAddFull(
        glib.PRIORITY_DEFAULT_IDLE,
        struct {
            fn cb(data: ?*anyopaque) callconv(.c) c_int {
                const st: *app.AppState = @ptrCast(@alignCast(data.?));
                st.gutter.as(gtk.Widget).queueDraw();
                return 0; // remove source
            }
        }.cb,
        s,
        null,
    );
}

pub fn setWidthForView(view: *gtk.TextView, gutter: *gtk.DrawingArea, cfg: *const config.Config) void {
    const buffer = view.getBuffer();
    const lines: c_int = buffer.getLineCount();
    // Buffer always has at least 1 line, but safe-guard against edge cases.
    const count = if (lines < 1) 1 else lines;

    // We strictly count the digits needed for the current line count.
    const digits: c_int = countDigits(count);

    const digit_px: c_int = getDigitWidth(view, cfg);

    // Left: 2px (just enough so it doesn't touch the edge).
    // Right: 6px (kept larger to separate line numbers from code).
    const pad_left: c_int = 2;
    const pad_right: c_int = 6;

    const w: c_int = pad_left + pad_right + (digits * digit_px);
    gutter.setContentWidth(w);
}

fn queueGutterDrawImpl() void {
    const s = app.state orelse return;
    s.gutter.as(gtk.Widget).queueDraw();
}

fn queueGutterDrawFromAdj(_: *gtk.Adjustment, _: *gtk.TextView) callconv(.c) void {
    queueGutterDrawImpl();
}

fn queueGutterDrawFromBuffer(_: *gtk.TextBuffer, _: *gtk.TextView) callconv(.c) void {
    queueGutterDrawImpl();
}

fn onEditorKeypressRedraw(
    _: *gtk.EventControllerKey,
    _: c_uint,
    _: c_uint,
    _: gdk.ModifierType,
    _: *gtk.TextView,
) callconv(.c) c_int {
    queueGutterDrawImpl();
    return 0;
}

fn gutterDraw(
    area: *gtk.DrawingArea,
    cr: *cairo.Context,
    width: c_int,
    height: c_int,
    view_ptr: ?*anyopaque,
) callconv(.c) void {
    _ = area;

    const view_opaque = view_ptr orelse return;
    const view: *gtk.TextView = @ptrCast(@alignCast(view_opaque));

    // ---- style ----
    const cfg = if (app.state) |s| s.config else null;
    const family = if (cfg) |c| c.editor.font_family else "monospace";
    const size = if (cfg) |c| c.editor.font_size else 12;
    var family_buf: [256:0]u8 = undefined;
    const family_z: [*:0]const u8 = if (family.len > 0 and family.len < family_buf.len) blk: {
        @memcpy(family_buf[0..family.len], family);
        family_buf[family.len] = 0;
        break :blk &family_buf;
    } else "monospace";
    cr.selectFontFace(family_z, .normal, .normal);
    cr.setFontSize(@floatFromInt(size));

    // background - use theme background (slightly different for contrast)
    const bg = if (cfg) |c| c.theme.background else 0x1e1e1e;
    const bg_rgb = colorToRgb(bg);
    cr.setSourceRgb(bg_rgb[0] * 0.9, bg_rgb[1] * 0.9, bg_rgb[2] * 0.9);
    cr.rectangle(0, 0, @floatFromInt(width), @floatFromInt(height));
    cr.fill();

    // text color - use comment color for line numbers (typically dimmer)
    const fg = if (cfg) |c| c.theme.comment else 0xbfbfbf;
    const fg_rgb = colorToRgb(fg);
    cr.setSourceRgb(fg_rgb[0], fg_rgb[1], fg_rgb[2]);

    const buffer = view.getBuffer();

    // cursor logic
    const has_focus = view.as(gtk.Widget).hasFocus() != 0;
    const real_cursor_line: i32 = getCursorLine(buffer);
    const cursor_line: i32 = if (has_focus) real_cursor_line else 0;
    const active_line: i32 = if (has_focus) real_cursor_line else -1;

    const mode: GutterMode = if (cfg) |c| c.editor.line_number_mode else .absolute;

    // visible rect
    var rect: gdk.Rectangle = undefined;
    view.getVisibleRect(&rect);

    // first visible line
    var iter: gtk.TextIter = undefined;
    _ = view.getIterAtLocation(&iter, rect.f_x, rect.f_y);
    iter.setLineOffset(0);

    // pixel position of that line
    var line_y: c_int = 0;
    var line_h: c_int = 0;
    view.getLineYrange(&iter, &line_y, &line_h);

    // convert to gutter coords
    var y: c_int = line_y - rect.f_y;

    const pad_right: f64 = 6;

    while (y < height) {
        const line0: i32 = iter.getLine();

        const is_current = line0 == active_line;

        // format number
        var buf: [32:0]u8 = undefined;
        const number_z: [:0]const u8 = switch (mode) {
            .absolute => std.fmt.bufPrintZ(&buf, "{d}", .{line0 + 1}) catch "0",
            .relative => blk: {
                if (line0 == cursor_line)
                    break :blk std.fmt.bufPrintZ(&buf, "{d}", .{line0 + 1}) catch "0";
                const d: u32 = @abs(line0 - cursor_line);
                break :blk std.fmt.bufPrintZ(&buf, "{d}", .{d}) catch "0";
            },
        };

        // measure text for right-align
        cr.selectFontFace("monospace", .normal, if (is_current) .bold else .normal);
        var ext: cairo.TextExtents = undefined;
        cr.textExtents(number_z.ptr, &ext);

        const x: f64 =
            @as(f64, @floatFromInt(width)) -
            pad_right -
            (ext.width + ext.x_bearing);

        // baseline near bottom of line box
        const baseline_y: f64 = @floatFromInt(y + line_h - 4);

        cr.moveTo(x, baseline_y);
        cr.showText(number_z.ptr);

        if (iter.forwardLine() == 0) break;

        // next line geometry
        view.getLineYrange(&iter, &line_y, &line_h);
        y = line_y - rect.f_y;
    }
}

fn onMarkSetRedraw(
    _: *gtk.TextBuffer,
    _: *gtk.TextIter,
    _: *gtk.TextMark,
    _: *gtk.TextView,
) callconv(.c) void {
    queueGutterDrawImpl();
}

fn getCursorLine(buffer: *gtk.TextBuffer) i32 {
    var iter: gtk.TextIter = undefined;
    buffer.getIterAtMark(&iter, buffer.getInsert());
    return iter.getLine();
}

inline fn countDigits(n_in: c_int) c_int {
    var n: c_int = if (n_in < 0) -n_in else n_in;
    if (n == 0) return 1;
    var d: c_int = 0;
    while (n > 0) : (n = @divTrunc(n, 10)) {
        d += 1;
    }
    return d;
}

fn getDigitWidth(view: *gtk.TextView, cfg: *const config.Config) c_int {
    const context = view.as(gtk.Widget).getPangoContext();
    const desc = pango.FontDescription.new();
    defer pango.FontDescription.free(desc);

    const family_z = app.allocator.allocSentinel(u8, cfg.editor.font_family.len, 0) catch return 8;
    defer app.allocator.free(family_z);
    @memcpy(family_z, cfg.editor.font_family);
    pango.FontDescription.setFamily(desc, family_z.ptr);
    pango.FontDescription.setSize(desc, @as(c_int, cfg.editor.font_size) * pango_scale);

    const metrics = pango.Context.getMetrics(context, desc, null);
    defer pango.FontMetrics.unref(metrics);

    const width_units = pango.FontMetrics.getApproximateDigitWidth(metrics);
    const width_px = @divTrunc(width_units + (pango_scale / 2), pango_scale);
    return if (width_px > 0) width_px else 8;
}

fn colorToRgb(color: u32) [3]f64 {
    const r: f64 = @as(f64, @floatFromInt((color >> 16) & 0xff)) / 255.0;
    const g: f64 = @as(f64, @floatFromInt((color >> 8) & 0xff)) / 255.0;
    const b: f64 = @as(f64, @floatFromInt(color & 0xff)) / 255.0;
    return .{ r, g, b };
}
