const std = @import("std");

pub fn iconForName(name: []const u8, is_dir: bool, use_nerd: bool) []const u8 {
    if (!use_nerd) return "";
    if (is_dir) return "\u{f07b}";

    const ext = std.fs.path.extension(name);
    if (ext.len == 0) return "\u{f15b}";

    return iconForExtension(ext);
}

fn iconForExtension(ext: []const u8) []const u8 {
    if (std.mem.eql(u8, ext, ".zig")) return "\u{e6a9}";
    if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h")) return "\u{e61e}";
    if (std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".hpp") or std.mem.eql(u8, ext, ".cc")) return "\u{e61d}";
    if (std.mem.eql(u8, ext, ".rs")) return "\u{e7a8}";
    if (std.mem.eql(u8, ext, ".go")) return "\u{e626}";
    if (std.mem.eql(u8, ext, ".py")) return "\u{e73c}";
    if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".mjs")) return "\u{e74e}";
    if (std.mem.eql(u8, ext, ".ts")) return "\u{e628}";
    if (std.mem.eql(u8, ext, ".json")) return "\u{e60b}";
    if (std.mem.eql(u8, ext, ".toml") or std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) return "\u{e615}";
    if (std.mem.eql(u8, ext, ".md")) return "\u{e73e}";
    if (std.mem.eql(u8, ext, ".html")) return "\u{e736}";
    if (std.mem.eql(u8, ext, ".css")) return "\u{e749}";
    if (std.mem.eql(u8, ext, ".sh") or std.mem.eql(u8, ext, ".bash")) return "\u{e795}";
    if (std.mem.eql(u8, ext, ".lua")) return "\u{e620}";
    if (std.mem.eql(u8, ext, ".java")) return "\u{e738}";
    if (std.mem.eql(u8, ext, ".kt")) return "\u{e634}";
    if (std.mem.eql(u8, ext, ".swift")) return "\u{e755}";
    if (std.mem.eql(u8, ext, ".rb")) return "\u{e791}";
    if (std.mem.eql(u8, ext, ".php")) return "\u{e73d}";
    if (std.mem.eql(u8, ext, ".cs")) return "\u{e648}";
    if (std.mem.eql(u8, ext, ".dart")) return "\u{e798}";
    if (std.mem.eql(u8, ext, ".scala")) return "\u{e737}";

    // --- Build / config ---
    if (std.mem.eql(u8, ext, ".lock")) return "\u{f023}";
    if (std.mem.eql(u8, ext, ".env")) return "\u{f462}";
    if (std.mem.eql(u8, ext, ".ini") or std.mem.eql(u8, ext, ".cfg")) return "\u{e615}";
    if (std.mem.eql(u8, ext, ".makefile")) return "\u{e673}";
    if (std.mem.eql(u8, ext, ".cmake")) return "\u{e673}";

    // --- Archives ---
    if (std.mem.eql(u8, ext, ".zip") or std.mem.eql(u8, ext, ".tar") or std.mem.eql(u8, ext, ".gz") or std.mem.eql(u8, ext, ".xz") or std.mem.eql(u8, ext, ".7z")) return "\u{f410}";

    // --- Media ---
    if (std.mem.eql(u8, ext, ".png") or std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg") or std.mem.eql(u8, ext, ".gif") or std.mem.eql(u8, ext, ".webp")) return "\u{f1c5}";

    if (std.mem.eql(u8, ext, ".mp3") or std.mem.eql(u8, ext, ".wav") or std.mem.eql(u8, ext, ".flac")) return "\u{f1c7}";

    if (std.mem.eql(u8, ext, ".mp4") or std.mem.eql(u8, ext, ".mkv") or std.mem.eql(u8, ext, ".webm")) return "\u{f1c8}";

    // --- Binaries ---
    if (std.mem.eql(u8, ext, ".exe") or std.mem.eql(u8, ext, ".bin") or std.mem.eql(u8, ext, ".app")) return "\u{f17a}";

    return "\u{f15b}"; // default file icon
}
