const std = @import("std");

pub const max_file_size: usize = 10 * 1024 * 1024;

pub fn readUtf8File(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_size: usize,
) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.size > max_size) return error.FileTooLarge;

    const content = try file.readToEndAlloc(allocator, max_size);
    errdefer allocator.free(content);

    if (!std.unicode.utf8ValidateSlice(content)) return error.InvalidUtf8;

    return content;
}

pub fn writeFileAtomic(path: []const u8, content: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_name = try std.fmt.bufPrint(&tmp_buf, ".{s}.zinc.tmp", .{base});

    var dir_handle = try std.fs.cwd().openDir(dir, .{});
    defer dir_handle.close();

    // Write temp + rename so we don't clobber the original on failure.
    const f = try dir_handle.createFile(tmp_name, .{ .truncate = true });
    errdefer dir_handle.deleteFile(tmp_name) catch {};

    try f.writeAll(content);
    try f.sync(); // Ensure data is flushed to disk
    f.close();

    // Rename after close and sync
    dir_handle.rename(tmp_name, base) catch |err| {
        dir_handle.deleteFile(tmp_name) catch {};
        return err;
    };
}
