//! HTML tokenizer for syntax highlighting.

const std = @import("std");
const types = @import("../types.zig");

const Token = types.Token;
const TokenType = types.TokenType;

pub const language = types.Language{
    .name = "html",
    .extensions = &.{ ".html", ".htm" },
    .tokenize = tokenize,
};

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

        // Comments <!-- -->
        if (c == '<' and i + 3 < source.len and source[i + 1] == '!' and source[i + 2] == '-' and source[i + 3] == '-') {
            const s_line = line;
            const s_col = col;
            i += 4;
            col += 4;
            while (i + 2 < source.len) {
                if (source[i] == '-' and source[i + 1] == '-' and source[i + 2] == '>') {
                    i += 3;
                    col += 3;
                    break;
                }
                if (source[i] == '\n') {
                    line += 1;
                    col = 0;
                    i += 1;
                    continue;
                }
                i += 1;
                col += 1;
            }
            try addToken(allocator, &tokens, .comment, s_line, s_col, line, col);
            continue;
        }

        // Tags
        if (c == '<') {
            const s_line = line;
            const s_col = col;
            i += 1;
            col += 1;
            // Tag name
            while (i < source.len and std.ascii.isWhitespace(source[i])) {
                i += 1;
                col += 1;
            }
            while (i < source.len and (std.ascii.isAlphabetic(source[i]) or source[i] == '/' or source[i] == '!')) {
                i += 1;
                col += 1;
            }
            try addToken(allocator, &tokens, .keyword, s_line, s_col, line, col);
            // Attributes and strings
            while (i < source.len and source[i] != '>') {
                const ch = source[i];
                if (ch == '"' or ch == '\'') {
                    const quote = ch;
                    const str_line = line;
                    const str_col = col;
                    i += 1;
                    col += 1;
                    while (i < source.len) {
                        const sc = source[i];
                        if (sc == quote) {
                            i += 1;
                            col += 1;
                            break;
                        }
                        if (sc == '\n') {
                            line += 1;
                            col = 0;
                            i += 1;
                            continue;
                        }
                        i += 1;
                        col += 1;
                    }
                    try addToken(allocator, &tokens, .string, str_line, str_col, line, col);
                    continue;
                }
                i += 1;
                col += 1;
            }
            if (i < source.len and source[i] == '>') {
                i += 1;
                col += 1;
            }
            continue;
        }

        i += 1;
        col += 1;
    }

    return tokens.toOwnedSlice(allocator);
}
