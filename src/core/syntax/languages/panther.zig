//! Panther tokenizer for syntax highlighting.

const std = @import("std");
const types = @import("../types.zig");

const Token = types.Token;
const TokenType = types.TokenType;

pub const language = types.Language{
    .name = "panther",
    .extensions = &.{".panther"},
    .tokenize = tokenize,
};

const Container = enum {
    none,
    @"struct",
    @"enum",
    @"error",
};

const keywords = [_][]const u8{
    "var",   "const", "struct", "enum",  "error", "fn",       "return", "if",     "else", "for", "while",
    "match", "defer", "try",    "catch", "break", "continue", "pub",    "import", "in",
};

const special_keywords = [_][]const u8{
    "true", "false", "null", "_",
};

const builtin_types = [_][]const u8{
    "bool",    "byte", "char", "string", "void", "isize", "usize",
    "i8",      "i16",  "i32",  "i64",    "i128", "i256",  "u8",
    "u16",     "u32",  "u64",  "u128",   "u256", "f32",   "f64",
    "numeric",
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
    var col: u32 = 0; // byte offset in line

    var expect_fn_name = false;
    var expect_var_decl = false;
    var expect_type_decl = false;
    var fn_sig = false;
    var fn_paren_depth: u32 = 0;
    var param_expect_name = false;
    var param_type_context = false;
    var return_type_context = false;
    var return_type_pending = false;

    var pending_container: ?Container = null;
    var container_stack: [64]Container = undefined;
    var container_depth: usize = 0;

    var struct_type_context = false;
    var struct_value_context = false;

    while (i < source.len) {
        const c = source[i];

        if (pending_container != null and !std.ascii.isWhitespace(c) and c != '/' and c != '{') {
            pending_container = null;
        }

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

        // Block comment (supports nesting)
        if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
            const s_line = line;
            const s_col = col;
            var depth: u32 = 1;
            i += 2;
            col += 2;
            while (i < source.len and depth > 0) {
                if (source[i] == '\n') {
                    line += 1;
                    col = 0;
                    i += 1;
                    continue;
                }
                if (i + 1 < source.len and source[i] == '/' and source[i + 1] == '*') {
                    depth += 1;
                    i += 2;
                    col += 2;
                    continue;
                }
                if (i + 1 < source.len and source[i] == '*' and source[i + 1] == '/') {
                    depth -= 1;
                    i += 2;
                    col += 2;
                    continue;
                }
                i += 1;
                col += 1;
            }
            try addToken(allocator, &tokens, .comment, s_line, s_col, line, col);
            continue;
        }

        // String and character literals
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
            const kind: TokenType = if (struct_value_context) .field_value else .string;
            try addToken(allocator, &tokens, kind, s_line, s_col, line, col);
            expect_fn_name = false;
            expect_var_decl = false;
            expect_type_decl = false;
            continue;
        }

        // Optional/error union markers
        if (c == '?' or c == '!') {
            const s_line = line;
            const s_col = col;
            i += 1;
            col += 1;
            try addToken(allocator, &tokens, .special, s_line, s_col, line, col);
            continue;
        }

        // Numbers (supports suffixes like 10i32, 3.14f32)
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
                    const kind: TokenType = if (struct_value_context) .field_value else .number;
                    try addToken(allocator, &tokens, kind, s_line, s_col, line, col);
                    expect_fn_name = false;
                    expect_var_decl = false;
                    expect_type_decl = false;
                    continue;
                }
            }
            while (i < source.len) {
                const d = source[i];
                if (isDigit(d) or d == '_' or d == '.' or d == 'e' or d == 'E' or d == 'p' or d == 'P' or d == '+' or d == '-') {
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
            const kind: TokenType = if (struct_value_context) .field_value else .number;
            try addToken(allocator, &tokens, kind, s_line, s_col, line, col);
            expect_fn_name = false;
            expect_var_decl = false;
            expect_type_decl = false;
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
                if (std.mem.eql(u8, word, "fn")) {
                    expect_fn_name = true;
                    fn_sig = true;
                    fn_paren_depth = 0;
                    param_expect_name = false;
                    param_type_context = false;
                    return_type_context = false;
                    return_type_pending = false;
                } else if (std.mem.eql(u8, word, "const") or std.mem.eql(u8, word, "var")) {
                    expect_var_decl = true;
                } else if (std.mem.eql(u8, word, "struct")) {
                    pending_container = .@"struct";
                    expect_type_decl = true;
                } else if (std.mem.eql(u8, word, "enum")) {
                    pending_container = .@"enum";
                    expect_type_decl = true;
                } else if (std.mem.eql(u8, word, "error")) {
                    pending_container = .@"error";
                    expect_type_decl = true;
                }
            } else if (isSpecial(word)) {
                const kind: TokenType = if (struct_value_context) .field_value else .special;
                try addToken(allocator, &tokens, kind, s_line, s_col, line, col);
                expect_fn_name = false;
            } else if (expect_type_decl) {
                try addToken(allocator, &tokens, .type, s_line, s_col, line, col);
                expect_type_decl = false;
            } else if (expect_fn_name) {
                try addToken(allocator, &tokens, .function, s_line, s_col, line, col);
                expect_fn_name = false;
            } else if (param_expect_name or (fn_sig and fn_paren_depth > 0 and !param_type_context and (peekPrevNonWhitespace(source, start) == '(' or peekPrevNonWhitespace(source, start) == ','))) {
                try addToken(allocator, &tokens, .param, s_line, s_col, line, col);
                param_expect_name = false;
            } else if (param_type_context or struct_type_context or return_type_context) {
                if (isBuiltinType(word)) {
                    try addToken(allocator, &tokens, .type, s_line, s_col, line, col);
                } else {
                    try addToken(allocator, &tokens, .type, s_line, s_col, line, col);
                }
            } else if (struct_value_context) {
                try addToken(allocator, &tokens, .field_value, s_line, s_col, line, col);
            } else if (expect_var_decl) {
                try addToken(allocator, &tokens, .variable_decl, s_line, s_col, line, col);
                expect_var_decl = false;
            } else {
                var kind: TokenType = .variable;
                const container = if (container_depth > 0) container_stack[container_depth - 1] else .none;
                if (container == .@"struct") {
                    if (peekNonWhitespace(source, i) == ':') {
                        kind = .field;
                    }
                } else if (container == .@"enum" or container == .@"error") {
                    if (peekNonWhitespace(source, i)) |next_c| {
                        if (next_c == ',' or next_c == '}' or next_c == '=' or next_c == '(') {
                            kind = .enum_field;
                        }
                    }
                } else {
                    if (peekNonWhitespace(source, i) == '(') {
                        kind = .function;
                    }
                }
                try addToken(allocator, &tokens, kind, s_line, s_col, line, col);
                expect_fn_name = false;
            }
            continue;
        }

        // Non-ASCII identifier starts
        if (c >= 0x80) {
            const s_line = line;
            const s_col = col;
            var len: usize = @intCast(std.unicode.utf8ByteSequenceLength(c) catch 1);
            if (len > source.len - i) len = source.len - i;
            i += len;
            col += @intCast(len);

            // Advance through the rest of the identifier (non-ASCII bytes only).
            while (i < source.len and source[i] >= 0x80) {
                var clen: usize = @intCast(std.unicode.utf8ByteSequenceLength(source[i]) catch 1);
                if (clen > source.len - i) clen = source.len - i;
                i += clen;
                col += @intCast(clen);
            }

            const kind: TokenType = if (struct_value_context) .field_value else .variable;
            try addToken(allocator, &tokens, kind, s_line, s_col, line, col);
            expect_fn_name = false;
            expect_var_decl = false;
            expect_type_decl = false;
            continue;
        }

        // Whitespace or punctuation
        if (!std.ascii.isWhitespace(c) and expect_fn_name) {
            expect_fn_name = false;
        }

        if (c == '(' and fn_sig) {
            fn_paren_depth += 1;
            param_expect_name = true;
        } else if (c == ')' and fn_sig and fn_paren_depth > 0) {
            fn_paren_depth -= 1;
            param_expect_name = false;
            param_type_context = false;
            if (fn_paren_depth == 0) {
                return_type_pending = true;
                return_type_context = false;
            }
        } else if (c == ',' and fn_sig and fn_paren_depth > 0) {
            param_expect_name = true;
            param_type_context = false;
        } else if (c == ':' and fn_sig and fn_paren_depth > 0) {
            param_type_context = true;
            param_expect_name = false;
        } else if (c == ':' and fn_sig and fn_paren_depth == 0 and return_type_pending) {
            return_type_context = true;
            return_type_pending = false;
        } else if (c == ';' and fn_sig and fn_paren_depth == 0) {
            fn_sig = false;
            return_type_context = false;
            return_type_pending = false;
        }

        if (c == '{') {
            if (pending_container) |kind| {
                if (container_depth < container_stack.len) {
                    container_stack[container_depth] = kind;
                    container_depth += 1;
                }
                pending_container = null;
            } else {
                if (container_depth < container_stack.len) {
                    container_stack[container_depth] = .none;
                    container_depth += 1;
                }
            }
            if (fn_sig and fn_paren_depth == 0) {
                fn_sig = false;
            }
            return_type_context = false;
            return_type_pending = false;
        } else if (c == '}') {
            if (container_depth > 0) container_depth -= 1;
            struct_type_context = false;
            struct_value_context = false;
        }

        const current_container = if (container_depth > 0) container_stack[container_depth - 1] else .none;
        if (current_container == .@"struct") {
            if (c == ':') {
                struct_type_context = true;
                struct_value_context = false;
            } else if (c == '=') {
                struct_type_context = false;
                struct_value_context = true;
            } else if (c == ',' or c == ';' or c == '\n') {
                struct_type_context = false;
                struct_value_context = false;
            }
        } else {
            struct_type_context = false;
            struct_value_context = false;
        }

        i += 1;
        col += 1;
    }

    return tokens.toOwnedSlice(allocator);
}
