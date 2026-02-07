//! Java tokenizer for syntax highlighting.

const std = @import("std");
const types = @import("../types.zig");

const Token = types.Token;
const TokenType = types.TokenType;

pub const language = types.Language{
    .name = "java",
    .extensions = &.{ ".java" },
    .tokenize = tokenize,
};

const keywords = [_][]const u8{
    "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const",
    "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float",
    "for", "goto", "if", "implements", "import", "instanceof", "int", "interface", "long", "native",
    "new", "package", "private", "protected", "public", "return", "short", "static", "strictfp", "super",
    "switch", "synchronized", "this", "throw", "throws", "transient", "try", "void", "volatile", "while",
    "record", "sealed", "permits", "var", "yield", "module", "open", "opens", "requires",
    "exports", "uses", "provides", "to", "with",
};

const special_keywords = [_][]const u8{
    "true", "false", "null",
};

const builtin_types = [_][]const u8{
    "boolean", "byte", "char", "short", "int", "long", "float", "double", "void", "String", "Object",
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
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

fn isAsciiIdentContinue(c: u8) bool {
    return isAsciiIdentStart(c) or (c >= '0' and c <= '9');
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
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

pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) ![]Token {
    var tokens = std.ArrayList(Token).empty;
    errdefer tokens.deinit(allocator);

    var i: usize = 0;
    var line: u32 = 0;
    var col: u32 = 0;

    var expect_type_decl = false;
    var expect_type_ref = false;
    var expect_var_decl = false;

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

        // Annotations
        if (c == '@') {
            const s_line = line;
            const s_col = col;
            i += 1;
            col += 1;
            while (i < source.len) {
                const ch = source[i];
                if (isAsciiIdentContinue(ch) or ch == '.' or ch == '$') {
                    i += 1;
                    col += 1;
                    continue;
                }
                break;
            }
            try addToken(allocator, &tokens, .attribute, s_line, s_col, line, col);
            expect_type_decl = false;
            expect_type_ref = false;
            expect_var_decl = false;
            continue;
        }

        // Strings and chars
        if (c == '"' or c == '\'') {
            const quote = c;
            const s_line = line;
            const s_col = col;
            i += 1;
            col += 1;
            while (i < source.len) {
                const ch = source[i];
                if (ch == '\\') {
                    if (i + 1 < source.len) {
                        i += 2;
                        col += 2;
                        continue;
                    }
                }
                if (ch == quote) {
                    i += 1;
                    col += 1;
                    break;
                }
                if (ch == '\n') {
                    line += 1;
                    col = 0;
                    i += 1;
                    continue;
                }
                i += 1;
                col += 1;
            }
            try addToken(allocator, &tokens, .string, s_line, s_col, line, col);
            expect_type_decl = false;
            expect_type_ref = false;
            expect_var_decl = false;
            continue;
        }

        // Numbers
        if (isDigit(c)) {
            const s_line = line;
            const s_col = col;
            i += 1;
            col += 1;
            if (c == '0' and i < source.len) {
                const n = source[i];
                if (n == 'x' or n == 'X' or n == 'b' or n == 'B' or n == 'o' or n == 'O') {
                    i += 1;
                    col += 1;
                    while (i < source.len) {
                        const d = source[i];
                        if (d == '_' or isHexDigit(d)) {
                            i += 1;
                            col += 1;
                            continue;
                        }
                        break;
                    }
                    while (i < source.len and isAsciiIdentContinue(source[i])) {
                        i += 1;
                        col += 1;
                    }
                    try addToken(allocator, &tokens, .number, s_line, s_col, line, col);
                    expect_type_decl = false;
                    expect_type_ref = false;
                    expect_var_decl = false;
                    continue;
                }
            }
            while (i < source.len) {
                const d = source[i];
                if (isDigit(d) or d == '_' or d == '.' or d == 'e' or d == 'E' or d == '+' or d == '-') {
                    i += 1;
                    col += 1;
                    continue;
                }
                break;
            }
            while (i < source.len and isAsciiIdentContinue(source[i])) {
                i += 1;
                col += 1;
            }
            try addToken(allocator, &tokens, .number, s_line, s_col, line, col);
            expect_type_decl = false;
            expect_type_ref = false;
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
                if (std.mem.eql(u8, word, "class") or std.mem.eql(u8, word, "interface") or std.mem.eql(u8, word, "enum") or std.mem.eql(u8, word, "record")) {
                    expect_type_decl = true;
                } else if (std.mem.eql(u8, word, "new") or std.mem.eql(u8, word, "extends") or std.mem.eql(u8, word, "implements") or std.mem.eql(u8, word, "throws") or std.mem.eql(u8, word, "permits")) {
                    expect_type_ref = true;
                } else if (std.mem.eql(u8, word, "var")) {
                    expect_var_decl = true;
                }
            } else if (isSpecial(word)) {
                try addToken(allocator, &tokens, .special, s_line, s_col, line, col);
            } else if (expect_type_decl or expect_type_ref or isBuiltinType(word)) {
                try addToken(allocator, &tokens, .type, s_line, s_col, line, col);
                expect_type_decl = false;
                expect_type_ref = false;
            } else if (expect_var_decl) {
                try addToken(allocator, &tokens, .variable_decl, s_line, s_col, line, col);
                expect_var_decl = false;
            } else {
                var kind: TokenType = .variable;
                if (peekNonWhitespace(source, i) == '(') {
                    kind = .function;
                }
                try addToken(allocator, &tokens, kind, s_line, s_col, line, col);
            }
            continue;
        }

        if (!std.ascii.isWhitespace(c)) {
            if (expect_type_decl) expect_type_decl = false;
            if (expect_type_ref) expect_type_ref = false;
            if (expect_var_decl) expect_var_decl = false;
        }

        i += 1;
        col += 1;
    }

    return tokens.toOwnedSlice(allocator);
}
