//! YAML tokenizer for syntax highlighting.

const std = @import("std");
const types = @import("../types.zig");

const Token = types.Token;
const TokenType = types.TokenType;

pub const language = types.Language{
    .name = "yaml",
    .extensions = &.{ ".yaml", ".yml" },
    .tokenize = tokenize,
};

const special_keywords = [_][]const u8{
    "true", "false", "null", "yes", "no", "on", "off",
};

fn isSpecial(word: []const u8) bool {
    for (special_keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
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

        // Numbers
        if (isDigit(c) or (c == '-' and i + 1 < source.len and isDigit(source[i + 1]))) {
            const s_line = line;
            const s_col = col;
            i += 1;
            col += 1;
            while (i < source.len) {
                const d = source[i];
                if (isDigit(d) or d == '.' or d == 'e' or d == 'E' or d == '+' or d == '-') {
                    i += 1;
                    col += 1;
                    continue;
                }
                break;
            }
            try addToken(allocator, &tokens, .number, s_line, s_col, line, col);
            continue;
        }

        // Literals
        if (std.ascii.isAlphabetic(c)) {
            const s_line = line;
            const s_col = col;
            const start = i;
            i += 1;
            col += 1;
            while (i < source.len and (std.ascii.isAlphabetic(source[i]) or source[i] == '_')) {
                i += 1;
                col += 1;
            }
            const word = source[start..i];
            if (isSpecial(word)) {
                try addToken(allocator, &tokens, .special, s_line, s_col, line, col);
            }
            continue;
        }

        // Keys (simple heuristic: word followed by :)
        if (c == ':') {
            if (i > 0 and source[i - 1] != ' ') {
                const s_line = line;
                const s_col = col;
                try addToken(allocator, &tokens, .special, s_line, s_col, line, s_col + 1);
            }
        }

        i += 1;
        col += 1;
    }

    return tokens.toOwnedSlice(allocator);
}
