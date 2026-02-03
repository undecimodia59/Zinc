//! Syntax highlighting manager for the editor.
//!
//! This module owns GTK text tags and applies tokenizer output to the buffer.

const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk4");
const gobject = @import("gobject");
const glib = @import("glib");

const config = @import("../../utils/config.zig");
const types = @import("types.zig");
const zig_lang = @import("languages/zig.zig");
const panther_lang = @import("languages/panther.zig");
const python_lang = @import("languages/python.zig");
const go_lang = @import("languages/go.zig");
const markdown_lang = @import("languages/markdown.zig");
const c_cpp_lang = @import("languages/c_cpp.zig");
const rust_lang = @import("languages/rust.zig");
const js_lang = @import("languages/javascript.zig");
const json_lang = @import("languages/json.zig");
const yaml_lang = @import("languages/yaml.zig");
const toml_lang = @import("languages/toml.zig");
const html_lang = @import("languages/html.zig");
const css_lang = @import("languages/css.zig");
const shell_lang = @import("languages/shell.zig");
const dart_lang = @import("languages/dart.zig");

const Token = types.Token;
const TokenType = types.TokenType;
const Language = types.Language;

const TagDef = struct {
    name: [:0]const u8,
    kind: TokenType,
};

const tag_defs = [_]TagDef{
    .{ .name = "syntax.comment", .kind = .comment },
    .{ .name = "syntax.keyword", .kind = .keyword },
    .{ .name = "syntax.special", .kind = .special },
    .{ .name = "syntax.string", .kind = .string },
    .{ .name = "syntax.number", .kind = .number },
    .{ .name = "syntax.type", .kind = .type },
    .{ .name = "syntax.function", .kind = .function },
    .{ .name = "syntax.variable", .kind = .variable },
    .{ .name = "syntax.variable_decl", .kind = .variable_decl },
    .{ .name = "syntax.param", .kind = .param },
    .{ .name = "syntax.field", .kind = .field },
    .{ .name = "syntax.enum_field", .kind = .enum_field },
    .{ .name = "syntax.field_value", .kind = .field_value },
    .{ .name = "syntax.attribute", .kind = .attribute },
};

// Add new languages by defining a tokenizer in languages/ and registering here.
const languages = [_]Language{
    zig_lang.language,
    panther_lang.language,
    python_lang.language,
    go_lang.language,
    markdown_lang.language,
    c_cpp_lang.language,
    rust_lang.language,
    js_lang.language,
    json_lang.language,
    yaml_lang.language,
    toml_lang.language,
    html_lang.language,
    css_lang.language,
    shell_lang.language,
    dart_lang.language,
};

const State = struct {
    view: ?*gtk.TextView = null,
    buffer: ?*gtk.TextBuffer = null,
    language: ?*const Language = null,
    idle_pending: bool = false,
    pending_full: bool = false,
};

var state: State = .{};

pub fn init(view: *gtk.TextView, cfg: *const config.Config) void {
    state.view = view;
    state.buffer = view.getBuffer();
    ensureTags(cfg);
    scheduleHighlightFull();
}

pub fn deinit() void {
    state = .{};
}

pub fn setLanguageFromPath(path: []const u8) void {
    var ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, "")) {
        const basename = std.fs.path.basename(path);
        if (std.mem.startsWith(u8, basename, ".")) {
            ext = basename;
        }
    }

    state.language = languageForExtension(ext);
    if (state.language == null) {
        const buffer = state.buffer orelse return;
        var start_iter: gtk.TextIter = undefined;
        var end_iter: gtk.TextIter = undefined;
        buffer.getBounds(&start_iter, &end_iter);
        clearTags(buffer, &start_iter, &end_iter);
        state.pending_full = false;
        state.idle_pending = false;
    } else {
        scheduleHighlightFull();
    }
}

pub fn scheduleHighlight() void {
    if (state.buffer == null or state.language == null) return;
    if (state.idle_pending) return;
    state.idle_pending = true;
    state.pending_full = false;

    _ = glib.idleAddFull(
        glib.PRIORITY_DEFAULT_IDLE,
        struct {
            fn cb(_: ?*anyopaque) callconv(.c) c_int {
                state.idle_pending = false;
                highlightNow();
                return 0;
            }
        }.cb,
        null,
        null,
    );
}

pub fn scheduleHighlightFull() void {
    if (state.buffer == null or state.language == null) return;
    if (state.idle_pending) {
        state.pending_full = true;
        return;
    }
    state.idle_pending = true;
    state.pending_full = true;

    _ = glib.idleAddFull(
        glib.PRIORITY_DEFAULT_IDLE,
        struct {
            fn cb(_: ?*anyopaque) callconv(.c) c_int {
                state.idle_pending = false;
                highlightNow();
                return 0;
            }
        }.cb,
        null,
        null,
    );
}

pub fn applyTheme(cfg: *const config.Config) void {
    ensureTags(cfg);
}

fn highlightNow() void {
    const buffer = state.buffer orelse return;
    const lang = state.language orelse return;
    const full = state.pending_full;
    state.pending_full = false;

    var full_start: gtk.TextIter = undefined;
    var full_end: gtk.TextIter = undefined;
    buffer.getBounds(&full_start, &full_end);

    var start_iter: gtk.TextIter = undefined;
    var end_iter: gtk.TextIter = undefined;
    if (full or state.view == null) {
        start_iter = full_start;
        end_iter = full_end;
    } else {
        const view = state.view.?;
        var rect: gdk.Rectangle = undefined;
        view.getVisibleRect(&rect);
        _ = view.getIterAtLocation(&start_iter, rect.f_x, rect.f_y);
        _ = view.getIterAtLocation(&end_iter, rect.f_x + rect.f_width, rect.f_y + rect.f_height);
        start_iter.setLineOffset(0);
        _ = end_iter.forwardLine();
        end_iter.setLineOffset(0);
    }

    // Clear existing syntax tags.
    clearTags(buffer, &start_iter, &end_iter);

    const c_text = buffer.getText(&full_start, &full_end, 0);
    defer glib.free(@ptrCast(c_text));

    const source = std.mem.span(c_text);

    const tokens = lang.tokenize(std.heap.c_allocator, source) catch return;
    defer std.heap.c_allocator.free(tokens);

    const start_line: i32 = start_iter.getLine();
    const end_line: i32 = end_iter.getLine();

    for (tokens) |tok| {
        if (tok.end_line < @as(u32, @intCast(start_line)) or
            tok.start_line > @as(u32, @intCast(end_line)))
        {
            continue;
        }
        const tag_name = tagName(tok.kind) orelse continue;
        _ = buffer.getIterAtLineIndex(&start_iter, @intCast(tok.start_line), @intCast(tok.start_col));
        _ = buffer.getIterAtLineIndex(&end_iter, @intCast(tok.end_line), @intCast(tok.end_col));
        buffer.applyTagByName(tag_name.ptr, &start_iter, &end_iter);
    }
}

fn tagName(kind: TokenType) ?[:0]const u8 {
    for (tag_defs) |def| {
        if (def.kind == kind) return def.name;
    }
    return null;
}

fn ensureTags(cfg: *const config.Config) void {
    const buffer = state.buffer orelse return;
    const table = buffer.getTagTable();

    for (tag_defs) |def| {
        const color = colorForKind(cfg, def.kind);
        var buf: [8:0]u8 = undefined;
        const color_z = std.fmt.bufPrintZ(&buf, "#{X:0>6}", .{color}) catch "#000000";

        if (table.lookup(def.name.ptr)) |tag| {
            tag.as(gobject.Object).set("foreground", color_z.ptr, @as(?[*:0]const u8, null));
        } else {
            _ = buffer.createTag(def.name.ptr, "foreground", color_z.ptr, @as(?[*:0]const u8, null));
        }
    }
}

fn clearTags(buffer: *gtk.TextBuffer, start: *gtk.TextIter, end: *gtk.TextIter) void {
    for (tag_defs) |def| {
        buffer.removeTagByName(def.name.ptr, start, end);
    }
}

fn colorForKind(cfg: *const config.Config, kind: TokenType) u32 {
    return switch (kind) {
        .comment => cfg.theme.comment,
        .keyword => cfg.theme.keyword,
        .special => cfg.theme.special,
        .string => cfg.theme.string,
        .number => cfg.theme.number,
        .type => cfg.theme.type,
        .function => cfg.theme.function,
        .variable => cfg.theme.variable,
        .variable_decl => cfg.theme.variable_decl,
        .param => cfg.theme.param,
        .field => cfg.theme.field,
        .enum_field => cfg.theme.enum_field,
        .field_value => cfg.theme.field_value,
        .attribute => cfg.theme.attribute,
    };
}

fn languageForExtension(ext: []const u8) ?*const Language {
    if (ext.len == 0) return null;
    for (languages, 0..) |lang, idx| {
        for (lang.extensions) |e| {
            if (std.mem.eql(u8, ext, e)) return &languages[idx];
        }
    }
    return null;
}
