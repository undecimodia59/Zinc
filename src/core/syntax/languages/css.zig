//! CSS tokenizer for syntax highlighting.

const std = @import("std");
const types = @import("../types.zig");

const Token = types.Token;
const TokenType = types.TokenType;

pub const language = types.Language{
    .name = "css",
    .extensions = &.{ ".css", ".scss", ".sass" },
    .tokenize = tokenize,
};

const keywords = [_][]const u8{
    "import", "media", "supports", "keyframes", "font-face", "namespace",
};

fn isKeyword(word: []const u8) bool {
    for (keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn peekNonWhitespace(source: []const u8, start: usize) ?u8 {
    var idx = start;
    while (idx < source.len) : (idx += 1) {
        const c = source[idx];
        if (!std.ascii.isWhitespace(c)) return c;
    }
    return null;
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isHexColor(word: []const u8) bool {
    if (!(word.len == 3 or word.len == 4 or word.len == 6 or word.len == 8)) return false;
    for (word) |c| {
        if (!isHexDigit(c)) return false;
    }
    return true;
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
    var in_selector = true;

    while (i < source.len) {
        const c = source[i];

        if (c == '\n') {
            line += 1;
            col = 0;
            i += 1;
            continue;
        }

        // Comments
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

        if (c == '{') {
            in_selector = false;
        } else if (c == '}') {
            in_selector = true;
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
        if (isDigit(c)) {
            const s_line = line;
            const s_col = col;
            i += 1;
            col += 1;
            while (i < source.len) {
                const d = source[i];
                if (isDigit(d) or d == '.' or d == '%' or d == '-' or std.ascii.isAlphabetic(d)) {
                    i += 1;
                    col += 1;
                    continue;
                }
                break;
            }
            try addToken(allocator, &tokens, .number, s_line, s_col, line, col);
            continue;
        }

        // Identifiers and at-rules / selectors
        if (std.ascii.isAlphabetic(c) or c == '@' or c == '-' or c == '#' or c == '.') {
            const s_line = line;
            const s_col = col;
            const start = i;
            i += 1;
            col += 1;
            while (i < source.len and (std.ascii.isAlphabetic(source[i]) or std.ascii.isDigit(source[i]) or source[i] == '-' or source[i] == '_' or source[i] == '#')) {
                i += 1;
                col += 1;
            }
            const word = source[start..i];
            if (word.len > 0 and word[0] == '@' and isKeyword(word[1..])) {
                try addToken(allocator, &tokens, .keyword, s_line, s_col, line, col);
            } else if (word.len > 0 and word[0] == '#') {
                if (isHexColor(word[1..])) {
                    try addToken(allocator, &tokens, .number, s_line, s_col, line, col);
                } else {
                    try addToken(allocator, &tokens, .special, s_line, s_col, line, col);
                }
            } else if (word.len > 0 and word[0] == '.') {
                try addToken(allocator, &tokens, .keyword, s_line, s_col, line, col);
            } else if (in_selector) {
                try addToken(allocator, &tokens, .type, s_line, s_col, line, col);
            } else {
                if (peekNonWhitespace(source, i)) |next_c| {
                    if (next_c == ':') {
                        try addToken(allocator, &tokens, .field, s_line, s_col, line, col);
                    } else {
                        try addToken(allocator, &tokens, .variable, s_line, s_col, line, col);
                    }
                } else {
                    try addToken(allocator, &tokens, .variable, s_line, s_col, line, col);
                }
            }
            continue;
        }

        i += 1;
        col += 1;
    }

    return tokens.toOwnedSlice(allocator);
}
