const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk4");
const gio = @import("gio");
const gobject = @import("gobject");
const app = @import("app.zig");
const editor = @import("editor/root.zig");
const vim_cmd = @import("vim/command.zig");

const PaletteMode = enum {
    app,
    vim,
};

// App command definition
const AppCommand = struct {
    label: [:0]const u8,
    action: ?*const fn (app_state: *app.AppState) void,
};

const VimCommandKind = enum {
    execute,
    template,
};

const VimCommand = struct {
    label: [:0]const u8,
    cmd: []const u8,
    kind: VimCommandKind,
};

// Available app commands
const app_commands = [_]AppCommand{
    .{ .label = "File: Save", .action = cmdSave },
    .{ .label = "File: Save As...", .action = cmdSaveAs },
    .{ .label = "File: Open File...", .action = cmdOpenFile },
    .{ .label = "File: Open Folder...", .action = cmdOpenFolder },
    .{ .label = "File: Close Window", .action = cmdCloseWindow },
    .{ .label = "App: Quit", .action = cmdQuit },
    .{ .label = "View: Toggle Line Numbers", .action = cmdToggleLineNumbers },
    .{ .label = "View: Zoom In", .action = cmdZoomIn },
    .{ .label = "View: Zoom Out", .action = cmdZoomOut },
};

// Available vim commands (for ':' palette)
const vim_commands = [_]VimCommand{
    .{ .label = ":w - Save", .cmd = "w", .kind = .execute },
    .{ .label = ":w {file} - Save As", .cmd = "w ", .kind = .template },
    .{ .label = ":q - Quit", .cmd = "q", .kind = .execute },
    .{ .label = ":wq - Save and Quit", .cmd = "wq", .kind = .execute },
    .{ .label = ":q! - Quit (no save)", .cmd = "q!", .kind = .execute },
    .{ .label = ":e {file} - Open File", .cmd = "e ", .kind = .template },
    .{ .label = ":!{cmd} - Shell Command", .cmd = "!", .kind = .template },
    .{ .label = ":{line} - Go to Line", .cmd = "", .kind = .template },
};

const PaletteState = struct {
    dialog: *gtk.Window,
    filter: *gtk.StringFilter,
    entry: *gtk.SearchEntry,
    mode: PaletteMode,
};

var palette_state: ?PaletteState = null;

pub fn show(parent: *gtk.Window, mode: PaletteMode) void {
    if (palette_state) |*s| {
        s.dialog.present();
        return;
    }

    const dialog = gtk.Window.new();
    dialog.setTransientFor(parent);
    dialog.setModal(1);
    dialog.setTitle("Command Palette");
    // dialog.setDefaultSize(600, 400); // Dynamic height
    dialog.setResizable(0);
    dialog.setDecorated(0); // Frameless feels more like a palette

    // Center logic (approximate)
    // Note: GTK4 doesn't prioritize manual positioning, but setModal+Transient handles typical dialog behavior.

    // Main layout
    const box = gtk.Box.new(gtk.Orientation.vertical, 6);
    box.as(gtk.Widget).setMarginStart(12);
    box.as(gtk.Widget).setMarginEnd(12);
    box.as(gtk.Widget).setMarginTop(12);
    box.as(gtk.Widget).setMarginBottom(12);

    // Search entry
    const entry = gtk.SearchEntry.new();
    box.append(entry.as(gtk.Widget));
    if (mode == .vim) {
        entry.as(gtk.Editable).setText(":");
        entry.as(gtk.Editable).setPosition(-1);
    }

    // Filterable list
    const str_list = gtk.StringList.new(null);
    switch (mode) {
        .app => {
            for (app_commands) |cmd| {
                str_list.append(cmd.label);
            }
        },
        .vim => {
            for (vim_commands) |cmd| {
                str_list.append(cmd.label);
            }
        },
    }

    const filter = gtk.StringFilter.new(@as(?*gtk.Expression, null));
    // Actually StringFilter defaults to strict match if no expression?
    // Let's set matching expression to the item string itself.
    // However, GtkStringList items are GtkStringObject.

    // Correct approach for filtering GtkStringList:
    // We filter on the 'string' property of GtkStringObject.
    const expr = gtk.PropertyExpression.new(gobject.typeFromName("GtkStringObject"), null, "string");
    filter.setExpression(expr.as(gtk.Expression));

    const filter_model = gtk.FilterListModel.new(str_list.as(gio.ListModel), filter.as(gtk.Filter));

    const selection_model = gtk.SingleSelection.new(filter_model.as(gio.ListModel));

    // ListView factory
    const factory = gtk.SignalListItemFactory.new();
    _ = gtk.SignalListItemFactory.signals.setup.connect(factory, ?*anyopaque, &onSetup, null, .{});
    _ = gtk.SignalListItemFactory.signals.bind.connect(factory, ?*anyopaque, &onBind, null, .{});

    const list_view = gtk.ListView.new(selection_model.as(gtk.SelectionModel), factory.as(gtk.ListItemFactory));

    const scroll = gtk.ScrolledWindow.new();
    scroll.setChild(list_view.as(gtk.Widget));
    scroll.setPropagateNaturalHeight(1);
    scroll.setMaxContentHeight(400);
    scroll.setPropagateNaturalWidth(1);
    scroll.setMinContentWidth(600);
    // scroll.as(gtk.Widget).setVexpand(1);
    box.append(scroll.as(gtk.Widget));

    dialog.setChild(box.as(gtk.Widget));

    // Connect entry change to filter
    // Connect entry change to filter
    _ = gtk.SearchEntry.signals.search_changed.connect(
        entry,
        *gtk.StringFilter,
        &onSearchChanged,
        filter,
        .{},
    );

    // Controller for Escape to close
    const key_controller = gtk.EventControllerKey.new();
    dialog.as(gtk.Widget).addController(key_controller.as(gtk.EventController));
    _ = gtk.EventControllerKey.signals.key_pressed.connect(
        key_controller,
        *gtk.Window,
        &onKeyPress,
        dialog,
        .{},
    );
    const entry_key_controller = gtk.EventControllerKey.new();
    entry.as(gtk.Widget).addController(entry_key_controller.as(gtk.EventController));
    _ = gtk.EventControllerKey.signals.key_pressed.connect(
        entry_key_controller,
        *gtk.Window,
        &onKeyPress,
        dialog,
        .{},
    );

    // Connect activation
    _ = gtk.ListView.signals.activate.connect(list_view, *gtk.FilterListModel, &onItemActivated, filter_model, .{});

    // Also bind Entry 'activate' to select first item
    _ = gtk.SearchEntry.signals.activate.connect(entry, *gtk.SingleSelection, &onEntryActivated, selection_model, .{});

    // Cleanup on close
    _ = gtk.Window.signals.close_request.connect(dialog, *gtk.Window, &onClose, dialog, .{});

    palette_state = .{
        .dialog = dialog,
        .filter = filter,
        .entry = entry,
        .mode = mode,
    };

    dialog.present();
}

fn onSetup(_: *gtk.SignalListItemFactory, item_obj: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
    const item: *gtk.ListItem = @ptrCast(item_obj);
    const label = gtk.Label.new("");
    label.as(gtk.Widget).setHalign(.start);
    label.as(gtk.Widget).setMarginStart(10);
    item.setChild(label.as(gtk.Widget));
}

fn onBind(_: *gtk.SignalListItemFactory, item_obj: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
    const item: *gtk.ListItem = @ptrCast(item_obj);
    const obj = item.getItem(); // GObject (GtkStringObject)
    const str_obj: *gtk.StringObject = @ptrCast(obj orelse return);

    const label_widget: *gtk.Label = @ptrCast(item.getChild() orelse return);
    label_widget.setText(str_obj.getString());
}

fn onSearchChanged(entry: *gtk.SearchEntry, filter: *gtk.StringFilter) callconv(.c) void {
    const text = entry.as(gtk.Editable).getText();
    filter.setSearch(text);
}

fn onItemActivated(_: *gtk.ListView, pos: c_uint, filter_model: *gtk.FilterListModel) callconv(.c) void {
    triggerCommand(pos, filter_model.as(gio.ListModel));
}

fn onEntryActivated(entry: *gtk.SearchEntry, model: *gtk.SingleSelection) callconv(.c) void {
    const text_ptr = entry.as(gtk.Editable).getText();
    const text = std.mem.span(text_ptr);

    // Check for vim command
    if (isVimCommand(text)) {
        if (app.state) |s| {
            var cmd_text = std.mem.trim(u8, text, " ");
            if (std.mem.startsWith(u8, cmd_text, ":")) {
                cmd_text = cmd_text[1..];
            }
            vim_cmd.execute(s.code_view, cmd_text);
        }
        // Close dialog
        if (palette_state) |*s| {
            s.dialog.destroy();
            palette_state = null;
        }
        return;
    }

    const pos = model.getSelected();
    if (pos == gtk.INVALID_LIST_POSITION) return;

    // Get the underlying list model (which is the FilterListModel)
    const filter_model = model.getModel();
    if (filter_model) |fm| {
        triggerCommand(pos, fm);
    }
}

fn triggerCommand(pos: c_uint, model: *gio.ListModel) void {
    const obj = model.getItem(pos) orelse return;
    const str_obj: *gtk.StringObject = @ptrCast(obj);
    const cmd_label_ptr = str_obj.getString();
    const cmd_label = std.mem.span(cmd_label_ptr);

    if (palette_state) |*s| {
        switch (s.mode) {
            .app => {
                for (app_commands) |cmd| {
                    if (std.mem.eql(u8, cmd.label, cmd_label)) {
                        if (cmd.action) |act| {
                            if (app.state) |state| act(state);
                        }
                        break;
                    }
                }
                s.dialog.destroy();
                palette_state = null;
                return;
            },
            .vim => {
                for (vim_commands) |cmd| {
                    if (!std.mem.eql(u8, cmd.label, cmd_label)) continue;
                    switch (cmd.kind) {
                        .execute => {
                            if (app.state) |state| {
                                vim_cmd.execute(state.code_view, cmd.cmd);
                            }
                            s.dialog.destroy();
                            palette_state = null;
                            return;
                        },
                        .template => {
                            var buf: [64:0]u8 = undefined;
                            const text = std.fmt.bufPrintZ(&buf, ":{s}", .{cmd.cmd}) catch return;
                            s.entry.as(gtk.Editable).setText(text.ptr);
                            s.entry.as(gtk.Editable).setPosition(-1);
                            _ = s.entry.as(gtk.Widget).grabFocus();
                            return;
                        },
                    }
                }
            },
        }
    }

    if (palette_state) |*s| {
        s.dialog.destroy();
        palette_state = null;
    }
}

fn onClose(_: *gtk.Window, _: *gtk.Window) callconv(.c) c_int {
    palette_state = null;
    return 0;
}

fn onKeyPress(
    _: *gtk.EventControllerKey,
    keyval: c_uint,
    _: c_uint,
    _: gdk.ModifierType,
    dialog: *gtk.Window,
) callconv(.c) c_int {
    if (keyval == gdk.KEY_Escape) {
        dialog.close();
        return 1;
    }
    return 0;
}

fn isVimCommand(text: []const u8) bool {
    var t = std.mem.trim(u8, text, " ");
    if (std.mem.startsWith(u8, t, ":")) {
        t = t[1..];
    }
    if (t.len == 0) return false;

    // Direct matches
    if (std.mem.eql(u8, t, "w")) return true;
    if (std.mem.eql(u8, t, "q")) return true;
    if (std.mem.eql(u8, t, "wq")) return true;
    if (std.mem.eql(u8, t, "q!")) return true;

    // Prefixes
    if (std.mem.startsWith(u8, t, "!")) return true;
    if (std.mem.startsWith(u8, t, "e ")) return true;
    if (std.mem.startsWith(u8, t, "w ")) return true; // Save as
    if (std.ascii.isDigit(t[0])) return true; // Line number

    return false;
}

// Command Actions

fn cmdQuit(s: *app.AppState) void {
    s.window.as(gtk.Window).close();
}

fn cmdSave(_: *app.AppState) void {
    editor.saveCurrentFile();
}

fn cmdSaveAs(_: *app.AppState) void {
    const btn = gtk.Button.new();
    app.onSaveAsClicked(btn, btn);
}

fn cmdOpenFile(s: *app.AppState) void {
    _ = s;
    // We pass null for buttons since the handler logic doesn't strictly use them other than for unused param
    // But we need a valid pointer to match signature.
    // Ideally we should refactor app logic to separate UI callback from logic.
    // Hack: create a dummy button or cast null if safe.
    // Actually safe because we modified onOpenFileClicked to ignore button arg inside (renamed to btn and used _)
    // But we can't pass null to *gtk.Button in Zig easily without casting.
    // Better: Helper in app.zig that calls logic directly.
    // For now, let's just trigger the click on the headerbar button if we can find it?
    // Or simpler: create a temporary button.
    const btn = gtk.Button.new();
    app.onOpenFileClicked(btn, btn);
}

fn cmdOpenFolder(s: *app.AppState) void {
    _ = s;
    const btn = gtk.Button.new();
    app.onOpenFolderClicked(btn, btn);
}

fn cmdCloseWindow(s: *app.AppState) void {
    s.window.as(gtk.Window).close();
}

fn cmdToggleLineNumbers(s: *app.AppState) void {
    // Need to toggle config and apply.
    // For simplicity, we can't easily modify config struct directly if it's not setup for reactive changes beyond pointer
    // But we can flip the bool and call apply.
    s.config.editor.show_line_numbers = !s.config.editor.show_line_numbers;
    editor.applyConfig(s.config);
}

fn cmdZoomIn(s: *app.AppState) void {
    s.config.editor.font_size += 1;
    editor.applyConfig(s.config);
}

fn cmdZoomOut(s: *app.AppState) void {
    if (s.config.editor.font_size > 6) {
        s.config.editor.font_size -= 1;
        editor.applyConfig(s.config);
    }
}
