const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk4");
const gio = @import("gio");
const gobject = @import("gobject");

const file_tree = @import("file_tree.zig");
const editor = @import("editor/root.zig");
const settings = @import("settings.zig");
const keybindings = @import("keybindings.zig");
const config = @import("../utils/config.zig");

const Allocator = std.mem.Allocator;

/// Global application state
pub var state: ?*AppState = null;

/// Global allocator - must outlive the application
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = gpa.allocator();

/// Application state containing all UI components and runtime data
pub const AppState = struct {
    allocator: Allocator,
    window: *gtk.ApplicationWindow,
    header_bar: *gtk.HeaderBar,
    title_label: *gtk.Label,
    paned: *gtk.Paned,
    statusbar: *gtk.Statusbar,

    // File tree components
    file_tree: *gtk.TreeView,
    tree_store: *gtk.TreeStore,
    file_tree_scroll: *gtk.ScrolledWindow,

    // Editor components
    code_view: *gtk.TextView,
    code_scroll: *gtk.ScrolledWindow,
    config: *config.Config,
    line_highlight: *gtk.DrawingArea,

    // Runtime state
    current_path: ?[]const u8,
    current_file: ?[]const u8,
    file_tree_position: c_int,

    // Added modified to fix leak on editor.getContent()
    modified: bool,

    gutter: *gtk.DrawingArea,

    pub fn deinit(self: *AppState) void {
        if (self.current_path) |p| self.allocator.free(p);
        if (self.current_file) |f| self.allocator.free(f);
        self.file_tree_scroll.as(gobject.Object).unref();
        self.config.deinit();
        self.allocator.destroy(self.config);
        self.allocator.destroy(self);
    }

    pub fn setTitle(self: *AppState, title: [:0]const u8) void {
        self.title_label.setText(title.ptr);
        self.window.as(gtk.Window).setTitle(title.ptr);
    }

    pub fn setStatus(self: *AppState, message: [:0]const u8) void {
        _ = self.statusbar.push(0, message.ptr);
    }

    pub fn setModified(self: *AppState, m: bool) void {
        self.modified = m;
    }
};

/// Called when the GTK application is activated
pub fn onActivate(app_ptr: *gtk.Application, user_data: *gtk.Application) callconv(.c) void {
    _ = user_data;

    // Create app state using global allocator
    const app_state = allocator.create(AppState) catch {
        std.debug.print("Failed to allocate AppState\n", .{});
        return;
    };

    // Load configuration
    const app_config = allocator.create(config.Config) catch {
        std.debug.print("Failed to allocate Config\n", .{});
        return;
    };
    app_config.* = config.Config.init(allocator);
    app_config.load() catch |err| {
        std.debug.print("Failed to load config: {}\n", .{err});
    };

    // Create main window
    const window = gtk.ApplicationWindow.new(app_ptr);
    window.as(gtk.Window).setTitle("Zinc");
    window.as(gtk.Window).setDefaultSize(
        @intCast(app_config.ui.window_width),
        @intCast(app_config.ui.window_height),
    );

    // Attach keyboard shortcuts (Ctrl+S, Ctrl+E, etc.)
    keybindings.attach(window);

    _ = gtk.Window.signals.close_request.connect(
        window.as(gtk.Window),
        *gtk.Window,
        &onCloseRequest,
        window.as(gtk.Window),
        .{},
    );

    // Main vertical box
    const main_box = gtk.Box.new(gtk.Orientation.vertical, 0);

    // Create header bar
    const header_result = createHeaderBar();
    const title_label = gtk.Label.new("Zinc IDE");
    header_result.header_bar.setTitleWidget(title_label.as(gtk.Widget));
    window.as(gtk.Window).setTitlebar(header_result.header_bar.as(gtk.Widget));

    // Create paned container
    const paned = gtk.Paned.new(gtk.Orientation.horizontal);
    paned.as(gtk.Widget).setVexpand(1);
    paned.setPosition(@intCast(app_config.ui.file_tree_width));
    // Prevent the file tree from collapsing below its size request.
    paned.setShrinkStartChild(0);
    // Allow the end child (editor) to resize freely.
    paned.setShrinkEndChild(1);
    paned.setResizeStartChild(1);
    paned.setResizeEndChild(1);

    // Create file tree (left side)
    const tree_result = file_tree.create();
    // Keep an extra ref so we can detach/reattach the widget safely.
    _ = tree_result.scroll.as(gobject.Object).ref();
    tree_result.scroll.as(gtk.Widget).setSizeRequest(@intCast(app_config.ui.file_tree_width), -1);
    file_tree.applyConfig(tree_result.tree_view, app_config);
    paned.setStartChild(tree_result.scroll.as(gtk.Widget));

    // Create editor (right side)
    const editor_result = editor.create(app_config);
    paned.setEndChild(editor_result.root.as(gtk.Widget));

    main_box.append(paned.as(gtk.Widget));

    // Create statusbar
    const statusbar = gtk.Statusbar.new();
    statusbar.as(gtk.Widget).setMarginStart(4);
    statusbar.as(gtk.Widget).setMarginEnd(4);
    _ = statusbar.push(0, "Ready");
    main_box.append(statusbar.as(gtk.Widget));

    window.as(gtk.Window).setChild(main_box.as(gtk.Widget));

    // Initialize state
    app_state.* = AppState{
        .allocator = allocator,
        .window = window,
        .header_bar = header_result.header_bar,
        .title_label = title_label,
        .paned = paned,
        .statusbar = statusbar,
        .file_tree = tree_result.tree_view,
        .tree_store = tree_result.tree_store,
        .file_tree_scroll = tree_result.scroll,
        .code_view = editor_result.text_view,
        .code_scroll = editor_result.scroll,
        .config = app_config,
        .line_highlight = editor_result.line_highlight,
        .current_path = null,
        .current_file = null,
        .file_tree_position = @intCast(app_config.ui.file_tree_width),
        .modified = false,
        .gutter = editor_result.gutter,
    };
    state = app_state;

    // Connect header bar button signals
    connectHeaderBarSignals(
        header_result.open_folder_btn,
        header_result.open_file_btn,
        header_result.settings_btn,
    );

    // Connect file tree signals
    file_tree.connectSignals(tree_result.tree_view);

    // Check for initial path from command line
    const path_ptr = app_ptr.as(gobject.Object).getData("initial_path");
    const path_len_ptr = app_ptr.as(gobject.Object).getData("initial_path_len");

    if (path_ptr != null and path_len_ptr != null) {
        const ptr: [*]const u8 = @ptrCast(path_ptr);
        const len: usize = @intFromPtr(path_len_ptr);
        const initial_path = ptr[0..len];
        openPath(initial_path);
    }

    // Show window
    window.as(gtk.Widget).setVisible(1);
}

const HeaderBarResult = struct {
    header_bar: *gtk.HeaderBar,
    open_folder_btn: *gtk.Button,
    open_file_btn: *gtk.Button,
    settings_btn: *gtk.Button,
};

fn createHeaderBar() HeaderBarResult {
    const header_bar = gtk.HeaderBar.new();

    // Open folder button
    const open_folder_btn = gtk.Button.newFromIconName("folder-open-symbolic");
    open_folder_btn.as(gtk.Widget).setTooltipText("Open Folder");
    header_bar.packStart(open_folder_btn.as(gtk.Widget));

    // Open file button
    const open_file_btn = gtk.Button.newFromIconName("document-open-symbolic");
    open_file_btn.as(gtk.Widget).setTooltipText("Open File");
    header_bar.packStart(open_file_btn.as(gtk.Widget));

    // Settings button
    const settings_btn = gtk.Button.newFromIconName("emblem-system-symbolic");
    settings_btn.as(gtk.Widget).setTooltipText("Settings");
    header_bar.packStart(settings_btn.as(gtk.Widget));

    return .{
        .header_bar = header_bar,
        .open_folder_btn = open_folder_btn,
        .open_file_btn = open_file_btn,
        .settings_btn = settings_btn,
    };
}

fn connectHeaderBarSignals(open_folder_btn: *gtk.Button, open_file_btn: *gtk.Button, settings_btn: *gtk.Button) void {
    _ = gtk.Button.signals.clicked.connect(open_folder_btn, *gtk.Button, &onOpenFolderClicked, open_folder_btn, .{});
    _ = gtk.Button.signals.clicked.connect(open_file_btn, *gtk.Button, &onOpenFileClicked, open_file_btn, .{});
    _ = gtk.Button.signals.clicked.connect(settings_btn, *gtk.Button, &onSettingsClicked, settings_btn, .{});
}

fn onOpenFolderClicked(_: *gtk.Button, _: *gtk.Button) callconv(.c) void {
    const app_state = state orelse return;

    const dialog = gtk.FileDialog.new();
    dialog.setTitle("Open Folder");
    dialog.setModal(1);

    dialog.selectFolder(
        app_state.window.as(gtk.Window),
        null,
        &onFolderSelected,
        null,
    );
}

fn onFolderSelected(
    source_object: ?*gobject.Object,
    res: *gio.AsyncResult,
    _: ?*anyopaque,
) callconv(.c) void {
    const glib = @import("glib");
    const dialog: *gtk.FileDialog = @ptrCast(source_object orelse return);

    var err: ?*glib.Error = null;
    const file = dialog.selectFolderFinish(res, &err);

    if (err != null) {
        glib.Error.free(err.?);
        return;
    }

    if (file) |f| {
        const path = f.getPath();
        if (path) |p| {
            openPath(std.mem.span(p));
        }
        f.as(gobject.Object).unref();
    }
}

fn onOpenFileClicked(_: *gtk.Button, _: *gtk.Button) callconv(.c) void {
    const app_state = state orelse return;

    const dialog = gtk.FileDialog.new();
    dialog.setTitle("Open File");
    dialog.setModal(1);

    dialog.open(
        app_state.window.as(gtk.Window),
        null,
        &onFileSelected,
        null,
    );
}

fn onSettingsClicked(_: *gtk.Button, _: *gtk.Button) callconv(.c) void {
    const app_state = state orelse return;
    settings.show(app_state.window, app_state.config, &onSettingsApply, app_state);
}

fn onFileSelected(
    source_object: ?*gobject.Object,
    res: *gio.AsyncResult,
    _: ?*anyopaque,
) callconv(.c) void {
    const glib = @import("glib");
    const dialog: *gtk.FileDialog = @ptrCast(source_object orelse return);

    var err: ?*glib.Error = null;
    const file = dialog.openFinish(res, &err);

    if (err != null) {
        glib.Error.free(err.?);
        return;
    }

    if (file) |f| {
        const path = f.getPath();
        if (path) |p| {
            openPath(std.mem.span(p));
        }
        f.as(gobject.Object).unref();
    }
}

/// Open a file or folder path
pub fn openPath(path: []const u8) void {
    const app_state = state orelse return;

    const stat = std.fs.cwd().statFile(path) catch |err| {
        std.debug.print("Error accessing path: {}\n", .{err});
        app_state.setStatus("Error: Cannot access path");
        return;
    };

    switch (stat.kind) {
        .directory => {
            file_tree.openFolder(path);
        },
        .file => {
            if (std.fs.path.dirname(path)) |dir| {
                file_tree.openFolder(dir);
                if (app_state.current_path) |p| app_state.allocator.free(p);
                app_state.current_path = app_state.allocator.dupe(u8, dir) catch null;
            }
            editor.loadFile(path);
        },
        else => {
            app_state.setStatus("Error: Unsupported file type");
        },
    }

    // Update current path for folders
    if (stat.kind == .directory) {
        if (app_state.current_path) |p| app_state.allocator.free(p);
        app_state.current_path = app_state.allocator.dupe(u8, path) catch null;
    }
}

fn onCloseRequest(_: *gtk.Window, _: *gtk.Window) callconv(.c) c_int {
    const app_state = state orelse return 0;
    const cfg = app_state.config;

    const pos = app_state.paned.getPosition();
    if (pos > 0) cfg.ui.file_tree_width = @intCast(pos);

    var w: c_int = 0;
    var h: c_int = 0;
    app_state.window.as(gtk.Window).getDefaultSize(&w, &h);
    if (w > 0) cfg.ui.window_width = @intCast(w);
    if (h > 0) cfg.ui.window_height = @intCast(h);

    cfg.save() catch |err| {
        std.debug.print("Failed to save config: {}\n", .{err});
    };

    return 0;
}

fn reloadConfig() void {
    const app_state = state orelse return;
    const cfg = app_state.config;

    cfg.load() catch |err| {
        std.debug.print("Failed to load config: {}\n", .{err});
        app_state.setStatus("Error: failed to load config");
        return;
    };
    applyConfigToUi(app_state, cfg);
    app_state.setStatus("Settings reloaded");
}

fn onSettingsApply(ctx: ?*anyopaque, cfg: *config.Config) void {
    const app_state: *AppState = @ptrCast(@alignCast(ctx orelse return));
    applyConfigToUi(app_state, cfg);
    app_state.setStatus("Settings applied");
}

fn applyConfigToUi(app_state: *AppState, cfg: *config.Config) void {
    editor.applyConfig(cfg);
    file_tree.applyConfig(app_state.file_tree, cfg);
    file_tree.refreshDisplay();

    app_state.window.as(gtk.Window).setDefaultSize(
        @intCast(cfg.ui.window_width),
        @intCast(cfg.ui.window_height),
    );

    const width: c_int = @intCast(cfg.ui.file_tree_width);
    app_state.file_tree_scroll.as(gtk.Widget).setSizeRequest(width, -1);
    if (app_state.paned.getStartChild() != null) {
        app_state.paned.setPosition(width);
    }
    app_state.file_tree_position = width;
}
