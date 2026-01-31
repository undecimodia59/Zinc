const std = @import("std");
const Allocator = std.mem.Allocator;

/// Completion item kind (compatible with LSP CompletionItemKind)
pub const CompletionKind = enum(u8) {
    text = 1,
    method = 2,
    function = 3,
    constructor = 4,
    field = 5,
    variable = 6,
    class = 7,
    interface = 8,
    module = 9,
    property = 10,
    unit = 11,
    value = 12,
    enum_member = 13,
    keyword = 14,
    snippet = 15,
    color = 16,
    file = 17,
    reference = 18,
    folder = 19,
    constant = 20,
    struct_field = 21,
    event = 22,
    operator = 23,
    type_parameter = 24,
};

/// Generic completion item that can come from buffer analysis or LSP
pub const CompletionItem = struct {
    /// The text to display and insert
    label: []const u8,
    /// Kind of completion (for icons)
    kind: CompletionKind = .text,
    /// Optional detail (e.g., type signature)
    detail: ?[]const u8 = null,
    /// Score for sorting (higher = better match)
    score: i32 = 0,

    /// Owned version for items that manage their own memory
    pub const Owned = struct {
        label: []u8,
        kind: CompletionKind,
        detail: ?[]u8,
        score: i32,

        pub fn deinit(self: *Owned, allocator: Allocator) void {
            allocator.free(self.label);
            if (self.detail) |d| allocator.free(d);
        }

        pub fn asItem(self: *const Owned) CompletionItem {
            return .{
                .label = self.label,
                .kind = self.kind,
                .detail = self.detail,
                .score = self.score,
            };
        }
    };
};

/// Buffer-based completion: extracts identifiers from source text
pub const BufferCompleter = struct {
    allocator: Allocator,
    items: std.ArrayListUnmanaged(Entry),

    const Entry = struct {
        text: []u8,
        count: u32,
        last_offset: u32,
    };

    pub fn init(allocator: Allocator) BufferCompleter {
        return .{
            .allocator = allocator,
            .items = .empty,
        };
    }

    pub fn deinit(self: *BufferCompleter) void {
        for (self.items.items) |entry| {
            self.allocator.free(entry.text);
        }
        self.items.deinit(self.allocator);
    }

    /// Clear all items
    pub fn clear(self: *BufferCompleter) void {
        for (self.items.items) |entry| {
            self.allocator.free(entry.text);
        }
        self.items.clearRetainingCapacity();
    }

    /// Parse text and extract all identifiers
    pub fn indexText(self: *BufferCompleter, text: []const u8) void {
        self.clear();

        var map = std.StringHashMap(usize).init(self.allocator);
        defer map.deinit();

        var i: usize = 0;
        while (i < text.len) {
            if (!isIdentStart(text[i])) {
                i += 1;
                continue;
            }

            const start_idx = i;
            i += 1;
            while (i < text.len and isIdentChar(text[i])) : (i += 1) {}

            const token = text[start_idx..i];
            if (token.len == 0) continue;

            if (map.get(token)) |idx| {
                self.items.items[idx].count += 1;
                self.items.items[idx].last_offset = @intCast(start_idx);
            } else {
                const copy = self.allocator.dupe(u8, token) catch continue;
                self.items.append(self.allocator, .{
                    .text = copy,
                    .count = 1,
                    .last_offset = @intCast(start_idx),
                }) catch {
                    self.allocator.free(copy);
                    continue;
                };
                _ = map.put(copy, self.items.items.len - 1) catch {};
            }
        }
    }

    /// Get completions matching prefix, sorted by relevance
    pub fn getCompletions(
        self: *BufferCompleter,
        prefix: []const u8,
        cursor_offset: u32,
        out: *std.ArrayListUnmanaged(CompletionItem),
        allocator: Allocator,
        max_results: usize,
    ) void {
        out.clearRetainingCapacity();

        // Collect matching indices
        var matches: std.ArrayListUnmanaged(usize) = .empty;
        defer matches.deinit(self.allocator);

        for (self.items.items, 0..) |entry, idx| {
            if (std.mem.startsWith(u8, entry.text, prefix)) {
                matches.append(self.allocator, idx) catch continue;
            }
        }

        // Sort by relevance: proximity to cursor, then frequency
        const SortCtx = struct {
            items: []const Entry,
            cursor: u32,
            prefix: []const u8,

            fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                const item_a = ctx.items[a];
                const item_b = ctx.items[b];

                // Exact match first
                const exact_a = item_a.text.len == ctx.prefix.len;
                const exact_b = item_b.text.len == ctx.prefix.len;
                if (exact_a != exact_b) return exact_a;

                // Then by proximity to cursor
                const dist_a = absDiff(item_a.last_offset, ctx.cursor);
                const dist_b = absDiff(item_b.last_offset, ctx.cursor);
                if (dist_a != dist_b) return dist_a < dist_b;

                // Then by frequency
                if (item_a.count != item_b.count) return item_a.count > item_b.count;

                // Then alphabetically
                return std.mem.lessThan(u8, item_a.text, item_b.text);
            }
        };

        std.mem.sort(usize, matches.items, SortCtx{
            .items = self.items.items,
            .cursor = cursor_offset,
            .prefix = prefix,
        }, SortCtx.lessThan);

        // Convert to CompletionItems
        const count = @min(matches.items.len, max_results);
        for (matches.items[0..count]) |idx| {
            const entry = self.items.items[idx];
            out.append(allocator, .{
                .label = entry.text,
                .kind = .text,
                .detail = null,
                .score = @intCast(entry.count),
            }) catch continue;
        }
    }
};

// Helper functions

pub fn isIdentStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

pub fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

pub fn isIdentCharUnicode(c: u32) bool {
    if (c > 0x7f) return false;
    return isIdentChar(@intCast(c));
}

fn absDiff(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

// Tests

test "BufferCompleter basic" {
    const allocator = std.testing.allocator;

    var completer = BufferCompleter.init(allocator);
    defer completer.deinit();

    completer.indexText("foo bar foo baz foobar");

    var results = std.ArrayList(CompletionItem).init(allocator);
    defer results.deinit();

    completer.getCompletions("fo", 0, &results, 10);

    try std.testing.expect(results.items.len == 2); // foo, foobar
}
