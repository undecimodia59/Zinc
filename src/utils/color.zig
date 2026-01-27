//! Color utility functions

/// Convert a 24-bit RGB color (0xRRGGBB) to normalized RGB floats [0.0, 1.0]
pub fn colorToRgb(color: u32) [3]f64 {
    const r: f64 = @as(f64, @floatFromInt((color >> 16) & 0xff)) / 255.0;
    const g: f64 = @as(f64, @floatFromInt((color >> 8) & 0xff)) / 255.0;
    const b: f64 = @as(f64, @floatFromInt(color & 0xff)) / 255.0;
    return .{ r, g, b };
}

/// Parse a hex color string (with or without #) to u32
/// Returns null if invalid
pub fn parseHexColor(value: []const u8) ?u32 {
    if (value.len == 0) return null;
    var s = value;
    if (s[0] == '#') s = s[1..];
    if (s.len != 6) return null;
    const std = @import("std");
    return std.fmt.parseUnsigned(u32, s, 16) catch null;
}
