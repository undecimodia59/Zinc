//! Smali tokenizer for syntax highlighting.

const std = @import("std");
const types = @import("../types.zig");

const Token = types.Token;
const TokenType = types.TokenType;

pub const language = types.Language{
    .name = "smali",
    .extensions = &.{ ".smali" },
    .tokenize = tokenize,
};

const directives = [_][]const u8{
    ".class", ".super", ".source", ".method", ".end", ".field", ".annotation", ".subannotation",
    ".param", ".locals", ".registers", ".line", ".prologue", ".epilogue", ".implements", ".catch",
    ".catchall", ".packed-switch", ".sparse-switch", ".array-data", ".restart", ".local", ".endlocal",
};

const opcodes = [_][]const u8{
    "nop", "move", "move/from16", "move/16", "move-wide", "move-wide/from16", "move-wide/16",
    "move-object", "move-object/from16", "move-object/16", "move-result", "move-result-wide",
    "move-result-object", "move-exception", "return-void", "return", "return-wide", "return-object",
    "const/4", "const/16", "const", "const/high16", "const-wide/16", "const-wide/32", "const-wide",
    "const-wide/high16", "const-string", "const-string/jumbo", "const-class", "monitor-enter",
    "monitor-exit", "check-cast", "instance-of", "array-length", "new-instance", "new-array",
    "filled-new-array", "filled-new-array/range", "fill-array-data", "throw", "goto", "goto/16",
    "goto/32", "packed-switch", "sparse-switch", "cmpl-float", "cmpg-float", "cmpl-double",
    "cmpg-double", "cmp-long", "if-eq", "if-ne", "if-lt", "if-ge", "if-gt", "if-le",
    "if-eqz", "if-nez", "if-ltz", "if-gez", "if-gtz", "if-lez", "aget", "aget-wide",
    "aget-object", "aget-boolean", "aget-byte", "aget-char", "aget-short", "aput", "aput-wide",
    "aput-object", "aput-boolean", "aput-byte", "aput-char", "aput-short", "iget", "iget-wide",
    "iget-object", "iget-boolean", "iget-byte", "iget-char", "iget-short", "iput", "iput-wide",
    "iput-object", "iput-boolean", "iput-byte", "iput-char", "iput-short", "sget", "sget-wide",
    "sget-object", "sget-boolean", "sget-byte", "sget-char", "sget-short", "sput", "sput-wide",
    "sput-object", "sput-boolean", "sput-byte", "sput-char", "sput-short", "invoke-virtual",
    "invoke-super", "invoke-direct", "invoke-static", "invoke-interface", "invoke-virtual/range",
    "invoke-super/range", "invoke-direct/range", "invoke-static/range", "invoke-interface/range",
    "add-int", "sub-int", "mul-int", "div-int", "rem-int", "and-int", "or-int", "xor-int",
    "shl-int", "shr-int", "ushr-int", "add-long", "sub-long", "mul-long", "div-long", "rem-long",
    "and-long", "or-long", "xor-long", "shl-long", "shr-long", "ushr-long", "add-float",
    "sub-float", "mul-float", "div-float", "rem-float", "add-double", "sub-double", "mul-double",
    "div-double", "rem-double", "neg-int", "neg-long", "neg-float", "neg-double", "not-int",
    "not-long", "int-to-long", "int-to-float", "int-to-double", "long-to-int", "long-to-float",
    "long-to-double", "float-to-int", "float-to-long", "float-to-double", "double-to-int",
    "double-to-long", "double-to-float", "int-to-byte", "int-to-char", "int-to-short",
};

const special_keywords = [_][]const u8{
    "true", "false", "null",
};

fn isDirective(word: []const u8) bool {
    for (directives) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

fn isOpcode(word: []const u8) bool {
    for (opcodes) |kw| {
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

        // Line comment
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
        if (c == '"') {
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
                if (ch == '"') {
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

        // Numbers (including negative and hex)
        if (isDigit(c) or (c == '-' and i + 1 < source.len and isDigit(source[i + 1]))) {
            const s_line = line;
            const s_col = col;
            if (c == '-') {
                i += 1;
                col += 1;
            }
            if (i < source.len and source[i] == '0' and i + 1 < source.len and (source[i + 1] == 'x' or source[i + 1] == 'X')) {
                i += 2;
                col += 2;
                while (i < source.len) {
                    const d = source[i];
                    if (isHexDigit(d)) {
                        i += 1;
                        col += 1;
                        continue;
                    }
                    break;
                }
            } else {
                while (i < source.len) {
                    const d = source[i];
                    if (isDigit(d) or d == '.' or d == 'e' or d == 'E' or d == '+' or d == '-') {
                        i += 1;
                        col += 1;
                        continue;
                    }
                    break;
                }
            }
            try addToken(allocator, &tokens, .number, s_line, s_col, line, col);
            continue;
        }

        // Type descriptors (L...; or array types)
        if (c == 'L' or c == '[') {
            const s_line = line;
            const s_col = col;
            const start = i;
            var idx = i;
            var saw_type = false;
            while (idx < source.len and source[idx] == '[') : (idx += 1) {}
            if (idx < source.len) {
                const t = source[idx];
                if (t == 'L') {
                    idx += 1;
                    while (idx < source.len and source[idx] != ';' and source[idx] != '\n' and !std.ascii.isWhitespace(source[idx])) {
                        idx += 1;
                    }
                    if (idx < source.len and source[idx] == ';') {
                        idx += 1;
                        saw_type = true;
                    }
                } else if (t == 'Z' or t == 'B' or t == 'S' or t == 'C' or t == 'I' or t == 'J' or t == 'F' or t == 'D' or t == 'V') {
                    idx += 1;
                    saw_type = true;
                }
            }
            if (saw_type) {
                i = idx;
                col += @intCast(idx - start);
                try addToken(allocator, &tokens, .type, s_line, s_col, line, col);
                continue;
            }
        }

        // Directives
        if (c == '.' and i + 1 < source.len and isAsciiIdentStart(source[i + 1])) {
            const s_line = line;
            const s_col = col;
            const start = i;
            i += 1;
            col += 1;
            while (i < source.len) {
                const ch = source[i];
                if (isAsciiIdentContinue(ch) or ch == '-' or ch == '_') {
                    i += 1;
                    col += 1;
                    continue;
                }
                break;
            }
            const word = source[start..i];
            if (isDirective(word)) {
                try addToken(allocator, &tokens, .keyword, s_line, s_col, line, col);
            } else {
                try addToken(allocator, &tokens, .keyword, s_line, s_col, line, col);
            }
            continue;
        }

        // Labels
        if (c == ':') {
            const s_line = line;
            const s_col = col;
            i += 1;
            col += 1;
            while (i < source.len and !std.ascii.isWhitespace(source[i])) {
                i += 1;
                col += 1;
            }
            try addToken(allocator, &tokens, .field, s_line, s_col, line, col);
            continue;
        }

        // Registers (v0, p1, v0..v3)
        if ((c == 'v' or c == 'p') and i + 1 < source.len and isDigit(source[i + 1])) {
            const s_line = line;
            const s_col = col;
            i += 1;
            col += 1;
            while (i < source.len) {
                const ch = source[i];
                if (isDigit(ch) or ch == '.') {
                    i += 1;
                    col += 1;
                    continue;
                }
                break;
            }
            try addToken(allocator, &tokens, .variable, s_line, s_col, line, col);
            continue;
        }

        // Opcodes and identifiers
        if (isAsciiIdentStart(c)) {
            const s_line = line;
            const s_col = col;
            const start = i;
            i += 1;
            col += 1;
            while (i < source.len) {
                const ch = source[i];
                if (isAsciiIdentContinue(ch) or ch == '-' or ch == '/' or ch == '$') {
                    i += 1;
                    col += 1;
                    continue;
                }
                break;
            }
            const word = source[start..i];
            if (isOpcode(word)) {
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
