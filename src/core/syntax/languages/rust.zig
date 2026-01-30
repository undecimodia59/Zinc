//! Rust tokenizer for syntax highlighting.

const std = @import("std");
const types = @import("../types.zig");

const Token = types.Token;
const TokenType = types.TokenType;

pub const language = types.Language{
    .name = "rust",
    .extensions = &.{".rs"},
    .tokenize = tokenize,
};

const keywords = [_][]const u8{
    "as",    "break", "const",    "continue", "crate",  "else", "enum",  "extern", "false",
    "fn",    "for",   "if",       "impl",     "in",     "let",  "loop",  "match",  "mod",
    "move",  "mut",   "pub",      "ref",      "return", "self", "Self",  "static", "struct",
    "super", "trait", "true",     "type",     "unsafe", "use",  "where", "while",  "async",
    "await", "dyn",   "println!",
};

const special_keywords = [_][]const u8{
    "None", "Some", "Ok", "Err",
};

const builtin_types = [_][]const u8{
    "bool", "char",  "str",  "String",
    "i8",   "i16",   "i32",  "i64",
    "i128", "isize", "u8",   "u16",
    "u32",  "u64",   "u128", "usize",
    "f32",  "f64",
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
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '\'';
}

fn isAsciiIdentContinue(c: u8) bool {
    return isAsciiIdentStart(c) or (c >= '0' and c <= '9');
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
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

    var expect_fn_name = false;
    var expect_type_decl = false;
    var expect_var_decl = false;
    var fn_sig = false;
    var fn_paren_depth: u32 = 0;
    var param_expect_name = false;
    var param_type_context = false;
    var return_type_context = false;

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
            while (i < source.len and isAsciiIdentContinue(source[i])) {
                i += 1;
                col += 1;
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
            var word = source[start..i];
            if (i < source.len and source[i] == '!') {
                i += 1;
                col += 1;
                word = source[start..i];
                try addToken(allocator, &tokens, .keyword, s_line, s_col, line, col);
                continue;
            }
            if (isKeyword(word)) {
                try addToken(allocator, &tokens, .keyword, s_line, s_col, line, col);
                if (std.mem.eql(u8, word, "fn")) {
                    expect_fn_name = true;
                    fn_sig = true;
                    fn_paren_depth = 0;
                    param_expect_name = false;
                    param_type_context = false;
                    return_type_context = false;
                } else if (std.mem.eql(u8, word, "struct") or std.mem.eql(u8, word, "enum") or std.mem.eql(u8, word, "trait") or std.mem.eql(u8, word, "type")) {
                    expect_type_decl = true;
                } else if (std.mem.eql(u8, word, "let") or std.mem.eql(u8, word, "const") or std.mem.eql(u8, word, "static")) {
                    expect_var_decl = true;
                }
            } else if (isSpecial(word)) {
                try addToken(allocator, &tokens, .special, s_line, s_col, line, col);
            } else if (expect_type_decl) {
                try addToken(allocator, &tokens, .type, s_line, s_col, line, col);
                expect_type_decl = false;
            } else if (expect_fn_name) {
                try addToken(allocator, &tokens, .function, s_line, s_col, line, col);
                expect_fn_name = false;
            } else if (param_expect_name and !param_type_context) {
                try addToken(allocator, &tokens, .param, s_line, s_col, line, col);
                param_expect_name = false;
            } else if (param_type_context or return_type_context) {
                const kind: TokenType = if (isBuiltinType(word)) .type else .type;
                try addToken(allocator, &tokens, kind, s_line, s_col, line, col);
            } else if (expect_var_decl) {
                try addToken(allocator, &tokens, .variable_decl, s_line, s_col, line, col);
                expect_var_decl = false;
            } else {
                var kind: TokenType = .variable;
                if (peekNonWhitespace(source, i) == '(') {
                    kind = .function;
                }
                if (isBuiltinType(word)) kind = .type;
                try addToken(allocator, &tokens, kind, s_line, s_col, line, col);
            }
            continue;
        }

        if (!std.ascii.isWhitespace(c) and expect_fn_name) {
            expect_fn_name = false;
        }

        if (c == '(' and fn_sig) {
            fn_paren_depth += 1;
            param_expect_name = true;
            param_type_context = false;
        } else if (c == ')' and fn_sig and fn_paren_depth > 0) {
            fn_paren_depth -= 1;
            param_expect_name = false;
            param_type_context = false;
            if (fn_paren_depth == 0) {
                fn_sig = false;
                return_type_context = false;
            }
        } else if (c == ',' and fn_sig and fn_paren_depth > 0) {
            param_expect_name = true;
            param_type_context = false;
        } else if (c == ':' and fn_sig and fn_paren_depth > 0) {
            param_type_context = true;
        } else if (c == '-' and i + 1 < source.len and source[i + 1] == '>') {
            return_type_context = true;
        } else if (c == '{' and return_type_context) {
            return_type_context = false;
        }

        i += 1;
        col += 1;
    }

    return tokens.toOwnedSlice(allocator);
}
