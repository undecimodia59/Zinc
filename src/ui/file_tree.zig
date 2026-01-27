const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk4");
const gobject = @import("gobject");

const app = @import("app.zig");
const editor = @import("editor/root.zig");
const file_icons = @import("file_icons.zig");
const config = @import("../utils/config.zig");

const tree_css_class: [:0]const u8 = "zinc-file-tree";

// Track CSS provider to avoid leaking on repeated applyConfig calls
var tree_css_provider: ?*gtk.CssProvider = null;

/// Result of creating a file tree widget
pub const FileTreeResult = struct {
    scroll: *gtk.ScrolledWindow,
    tree_view: *gtk.TreeView,
    tree_store: *gtk.TreeStore,
};

/// Create the file tree widget
pub fn create() FileTreeResult {
    const tree_scroll = gtk.ScrolledWindow.new();
    tree_scroll.as(gtk.Widget).setSizeRequest(150, -1);
    tree_scroll.as(gtk.Widget).setHexpand(0);

    // Create tree store with columns: icon, display name, raw name
    var col_types = [_]usize{
        gobject.ext.types.string,
        gobject.ext.types.string,
        gobject.ext.types.string,
    };
    const tree_store = gtk.TreeStore.newv(3, &col_types);

    const file_tree = gtk.TreeView.newWithModel(tree_store.as(gtk.TreeModel));
    file_tree.setHeadersVisible(0);
    file_tree.setEnableSearch(1);
    file_tree.as(gtk.Widget).addCssClass(tree_css_class.ptr);

    // Create column for icon + filename
    const icon_renderer = gtk.CellRendererText.new();
    const name_renderer = gtk.CellRendererText.new();
    const column = gtk.TreeViewColumn.new();
    column.setTitle("Name");
    column.packStart(icon_renderer.as(gtk.CellRenderer), 0);
    column.packStart(name_renderer.as(gtk.CellRenderer), 1);
    column.addAttribute(icon_renderer.as(gtk.CellRenderer), "text", 0);
    column.addAttribute(name_renderer.as(gtk.CellRenderer), "text", 1);
    _ = file_tree.appendColumn(column);

    tree_scroll.setChild(file_tree.as(gtk.Widget));

    return .{
        .scroll = tree_scroll,
        .tree_view = file_tree,
        .tree_store = tree_store,
    };
}

pub fn applyConfig(tree_view: *gtk.TreeView, cfg: *const config.Config) void {
    const display = gdk.Display.getDefault() orelse return;

    // Remove old provider if it exists
    if (tree_css_provider) |old| {
        gtk.StyleContext.removeProviderForDisplay(display, old.as(gtk.StyleProvider));
        old.as(gobject.Object).unref();
    }

    const provider = gtk.CssProvider.new();
    tree_css_provider = provider;

    tree_view.as(gtk.Widget).addCssClass(tree_css_class.ptr);

    const bg = cfg.theme.background;
    const fg = cfg.theme.foreground;
    const sel = cfg.theme.selection;

    const font_css = if (cfg.ui.nerd_font_icons)
        \\"{s}", "Symbols Nerd Font", "Symbols Nerd Font Mono"
    else
        \\"{s}"
    ;

    const css = std.fmt.allocPrint(
        app.allocator(),
        \\@define-color theme_selected_bg_color #{X:0>6};
        \\@define-color theme_selected_fg_color #{X:0>6};
        \\.{s} {{
        \\  font-family: {s};
        \\  font-size: {d}pt;
        \\  background: #{X:0>6};
        \\  color: #{X:0>6};
        \\}}
        \\.{s}:selected {{
        \\  background: @theme_selected_bg_color;
        \\  color: @theme_selected_fg_color;
        \\}}
    ,
        .{
            sel,
            fg,
            tree_css_class,
            font_css,
            cfg.editor.font_size,
            bg,
            fg,
            tree_css_class,
        },
    ) catch return;
    defer app.allocator().free(css);

    const css_z = app.allocator().allocSentinel(u8, css.len, 0) catch return;
    defer app.allocator().free(css_z);
    @memcpy(css_z, css);

    provider.loadFromData(css_z.ptr, @intCast(css_z.len));
    gtk.StyleContext.addProviderForDisplay(
        display,
        provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
}

/// Connect signals to the file tree
pub fn connectSignals(tree_view: *gtk.TreeView) void {
    _ = gtk.TreeView.signals.row_activated.connect(
        tree_view,
        *gtk.TreeView,
        &onRowActivated,
        tree_view,
        .{},
    );
}

/// Open a folder and populate the tree
pub fn openFolder(path: []const u8) void {
    const state = app.state orelse return;

    // Clear existing tree
    state.tree_store.clear();

    // Get absolute path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = std.fs.cwd().realpath(path, &path_buf) catch path;

    // Update current_path to the absolute path
    if (state.current_path) |p| state.allocator.free(p);
    state.current_path = state.allocator.dupe(u8, abs_path) catch null;

    // Update title
    const basename = std.fs.path.basename(abs_path);
    var title_buf: [256:0]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "Zinc IDE - {s}", .{basename}) catch "Zinc IDE";
    state.setTitle(title);

    // Populate tree
    populateTree(abs_path, null, 0);

    // Update status
    var status_buf: [512:0]u8 = undefined;
    const status = std.fmt.bufPrintZ(&status_buf, "Opened: {s}", .{abs_path}) catch "Opened folder";
    state.setStatus(status);
}

pub fn refreshDisplay() void {
    const state = app.state orelse return;
    const base_path = state.current_path orelse return;

    state.tree_store.clear();
    populateTree(base_path, null, 0);
}

const TreeEntry = struct {
    name: []const u8,
    kind: std.fs.Dir.Entry.Kind,
};

fn populateTree(path: []const u8, parent: ?*gtk.TreeIter, depth: u32) void {
    if (depth > 10) return;

    const state = app.state orelse return;

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();

    // Collect entries
    var entries: std.ArrayListUnmanaged(TreeEntry) = .empty;
    defer {
        for (entries.items) |entry| {
            state.allocator.free(entry.name);
        }
        entries.deinit(state.allocator);
    }

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        // Skip hidden files
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        const name_copy = state.allocator.dupe(u8, entry.name) catch continue;
        entries.append(state.allocator, .{
            .name = name_copy,
            .kind = entry.kind,
        }) catch {
            state.allocator.free(name_copy);
            continue;
        };
    }

    // Sort: directories first, then alphabetically
    std.mem.sort(TreeEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: TreeEntry, b: TreeEntry) bool {
            const a_is_dir = a.kind == .directory;
            const b_is_dir = b.kind == .directory;
            if (a_is_dir != b_is_dir) return a_is_dir;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    for (entries.items) |entry| {
        var tree_iter: gtk.TreeIter = undefined;
        state.tree_store.append(&tree_iter, parent);

        const use_icons = state.config.ui.nerd_font_icons;
        const is_dir = entry.kind == .directory;
        const icon = file_icons.iconForName(entry.name, is_dir, use_icons);

        // Display name keeps the filesystem name intact.
        var display_buf: [512]u8 = undefined;
        const display_name = if (is_dir)
            std.fmt.bufPrint(&display_buf, "{s}/", .{entry.name}) catch entry.name
        else
            entry.name;

        // Create null-terminated strings.
        var icon_z: [32]u8 = undefined;
        var icon_len: usize = 0;
        if (icon.len > 0 and icon.len < icon_z.len) {
            @memcpy(icon_z[0..icon.len], icon);
            icon_len = icon.len;
        }
        icon_z[icon_len] = 0;

        var display_z: [513]u8 = undefined;
        @memcpy(display_z[0..display_name.len], display_name);
        display_z[display_name.len] = 0;

        var raw_z: [513]u8 = undefined;
        @memcpy(raw_z[0..entry.name.len], entry.name);
        raw_z[entry.name.len] = 0;

        var value: gobject.Value = std.mem.zeroes(gobject.Value);
        _ = value.init(gobject.ext.types.string);
        value.setString(@ptrCast(&icon_z));
        state.tree_store.setValue(&tree_iter, 0, &value);
        value.unset();

        _ = value.init(gobject.ext.types.string);
        value.setString(@ptrCast(&display_z));
        state.tree_store.setValue(&tree_iter, 1, &value);
        value.unset();

        _ = value.init(gobject.ext.types.string);
        value.setString(@ptrCast(&raw_z));
        state.tree_store.setValue(&tree_iter, 2, &value);
        value.unset();

        // Recursively add subdirectories (limited depth)
        if (entry.kind == .directory and depth < 2) {
            var subpath_buf: [std.fs.max_path_bytes]u8 = undefined;
            const subpath = std.fmt.bufPrint(&subpath_buf, "{s}/{s}", .{ path, entry.name }) catch continue;
            populateTree(subpath, &tree_iter, depth + 1);
        }
    }
}

fn onRowActivated(
    tree_view: *gtk.TreeView,
    gtk_path: *gtk.TreePath,
    _: ?*gtk.TreeViewColumn,
    _: *gtk.TreeView,
) callconv(.c) void {
    const state = app.state orelse return;

    var tree_iter: gtk.TreeIter = undefined;
    if (state.tree_store.as(gtk.TreeModel).getIter(&tree_iter, gtk_path) == 0) return;

    // Get the raw name from the tree
    var value: gobject.Value = std.mem.zeroes(gobject.Value);
    state.tree_store.as(gtk.TreeModel).getValue(&tree_iter, 2, &value);

    const name_ptr = value.getString();
    if (name_ptr == null) {
        value.unset();
        return;
    }
    const raw_name = std.mem.span(name_ptr.?);

    // Copy the name before unsetting value (which frees the string).
    const first_part = state.allocator.dupe(u8, raw_name) catch {
        value.unset();
        return;
    };
    value.unset();

    // Reconstruct the full path by walking up the tree
    var path_parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (path_parts.items) |part| state.allocator.free(part);
        path_parts.deinit(state.allocator);
    }

    path_parts.append(state.allocator, first_part) catch {
        state.allocator.free(first_part);
        return;
    };

    // Walk up to root
    var current_iter = tree_iter;
    var parent_iter: gtk.TreeIter = undefined;
    while (state.tree_store.as(gtk.TreeModel).iterParent(&parent_iter, &current_iter) != 0) {
        current_iter = parent_iter;
        var parent_value: gobject.Value = std.mem.zeroes(gobject.Value);
        state.tree_store.as(gtk.TreeModel).getValue(&current_iter, 2, &parent_value);
        const parent_name_ptr = parent_value.getString();
        if (parent_name_ptr) |ptr| {
            const parent_name = std.mem.span(ptr);
            path_parts.append(state.allocator, state.allocator.dupe(u8, parent_name) catch {
                parent_value.unset();
                return;
            }) catch {
                parent_value.unset();
                return;
            };
        }
        parent_value.unset();
    }

    // Reverse to get correct order
    std.mem.reverse([]const u8, path_parts.items);

    // Build full path
    const base_path = state.current_path orelse return;
    var full_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var full_path_len: usize = 0;

    @memcpy(full_path_buf[0..base_path.len], base_path);
    full_path_len = base_path.len;

    for (path_parts.items) |part| {
        if (full_path_len + 1 + part.len >= std.fs.max_path_bytes) return;
        full_path_buf[full_path_len] = '/';
        full_path_len += 1;
        @memcpy(full_path_buf[full_path_len .. full_path_len + part.len], part);
        full_path_len += part.len;
    }

    const full_path = full_path_buf[0..full_path_len];

    // Check if it's a directory or file
    const stat = std.fs.cwd().statFile(full_path) catch return;

    if (stat.kind == .file) {
        editor.loadFile(full_path);
    } else if (stat.kind == .directory) {
        // Toggle expand/collapse for directories
        if (tree_view.rowExpanded(gtk_path) != 0) {
            _ = tree_view.collapseRow(gtk_path);
        } else {
            _ = tree_view.expandRow(gtk_path, 0);
        }
    }
}
