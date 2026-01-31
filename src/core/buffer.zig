const std = @import("std");
const Allocator = std.mem.Allocator;

/// Represents an open file buffer
pub const Buffer = struct {
    allocator: Allocator,
    /// Absolute path to the file (null for untitled)
    path: ?[]const u8,
    /// Whether the buffer has unsaved changes
    modified: bool = false,
    /// Cursor line (1-indexed)
    cursor_line: u32 = 1,
    /// Cursor column (1-indexed)
    cursor_col: u32 = 1,
    /// Scroll position (top visible line)
    scroll_top: u32 = 0,
    /// Buffer content (owned, null if not loaded)
    content: ?[]const u8 = null,

    pub fn init(allocator: Allocator, path: ?[]const u8) !Buffer {
        const path_copy = if (path) |p| try allocator.dupe(u8, p) else null;
        return .{
            .allocator = allocator,
            .path = path_copy,
        };
    }

    pub fn deinit(self: *Buffer) void {
        if (self.path) |p| self.allocator.free(p);
        if (self.content) |c| self.allocator.free(c);
        self.path = null;
        self.content = null;
    }

    /// Get display name for tab (filename or "untitled")
    pub fn getDisplayName(self: *const Buffer) []const u8 {
        if (self.path) |p| {
            return std.fs.path.basename(p);
        }
        return "untitled";
    }

    /// Check if this buffer matches a path
    pub fn matchesPath(self: *const Buffer, path: []const u8) bool {
        if (self.path) |p| {
            return std.mem.eql(u8, p, path);
        }
        return false;
    }
};

/// Manages multiple open buffers
pub const BufferManager = struct {
    allocator: Allocator,
    buffers: std.ArrayListUnmanaged(Buffer),
    active_index: usize,

    pub fn init(allocator: Allocator) BufferManager {
        return .{
            .allocator = allocator,
            .buffers = .empty,
            .active_index = 0,
        };
    }

    pub fn deinit(self: *BufferManager) void {
        for (self.buffers.items) |*buf| {
            buf.deinit();
        }
        self.buffers.deinit(self.allocator);
    }

    /// Get the currently active buffer
    pub fn getActive(self: *BufferManager) ?*Buffer {
        if (self.buffers.items.len == 0) return null;
        if (self.active_index >= self.buffers.items.len) {
            self.active_index = self.buffers.items.len - 1;
        }
        return &self.buffers.items[self.active_index];
    }

    /// Get buffer count
    pub fn count(self: *const BufferManager) usize {
        return self.buffers.items.len;
    }

    /// Find buffer by path, returns index or null
    pub fn findByPath(self: *BufferManager, path: []const u8) ?usize {
        for (self.buffers.items, 0..) |*buf, i| {
            if (buf.matchesPath(path)) return i;
        }
        return null;
    }

    /// Open a file - returns existing buffer if already open, or creates new
    pub fn open(self: *BufferManager, path: []const u8) !*Buffer {
        // Check if already open
        if (self.findByPath(path)) |idx| {
            self.active_index = idx;
            return &self.buffers.items[idx];
        }

        // Create new buffer
        var buf = try Buffer.init(self.allocator, path);
        errdefer buf.deinit();

        try self.buffers.append(self.allocator, buf);
        self.active_index = self.buffers.items.len - 1;
        return &self.buffers.items[self.active_index];
    }

    /// Create a new untitled buffer
    pub fn createUntitled(self: *BufferManager) !*Buffer {
        var buf = try Buffer.init(self.allocator, null);
        errdefer buf.deinit();

        try self.buffers.append(self.allocator, buf);
        self.active_index = self.buffers.items.len - 1;
        return &self.buffers.items[self.active_index];
    }

    /// Close buffer at index, returns true if IDE should quit (last buffer closed)
    pub fn close(self: *BufferManager, index: usize) bool {
        if (index >= self.buffers.items.len) return false;

        var buf = self.buffers.orderedRemove(index);
        buf.deinit();

        // Adjust active index
        if (self.buffers.items.len == 0) {
            return true; // No more buffers, quit IDE
        }
        if (self.active_index >= self.buffers.items.len) {
            self.active_index = self.buffers.items.len - 1;
        } else if (self.active_index > index) {
            self.active_index -= 1;
        }
        return false;
    }

    /// Close the active buffer
    pub fn closeActive(self: *BufferManager) bool {
        return self.close(self.active_index);
    }

    /// Switch to buffer at index
    pub fn switchTo(self: *BufferManager, index: usize) void {
        if (index < self.buffers.items.len) {
            self.active_index = index;
        }
    }

    /// Switch to next buffer (wraps around)
    pub fn nextBuffer(self: *BufferManager) void {
        if (self.buffers.items.len <= 1) return;
        self.active_index = (self.active_index + 1) % self.buffers.items.len;
    }

    /// Switch to previous buffer (wraps around)
    pub fn prevBuffer(self: *BufferManager) void {
        if (self.buffers.items.len <= 1) return;
        if (self.active_index == 0) {
            self.active_index = self.buffers.items.len - 1;
        } else {
            self.active_index -= 1;
        }
    }

    /// Get all buffers for iteration
    pub fn getBuffers(self: *BufferManager) []Buffer {
        return self.buffers.items;
    }

    /// Check if any buffer has unsaved changes
    pub fn hasUnsavedChanges(self: *BufferManager) bool {
        for (self.buffers.items) |buf| {
            if (buf.modified) return true;
        }
        return false;
    }
};
