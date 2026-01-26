//! Tree-sitter syntax highlighting
//!
//! This module will handle syntax highlighting using tree-sitter:
//! - Parsing source code
//! - Incremental parsing for edits
//! - Syntax node queries
//! - Highlight capture groups

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Syntax highlight type
pub const HighlightType = enum {
    keyword,
    @"type",
    function,
    variable,
    string,
    number,
    comment,
    operator,
    punctuation,
    constant,
    attribute,
    label,
    namespace,
    property,
    parameter,
    none,
};

/// A highlighted range in the source code
pub const HighlightRange = struct {
    start_byte: usize,
    end_byte: usize,
    start_line: u32,
    start_column: u32,
    end_line: u32,
    end_column: u32,
    highlight_type: HighlightType,
};

/// Syntax highlighter for a specific language
pub const Highlighter = struct {
    allocator: Allocator,
    language: []const u8,
    // TODO: Add tree-sitter parser and query

    pub fn init(allocator: Allocator, language: []const u8) Highlighter {
        return .{
            .allocator = allocator,
            .language = language,
        };
    }

    pub fn deinit(self: *Highlighter) void {
        _ = self;
    }

    /// Parse source code and return highlight ranges
    pub fn highlight(self: *Highlighter, source: []const u8) ![]HighlightRange {
        // TODO: Implement tree-sitter parsing and highlighting
        _ = self;
        _ = source;
        return &[_]HighlightRange{};
    }

    /// Update highlights after an edit
    pub fn updateHighlights(
        self: *Highlighter,
        source: []const u8,
        start_byte: usize,
        old_end_byte: usize,
        new_end_byte: usize,
    ) ![]HighlightRange {
        // TODO: Implement incremental parsing
        _ = self;
        _ = source;
        _ = start_byte;
        _ = old_end_byte;
        _ = new_end_byte;
        return &[_]HighlightRange{};
    }
};

/// Get the language for a file extension
pub fn languageForExtension(ext: []const u8) ?[]const u8 {
    const languages = std.StaticStringMap([]const u8).initComptime(.{
        .{ ".zig", "zig" },
        .{ ".c", "c" },
        .{ ".h", "c" },
        .{ ".cpp", "cpp" },
        .{ ".hpp", "cpp" },
        .{ ".cc", "cpp" },
        .{ ".rs", "rust" },
        .{ ".go", "go" },
        .{ ".py", "python" },
        .{ ".js", "javascript" },
        .{ ".ts", "typescript" },
        .{ ".json", "json" },
        .{ ".toml", "toml" },
        .{ ".yaml", "yaml" },
        .{ ".yml", "yaml" },
        .{ ".md", "markdown" },
        .{ ".html", "html" },
        .{ ".css", "css" },
        .{ ".sh", "bash" },
        .{ ".bash", "bash" },
        .{ ".lua", "lua" },
    });

    return languages.get(ext);
}
