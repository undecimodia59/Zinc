//! Dart tokenizer for syntax highlighting.

const std = @import("std");
const types = @import("../types.zig");

const Token = types.Token;
const TokenType = types.TokenType;

pub const language = types.Language{
    .name = "dart",
    .extensions = &.{".dart"},
    .tokenize = tokenize,
};

const keywords = [_][]const u8{
    "abstract", "as",       "assert", "async",    "await",  "base",   "break",    "case",   "catch",
    "class",    "const",    "continue", "covariant", "default", "deferred", "do", "else", "enum",
    "export",   "extends",  "extension", "external", "factory", "final", "finally", "for", "get",
    "hide",     "if",       "implements", "import", "in", "is", "late", "library", "mixin", "new",
    "on",       "operator", "part",   "required", "rethrow", "return", "sealed", "set", "show",
    "static",   "super",    "switch", "sync",     "this",   "throw",  "try", "typedef", "var",
    "when",     "while",    "with",   "yield",
};

const special_keywords = [_][]const u8{
    "true", "false", "null",
};

const builtin_types = [_][]const u8{
    "int", "double", "num", "String", "bool", "List", "Map", "Set", "Object", "dynamic", "void",
    "Never", "Future", "Stream", "Iterable", "DateTime", "RegExp", "Uri", "Duration", "Symbol", "BigInt",
};

fn isKeyword(word: []const u8) bool {
    for (keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

fn isSpecial(word: []const u8) bool {
    for (special_keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

fn isBuiltinType(word: []const u8) bool {
    for (builtin_types) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

fn isAsciiIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isAsciiIdentContinue(c: u8) bool {
    return isAsciiIdentStart(c) or (c >= '0' and c <= '9');
}

fn isUppercaseStart(word: []const u8) bool {
    if (word.len == 0) return false;
    const c = word[0];
    return c >= 'A' and c <= 'Z';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isQuote(c: u8) bool {
    return c == '"' or c == '\'';
}

fn addToken(allocator: std.mem.Allocator, list: *std.ArrayList(Token), kind: TokenType, s_line: u32, s_col: u32, e_line: u32, e_col: u32) !void {
    if (s_line == e_line and s_col == e_col) return;
    try list.append(allocator, .{ .start_line = s_line, .start_col = s_col, .end_line = e_line, .end_col = e_col, .kind = kind });
}

fn peekNonWhitespace(source: []const u8, start: usize) ?u8 {
    var idx = start;
    while (idx < source.len) : (idx += 1) {
        const c = source[idx];
        if (!std.ascii.isWhitespace(c)) return c;
    }
    return null;
}

fn peekPrevNonWhitespace(source: []const u8, start: usize) ?u8 {
    if (start == 0) return null;
    var idx: usize = start - 1;
    while (true) {
        const c = source[idx];
        if (!std.ascii.isWhitespace(c)) return c;
        if (idx == 0) break;
        idx -= 1;
    }
    return null;
}

pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) ![]Token {
    var tokens = std.ArrayList(Token).empty;
    errdefer tokens.deinit(allocator);

    var i: usize = 0;
    var line: u32 = 0;
    var col: u32 = 0;

    var expect_fn_name = false;
    var expect_type_decl = false;
    var expect_var_decl = false;
    var pending_fn_sig = false;
    var fn_sig = false;
    var fn_paren_depth: u32 = 0;
    var param_expect_name = false;
    var param_after_type = false;

    while (i < source.len) {
        const c = source[i];

        if (c == '\n') {
            line += 1;
            col = 0;
            i += 1;
            continue;
        }

        // Line comment
        if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
            const s_line = line;
            const s_col = col;
            i += 2;
            col += 2;
            while (i < source.len and source[i] != '\n') {
                i += 1;
                col += 1;
            }
            try addToken(allocator, &tokens, .comment, s_line, s_col, line, col);
            continue;
        }

        // Block comment
        if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
            const s_line = line;
            const s_col = col;
            i += 2;
            col += 2;
            while (i < source.len) {
                if (source[i] == '\n') {
                    line += 1;
                    col = 0;
                    i += 1;
                    continue;
                }
                if (i + 1 < source.len and source[i] == '*' and source[i + 1] == '/') {
                    i += 2;
                    col += 2;
                    break;
                }
                i += 1;
                col += 1;
            }
            try addToken(allocator, &tokens, .comment, s_line, s_col, line, col);
            continue;
        }

        // Raw strings (r'...', r"...", r'''...''', r"""...""")
        if ((c == 'r' or c == 'R') and i + 1 < source.len and isQuote(source[i + 1])) {
            const s_line = line;
            const s_col = col;
            const quote = source[i + 1];
            var triple = false;
            i += 2;
            col += 2;
            if (i + 1 < source.len and source[i] == quote and source[i + 1] == quote) {
                triple = true;
                i += 2;
                col += 2;
            }
            while (i < source.len) {
                const ch = source[i];
                if (ch == '\n') {
                    line += 1;
                    col = 0;
                    i += 1;
                    continue;
                }
                if (ch == quote) {
                    if (triple) {
                        if (i + 2 < source.len and source[i + 1] == quote and source[i + 2] == quote) {
                            i += 3;
                            col += 3;
                            break;
                        }
                    } else {
                        i += 1;
                        col += 1;
                        break;
                    }
                }
                i += 1;
                col += 1;
            }
            try addToken(allocator, &tokens, .string, s_line, s_col, line, col);
            expect_fn_name = false;
            expect_type_decl = false;
            expect_var_decl = false;
            continue;
        }

        // Strings (single, double, triple)
        if (isQuote(c)) {
            const quote = c;
            const s_line = line;
            const s_col = col;
            var triple = false;
            if (i + 2 < source.len and source[i + 1] == quote and source[i + 2] == quote) {
                triple = true;
                i += 3;
                col += 3;
            } else {
                i += 1;
                col += 1;
            }
            while (i < source.len) {
                const ch = source[i];
                if (!triple and ch == '\\') {
                    if (i + 1 < source.len) {
                        i += 2;
                        col += 2;
                        continue;
                    }
                }
                if (ch == '\n') {
                    line += 1;
                    col = 0;
                    i += 1;
                    continue;
                }
                if (ch == quote) {
                    if (triple) {
                        if (i + 2 < source.len and source[i + 1] == quote and source[i + 2] == quote) {
                            i += 3;
                            col += 3;
                            break;
                        }
                    } else {
                        i += 1;
                        col += 1;
                        break;
                    }
                }
                i += 1;
                col += 1;
            }
            try addToken(allocator, &tokens, .string, s_line, s_col, line, col);
            expect_fn_name = false;
            expect_type_decl = false;
            expect_var_decl = false;
            continue;
        }

        // Numbers
        if (isDigit(c)) {
            const s_line = line;
            const s_col = col;
            i += 1;
            col += 1;
            while (i < source.len) {
                const d = source[i];
                if (isDigit(d) or d == '_' or d == '.' or d == 'e' or d == 'E' or d == '+' or d == '-') {
                    i += 1;
                    col += 1;
                    continue;
                }
                break;
            }
            try addToken(allocator, &tokens, .number, s_line, s_col, line, col);
            expect_fn_name = false;
            expect_type_decl = false;
            expect_var_decl = false;
            continue;
        }

        // Identifiers
        if (isAsciiIdentStart(c)) {
            const s_line = line;
            const s_col = col;
            const start = i;
            i += 1;
            col += 1;
            while (i < source.len and isAsciiIdentContinue(source[i])) {
                i += 1;
                col += 1;
            }
            const word = source[start..i];
            if (isKeyword(word)) {
                try addToken(allocator, &tokens, .keyword, s_line, s_col, line, col);
                if (std.mem.eql(u8, word, "class") or std.mem.eql(u8, word, "enum") or std.mem.eql(u8, word, "mixin") or std.mem.eql(u8, word, "extension") or std.mem.eql(u8, word, "typedef")) {
                    expect_type_decl = true;
                } else if (std.mem.eql(u8, word, "var") or std.mem.eql(u8, word, "final") or std.mem.eql(u8, word, "const") or std.mem.eql(u8, word, "late")) {
                    expect_var_decl = true;
                } else if (std.mem.eql(u8, word, "get") or std.mem.eql(u8, word, "set") or std.mem.eql(u8, word, "operator")) {
                    expect_fn_name = true;
                }
            } else if (isSpecial(word)) {
                try addToken(allocator, &tokens, .special, s_line, s_col, line, col);
            } else if (expect_type_decl) {
                try addToken(allocator, &tokens, .type, s_line, s_col, line, col);
                expect_type_decl = false;
            } else if (expect_fn_name) {
                try addToken(allocator, &tokens, .function, s_line, s_col, line, col);
                expect_fn_name = false;
                pending_fn_sig = true;
            } else if (expect_var_decl) {
                try addToken(allocator, &tokens, .variable_decl, s_line, s_col, line, col);
                expect_var_decl = false;
            } else if (fn_sig and (param_expect_name or param_after_type)) {
                if (param_after_type) {
                    try addToken(allocator, &tokens, .param, s_line, s_col, line, col);
                    param_after_type = false;
                } else if (isBuiltinType(word) or isUppercaseStart(word)) {
                    try addToken(allocator, &tokens, .type, s_line, s_col, line, col);
                    param_after_type = true;
                    param_expect_name = false;
                } else {
                    try addToken(allocator, &tokens, .param, s_line, s_col, line, col);
                    param_expect_name = false;
                }
            } else {
                var kind: TokenType = .variable;
                if (peekNonWhitespace(source, i) == '(') {
                    kind = .function;
                    const prev = peekPrevNonWhitespace(source, start);
                    if (prev == null or prev == ';' or prev == '{' or prev == '}') {
                        pending_fn_sig = true;
                    }
                }
                if (isBuiltinType(word)) kind = .type;
                try addToken(allocator, &tokens, kind, s_line, s_col, line, col);
            }
            continue;
        }

        if (!std.ascii.isWhitespace(c) and expect_fn_name) {
            expect_fn_name = false;
        }

        if (c == '(' and pending_fn_sig) {
            pending_fn_sig = false;
            fn_sig = true;
            fn_paren_depth = 1;
            param_expect_name = true;
            param_after_type = false;
            i += 1;
            col += 1;
            continue;
        }

        if (c == '(' and fn_sig) {
            fn_paren_depth += 1;
            param_expect_name = true;
            param_after_type = false;
        } else if (c == ')' and fn_sig and fn_paren_depth > 0) {
            fn_paren_depth -= 1;
            param_expect_name = false;
            param_after_type = false;
            if (fn_paren_depth == 0) {
                fn_sig = false;
            }
        } else if (c == ',' and fn_sig and fn_paren_depth > 0) {
            param_expect_name = true;
            param_after_type = false;
        }

        i += 1;
        col += 1;
    }

    return tokens.toOwnedSlice(allocator);
}
