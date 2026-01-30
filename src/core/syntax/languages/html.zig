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
    // 1. Initialize ArrayList with allocator (Standard Zig)
    var tokens: std.ArrayList(Token) = .{};
    errdefer tokens.deinit(allocator);

    var i: usize = 0;
    var line: u32 = 0;
    var col: u32 = 0;

    while (i < source.len) {
        const c = source[i];

        // Handle Newlines
        if (c == '\n') {
            line += 1;
            col = 0;
            i += 1;
            continue;
        }

        // ---------------------------------------------------------
        // BLOCK: Comments // ---------------------------------------------------------
        const is_comment_start = c == '<' and
            i + 3 < source.len and
            source[i + 1] == '!' and
            source[i + 2] == '-' and
            source[i + 3] == '-';

        if (is_comment_start) { // <--- OPENING BRACE 1
            const s_line = line;
            const s_col = col;
            i += 4;
            col += 4;

            // Loop until -->
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
        } // <--- CLOSING BRACE 1 (Matches is_comment_start)

        // ---------------------------------------------------------
        // BLOCK: Tags <...>
        // ---------------------------------------------------------
        if (c == '<') { // <--- OPENING BRACE 2
            i += 1;
            col += 1;

            // Skip optional '/' or '!'
            if (i < source.len and (source[i] == '/' or source[i] == '!')) {
                i += 1;
                col += 1;
            }

            // Tag name (highlight keyword)
            const name_line = line;
            const name_col = col;
            while (i < source.len) {
                const char = source[i];
                if (std.ascii.isWhitespace(char) or char == '>' or char == '/') break;
                i += 1;
                col += 1;
            }
            if (name_col != col) {
                try addToken(allocator, &tokens, .keyword, name_line, name_col, line, col);
            }

            // Loop: Tag Internals (Attributes)
            while (i < source.len and source[i] != '>') {
                const ch = source[i];

                if (std.ascii.isWhitespace(ch)) {
                    if (ch == '\n') {
                        line += 1;
                        col = 0;
                    } else {
                        col += 1;
                    }
                    i += 1;
                    continue;
                }

                if (ch == '=') {
                    i += 1;
                    col += 1;
                    continue;
                }

                // Strings (Attribute Values)
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

                // Attributes (Algorithm: anything not > / = or whitespace)
                const a_line = line;
                const a_col = col;
                while (i < source.len) {
                    const next_c = source[i];
                    if (std.ascii.isWhitespace(next_c) or next_c == '=' or next_c == '>' or next_c == '/') break;
                    i += 1;
                    col += 1;
                }
                // Only add token if we actually advanced
                if (col != a_col) {
                    try addToken(allocator, &tokens, .attribute, a_line, a_col, line, col);
                }
            }

            // Close Tag >
            if (i < source.len and source[i] == '>') {
                i += 1;
                col += 1;
            }
            continue;
        } // <--- CLOSING BRACE 2 (Matches c == '<')

        i += 1;
        col += 1;
    }

    return tokens.toOwnedSlice(allocator);
}
