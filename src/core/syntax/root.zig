//! Syntax highlighting manager for the editor.
//!
//! This module owns GTK text tags and applies tokenizer output to the buffer.

const std = @import("std");
const gtk = @import("gtk");
const gobject = @import("gobject");
const glib = @import("glib");

const config = @import("../../utils/config.zig");
const types = @import("types.zig");
const zig_lang = @import("languages/zig.zig");
const panther_lang = @import("languages/panther.zig");

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
    .{ .name = "syntax.type", .kind = .@"type" },
    .{ .name = "syntax.function", .kind = .function },
    .{ .name = "syntax.variable", .kind = .variable },
    .{ .name = "syntax.variable_decl", .kind = .variable_decl },
    .{ .name = "syntax.param", .kind = .param },
    .{ .name = "syntax.field", .kind = .field },
    .{ .name = "syntax.enum_field", .kind = .enum_field },
    .{ .name = "syntax.field_value", .kind = .field_value },
};

// Add new languages by defining a tokenizer in languages/ and registering here.
const languages = [_]Language{
    zig_lang.language,
    panther_lang.language,
};

const State = struct {
    view: ?*gtk.TextView = null,
    buffer: ?*gtk.TextBuffer = null,
    language: ?*const Language = null,
    idle_pending: bool = false,
};

var state: State = .{};

pub fn init(view: *gtk.TextView, cfg: *const config.Config) void {
    state.view = view;
    state.buffer = view.getBuffer();
    ensureTags(cfg);
    scheduleHighlight();
}

pub fn deinit() void {
    state = .{};
}

pub fn setLanguageFromPath(path: []const u8) void {
    const ext = std.fs.path.extension(path);
    state.language = languageForExtension(ext);
    if (state.language == null) {
        const buffer = state.buffer orelse return;
        var start_iter: gtk.TextIter = undefined;
        var end_iter: gtk.TextIter = undefined;
        buffer.getBounds(&start_iter, &end_iter);
        clearTags(buffer, &start_iter, &end_iter);
    }
}

pub fn scheduleHighlight() void {
    if (state.buffer == null or state.language == null) return;
    if (state.idle_pending) return;
    state.idle_pending = true;

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

    var start_iter: gtk.TextIter = undefined;
    var end_iter: gtk.TextIter = undefined;
    buffer.getBounds(&start_iter, &end_iter);

    // Clear existing syntax tags.
    clearTags(buffer, &start_iter, &end_iter);

    const c_text = buffer.getText(&start_iter, &end_iter, 0);
    defer glib.free(@ptrCast(c_text));

    const source = std.mem.span(c_text);

    const tokens = lang.tokenize(std.heap.c_allocator, source) catch return;
    defer std.heap.c_allocator.free(tokens);

    for (tokens) |tok| {
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
        .@"type" => cfg.theme.type,
        .function => cfg.theme.function,
        .variable => cfg.theme.variable,
        .variable_decl => cfg.theme.variable_decl,
        .param => cfg.theme.param,
        .field => cfg.theme.field,
        .enum_field => cfg.theme.enum_field,
        .field_value => cfg.theme.field_value,
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
