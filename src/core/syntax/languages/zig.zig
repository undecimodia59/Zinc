//! Zig tokenizer for syntax highlighting.

const std = @import("std");
const types = @import("../types.zig");

const Token = types.Token;
const TokenType = types.TokenType;

pub const language = types.Language{
    .name = "zig",
    .extensions = &.{ ".zig" },
    .tokenize = tokenize,
};

const keywords = [_][]const u8{
    "align", "allowzero", "and", "anyframe", "anytype", "asm", "async", "await",
    "break", "catch", "comptime", "const", "continue", "defer", "else", "enum",
    "errdefer", "error", "export", "extern", "for", "if", "inline", "linksection",
    "noalias", "noinline", "nosuspend", "opaque", "or", "orelse", "packed",
    "pub", "resume", "return", "struct", "suspend", "switch", "test", "threadlocal",
    "try", "union", "unreachable", "usingnamespace", "var", "volatile", "while",
};

const builtin_types = [_][]const u8{
    "bool", "isize", "usize",
    "u8", "u16", "u32", "u64", "u128",
    "i8", "i16", "i32", "i64", "i128",
    "f16", "f32", "f64", "f80", "f128",
    "c_short", "c_ushort", "c_int", "c_uint", "c_long", "c_ulong", "c_longlong", "c_ulonglong",
    "c_longdouble", "c_void",
    "noreturn", "type", "anyopaque", "anyerror",
};

fn isKeyword(word: []const u8) bool {
    for (keywords) |kw| {
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

pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) ![]Token {
    var tokens = std.ArrayList(Token).empty;
    errdefer tokens.deinit(allocator);

    var i: usize = 0;
    var line: u32 = 0;
    var col: u32 = 0; // byte offset in line

    var expect_fn_name = false;

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
            try addToken(allocator, &tokens, .string, s_line, s_col, line, col);
            expect_fn_name = false;
            continue;
        }

        // Builtin functions (e.g. @import)
        if (c == '@' and i + 1 < source.len and isAsciiIdentStart(source[i + 1])) {
            const s_line = line;
            const s_col = col;
            i += 1;
            col += 1;
            while (i < source.len and isAsciiIdentContinue(source[i])) {
                i += 1;
                col += 1;
            }
            try addToken(allocator, &tokens, .function, s_line, s_col, line, col);
            expect_fn_name = false;
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
                    try addToken(allocator, &tokens, .number, s_line, s_col, line, col);
                    expect_fn_name = false;
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
            try addToken(allocator, &tokens, .number, s_line, s_col, line, col);
            expect_fn_name = false;
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
                expect_fn_name = std.mem.eql(u8, word, "fn");
            } else if (isBuiltinType(word)) {
                try addToken(allocator, &tokens, .@"type", s_line, s_col, line, col);
                expect_fn_name = false;
            } else if (expect_fn_name) {
                try addToken(allocator, &tokens, .function, s_line, s_col, line, col);
                expect_fn_name = false;
            } else {
                try addToken(allocator, &tokens, .variable, s_line, s_col, line, col);
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

            try addToken(allocator, &tokens, .variable, s_line, s_col, line, col);
            expect_fn_name = false;
            continue;
        }

        // Whitespace or punctuation
        if (!std.ascii.isWhitespace(c) and expect_fn_name) {
            expect_fn_name = false;
        }

        i += 1;
        col += 1;
    }

    return tokens.toOwnedSlice(allocator);
}
