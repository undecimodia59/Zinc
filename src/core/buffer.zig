//! Text buffer management
//!
//! This module will handle text buffer operations including:
//! - Undo/redo history
//! - Text manipulation
//! - Cursor management
//! - Selection handling

const std = @import("std");

const Allocator = std.mem.Allocator;

/// A text buffer with editing capabilities
pub const Buffer = struct {
    allocator: Allocator,
    content: std.ArrayList(u8),
    file_path: ?[]const u8,
    modified: bool,

    pub fn init(allocator: Allocator) Buffer {
        return .{
            .allocator = allocator,
            .content = std.ArrayList(u8).init(allocator),
            .file_path = null,
            .modified = false,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.content.deinit();
        if (self.file_path) |path| {
            self.allocator.free(path);
        }
    }

    pub fn loadFromFile(self: *Buffer, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        if (stat.size > 100 * 1024 * 1024) {
            return error.FileTooLarge;
        }

        self.content.clearRetainingCapacity();
        try self.content.ensureTotalCapacity(@intCast(stat.size));

        var buf: [8192]u8 = undefined;
        while (true) {
            const bytes_read = try file.read(&buf);
            if (bytes_read == 0) break;
            try self.content.appendSlice(buf[0..bytes_read]);
        }

        if (self.file_path) |old_path| {
            self.allocator.free(old_path);
        }
        self.file_path = try self.allocator.dupe(u8, path);
        self.modified = false;
    }

    pub fn saveToFile(self: *Buffer) !void {
        const path = self.file_path orelse return error.NoFilePath;

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        try file.writeAll(self.content.items);
        self.modified = false;
    }

    pub fn getText(self: *const Buffer) []const u8 {
        return self.content.items;
    }

    pub fn setText(self: *Buffer, text: []const u8) !void {
        self.content.clearRetainingCapacity();
        try self.content.appendSlice(text);
        self.modified = true;
    }

    pub fn insert(self: *Buffer, pos: usize, text: []const u8) !void {
        try self.content.insertSlice(pos, text);
        self.modified = true;
    }

    pub fn delete(self: *Buffer, start: usize, end: usize) void {
        if (start >= self.content.items.len or end > self.content.items.len or start >= end) {
            return;
        }
        self.content.replaceRange(start, end - start, &[_]u8{}) catch {};
        self.modified = true;
    }
};
