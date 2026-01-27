//! Syntax highlighting data types.

const std = @import("std");

/// Token categories understood by the highlighter.
pub const TokenType = enum {
    comment,
    keyword,
    string,
    number,
    @"type",
    function,
    variable,
};

/// Highlighted span expressed as line + byte offsets.
///
/// Offsets are byte indices within the line (UTF-8 safe for gtk TextBuffer APIs).
pub const Token = struct {
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
    kind: TokenType,
};

/// Syntax tokenizer for a language.
///
/// The tokenizer returns a list of tokens covering spans in `source`.
pub const Tokenizer = *const fn (allocator: std.mem.Allocator, source: []const u8) anyerror![]Token;

/// Language metadata and tokenizer entry point.
pub const Language = struct {
    name: []const u8,
    extensions: []const []const u8,
    tokenize: Tokenizer,
};
