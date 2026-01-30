//! Shell script tokenizer for syntax highlighting.

const std = @import("std");
const types = @import("../types.zig");

const Token = types.Token;
const TokenType = types.TokenType;

pub const language = types.Language{
    .name = "shell",
    .extensions = &.{ ".sh", ".bash", ".zsh" },
    .tokenize = tokenize,
};

const keywords = [_][]const u8{
    "if",   "then", "else",     "elif",   "fi",   "for",    "in",   "do", "done", "while", "until",
    "case", "esac", "function", "select", "time", "coproc", "echo",
};

const special_keywords = [_][]const u8{
    "true", "false",
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

fn isAsciiIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
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

pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) ![]Token {
    var tokens = std.ArrayList(Token).empty;
    errdefer tokens.deinit(allocator);

    var i: usize = 0;
    var line: u32 = 0;
    var col: u32 = 0;

    while (i < source.len) {
        const c = source[i];

        if (c == '\n') {
            line += 1;
            col = 0;
            i += 1;
            continue;
        }

        // Comment
        if (c == '#') {
            const s_line = line;
            const s_col = col;
            i += 1;
            col += 1;
            while (i < source.len and source[i] != '\n') {
                i += 1;
                col += 1;
            }
            try addToken(allocator, &tokens, .comment, s_line, s_col, line, col);
            continue;
        }

        // Strings
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
            continue;
        }

        // Variables $VAR or ${VAR}
        if (c == '$') {
            const s_line = line;
            const s_col = col;
            i += 1;
            col += 1;
            if (i < source.len and source[i] == '{') {
                i += 1;
                col += 1;
                while (i < source.len and source[i] != '}' and source[i] != '\n') {
                    i += 1;
                    col += 1;
                }
                if (i < source.len and source[i] == '}') {
                    i += 1;
                    col += 1;
                }
            } else {
                while (i < source.len and isAsciiIdentContinue(source[i])) {
                    i += 1;
                    col += 1;
                }
            }
            try addToken(allocator, &tokens, .variable, s_line, s_col, line, col);
            continue;
        }

        // Numbers
        if (isDigit(c)) {
            const s_line = line;
            const s_col = col;
            i += 1;
            col += 1;
            while (i < source.len and isDigit(source[i])) {
                i += 1;
                col += 1;
            }
            try addToken(allocator, &tokens, .number, s_line, s_col, line, col);
            continue;
        }

        // Identifiers / keywords
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
            } else if (isSpecial(word)) {
                try addToken(allocator, &tokens, .special, s_line, s_col, line, col);
            } else {
                try addToken(allocator, &tokens, .variable, s_line, s_col, line, col);
            }
            continue;
        }

        i += 1;
        col += 1;
    }

    return tokens.toOwnedSlice(allocator);
}
