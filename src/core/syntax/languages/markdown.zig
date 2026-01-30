//! Markdown tokenizer for syntax highlighting.

const std = @import("std");
const types = @import("../types.zig");

const Token = types.Token;
const TokenType = types.TokenType;

pub const language = types.Language{
    .name = "markdown",
    .extensions = &.{ ".md", ".markdown" },
    .tokenize = tokenize,
};

fn addToken(allocator: std.mem.Allocator, list: *std.ArrayList(Token), kind: TokenType, s_line: u32, s_col: u32, e_line: u32, e_col: u32) !void {
    if (s_line == e_line and s_col == e_col) return;
    try list.append(allocator, .{ .start_line = s_line, .start_col = s_col, .end_line = e_line, .end_col = e_col, .kind = kind });
}

fn isLineStart(source: []const u8, idx: usize) bool {
    if (idx == 0) return true;
    return source[idx - 1] == '\n';
}

fn skipSpaces(source: []const u8, idx: usize) usize {
    var i = idx;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
    return i;
}

pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) ![]Token {
    var tokens = std.ArrayList(Token).empty;
    errdefer tokens.deinit(allocator);

    var i: usize = 0;
    var line: u32 = 0;
    var col: u32 = 0;
    var in_fence = false;
    var fence_char: u8 = 0;

    while (i < source.len) {
        const c = source[i];

        if (c == '\n') {
            line += 1;
            col = 0;
            i += 1;
            continue;
        }

        if (isLineStart(source, i)) {
            const s_col = col;
            var j = skipSpaces(source, i);
            const j_col: u32 = col + @as(u32, @intCast(j - i));

            // Fenced code block (``` or ~~~)
            if (j + 2 < source.len and (source[j] == '`' or source[j] == '~') and source[j + 1] == source[j] and source[j + 2] == source[j]) {
                const fence = source[j];
                if (!in_fence) {
                    in_fence = true;
                    fence_char = fence;
                } else if (fence_char == fence) {
                    in_fence = false;
                }
                while (j < source.len and source[j] != '\n') : (j += 1) {}
                const end_col: u32 = col + @as(u32, @intCast(j - i));
                try addToken(allocator, &tokens, .special, line, s_col, line, end_col);
                i = j;
                col = end_col;
                continue;
            }

            if (in_fence) {
                while (j < source.len and source[j] != '\n') : (j += 1) {}
                const end_col: u32 = col + @as(u32, @intCast(j - i));
                try addToken(allocator, &tokens, .string, line, s_col, line, end_col);
                i = j;
                col = end_col;
                continue;
            }

            // Headings
            if (j < source.len and source[j] == '#') {
                var k = j;
                var count: u32 = 0;
                while (k < source.len and source[k] == '#') : (k += 1) {
                    count += 1;
                }
                if (count > 0 and count <= 6 and k < source.len and source[k] == ' ') {
                    while (k < source.len and source[k] != '\n') : (k += 1) {}
                    const end_col: u32 = j_col + @as(u32, @intCast(k - j));
                    try addToken(allocator, &tokens, .keyword, line, j_col, line, end_col);
                    i = k;
                    col = end_col;
                    continue;
                }
            }

            // Blockquote
            if (j < source.len and source[j] == '>') {
                try addToken(allocator, &tokens, .special, line, j_col, line, j_col + 1);
            }

            // List markers
            if (j < source.len) {
                if (source[j] == '-' or source[j] == '*' or source[j] == '+') {
                    if (j + 1 < source.len and source[j + 1] == ' ') {
                        try addToken(allocator, &tokens, .special, line, j_col, line, j_col + 1);
                    }
                } else if (std.ascii.isDigit(source[j])) {
                    var k = j;
                    while (k < source.len and std.ascii.isDigit(source[k])) : (k += 1) {}
                    if (k < source.len and source[k] == '.' and k + 1 < source.len and source[k + 1] == ' ') {
                        const end_col: u32 = j_col + @as(u32, @intCast(k - j + 1));
                        try addToken(allocator, &tokens, .special, line, j_col, line, end_col);
                    }
                }
            }
        }

        if (in_fence) {
            i += 1;
            col += 1;
            continue;
        }

        // Inline code
        if (c == '`') {
            const s_line = line;
            const s_col = col;
            i += 1;
            col += 1;
            while (i < source.len and source[i] != '`' and source[i] != '\n') {
                i += 1;
                col += 1;
            }
            if (i < source.len and source[i] == '`') {
                i += 1;
                col += 1;
            }
            try addToken(allocator, &tokens, .string, s_line, s_col, line, col);
            continue;
        }

        // Emphasis markers
        if (c == '*' or c == '_') {
            const s_line = line;
            const s_col = col;
            const marker = c;
            var count: u32 = 1;
            if (i + 1 < source.len and source[i + 1] == marker) {
                count = 2;
            }
            i += count;
            col += count;
            while (i < source.len) {
                if (source[i] == '\n') break;
                if (source[i] == marker) {
                    if (count == 2 and i + 1 < source.len and source[i + 1] == marker) {
                        i += 2;
                        col += 2;
                        break;
                    }
                    if (count == 1) {
                        i += 1;
                        col += 1;
                        break;
                    }
                }
                i += 1;
                col += 1;
            }
            try addToken(allocator, &tokens, .special, s_line, s_col, line, col);
            continue;
        }

        // Links [text](url)
        if (c == '[') {
            const s_line = line;
            const s_col = col;
            i += 1;
            col += 1;
            while (i < source.len and source[i] != ']' and source[i] != '\n') {
                i += 1;
                col += 1;
            }
            if (i < source.len and source[i] == ']') {
                i += 1;
                col += 1;
                if (i < source.len and source[i] == '(') {
                    while (i < source.len and source[i] != ')' and source[i] != '\n') {
                        i += 1;
                        col += 1;
                    }
                    if (i < source.len and source[i] == ')') {
                        i += 1;
                        col += 1;
                    }
                }
            }
            try addToken(allocator, &tokens, .string, s_line, s_col, line, col);
            continue;
        }

        i += 1;
        col += 1;
    }

    return tokens.toOwnedSlice(allocator);
}
