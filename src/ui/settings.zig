const std = @import("std");
const gtk = @import("gtk");
const glib = @import("glib");
const gobject = @import("gobject");

const config = @import("../utils/config.zig");

const Allocator = std.mem.Allocator;

pub const ApplyFn = *const fn (ctx: ?*anyopaque, cfg: *config.Config) void;

const FieldKind = enum {
    boolean,
    int_u8,
    int_u16,
    int_u32,
    string,
    color,
    string_list,
    line_number_mode,
    theme_preset,
};

const FieldMeta = struct {
    path: []const u8,
    label: []const u8,
    kind: ?FieldKind = null,
    min: ?i64 = null,
    max: ?i64 = null,
    step: ?i64 = null,
};

const Binding = struct {
    widget: *anyopaque,
    target: *anyopaque,
    kind: FieldKind,
};

const SettingsState = struct {
    allocator: Allocator,
    window: *gtk.ApplicationWindow,
    cfg: *config.Config,
    bindings: std.ArrayList(Binding),
    theme_names: std.ArrayList([]const u8),
    apply_fn: ApplyFn,
    apply_ctx: ?*anyopaque,

    pub fn deinit(self: *SettingsState) void {
        self.bindings.deinit(self.allocator);
        for (self.theme_names.items) |name| {
            self.allocator.free(name);
        }
        self.theme_names.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

pub fn show(parent: *gtk.ApplicationWindow, cfg: *config.Config, apply_fn: ApplyFn, ctx: ?*anyopaque) void {
    const app = parent.as(gtk.Window).getApplication() orelse return;
    const allocator = cfg.allocator;

    const state = allocator.create(SettingsState) catch return;
    state.* = .{
        .allocator = allocator,
        .window = gtk.ApplicationWindow.new(app),
        .cfg = cfg,
        .bindings = .{},
        .theme_names = .{},
        .apply_fn = apply_fn,
        .apply_ctx = ctx,
    };

    const window = state.window;
    window.as(gtk.Window).setTitle("Settings");
    window.as(gtk.Window).setDefaultSize(720, 640);
    window.as(gtk.Window).setTransientFor(parent.as(gtk.Window));
    window.as(gtk.Window).setModal(1);

    const root = gtk.Box.new(gtk.Orientation.vertical, 12);
    root.as(gtk.Widget).setMarginStart(12);
    root.as(gtk.Widget).setMarginEnd(12);
    root.as(gtk.Widget).setMarginTop(12);
    root.as(gtk.Widget).setMarginBottom(12);

    const scroll = gtk.ScrolledWindow.new();
    scroll.setPolicy(gtk.PolicyType.never, gtk.PolicyType.automatic);
    scroll.as(gtk.Widget).setVexpand(1);
    scroll.as(gtk.Widget).setHexpand(1);

    const content = gtk.Box.new(gtk.Orientation.vertical, 16);
    scroll.setChild(content.as(gtk.Widget));

    addStructSection("Editor", "editor", &cfg.editor, allocator, content, &state.bindings) catch {
        state.deinit();
        return;
    };
    addThemePresetSelector(state, content) catch {
        state.deinit();
        return;
    };
    addStructSection("UI", "ui", &cfg.ui, allocator, content, &state.bindings) catch {
        state.deinit();
        return;
    };

    addStringListField("Recent files", "recent_files", &cfg.recent_files, allocator, content, &state.bindings) catch {
        state.deinit();
        return;
    };
    addStringListField("Recent folders", "recent_folders", &cfg.recent_folders, allocator, content, &state.bindings) catch {
        state.deinit();
        return;
    };

    root.append(scroll.as(gtk.Widget));

    const buttons = gtk.Box.new(gtk.Orientation.horizontal, 8);
    buttons.as(gtk.Widget).setHalign(gtk.Align.end);

    const apply_btn = gtk.Button.newWithLabel("Apply");
    const close_btn = gtk.Button.newWithLabel("Close");
    buttons.append(close_btn.as(gtk.Widget));
    buttons.append(apply_btn.as(gtk.Widget));

    root.append(buttons.as(gtk.Widget));

    window.as(gtk.Window).setChild(root.as(gtk.Widget));

    _ = gtk.Button.signals.clicked.connect(apply_btn, *SettingsState, &onApplyClicked, state, .{});
    _ = gtk.Button.signals.clicked.connect(close_btn, *SettingsState, &onCloseClicked, state, .{});
    _ = gtk.Window.signals.close_request.connect(window.as(gtk.Window), *SettingsState, &onWindowClose, state, .{});

    window.as(gtk.Widget).setVisible(1);
}

fn onApplyClicked(_: *gtk.Button, state: *SettingsState) callconv(.c) void {
    applyBindings(state);
    state.cfg.save() catch |err| {
        std.debug.print("Failed to save config: {}\n", .{err});
    };
    state.apply_fn(state.apply_ctx, state.cfg);
}

fn onCloseClicked(_: *gtk.Button, state: *SettingsState) callconv(.c) void {
    state.window.as(gtk.Window).close();
}

fn onWindowClose(_: *gtk.Window, state: *SettingsState) callconv(.c) c_int {
    state.deinit();
    return 0;
}

fn applyBindings(state: *SettingsState) void {
    // Apply theme selection first.
    for (state.bindings.items) |binding| {
        if (binding.kind == .theme_preset) {
            applyThemePreset(binding, state);
        }
    }
    // Then apply other bindings (individual colors can still override preset)
    for (state.bindings.items) |binding| {
        switch (binding.kind) {
            .boolean => applyBool(binding),
            .int_u8 => applyIntU8(binding),
            .int_u16 => applyIntU16(binding),
            .int_u32 => applyIntU32(binding),
            .string => applyString(binding, state.cfg),
            .color => applyColor(binding),
            .string_list => applyStringList(binding, state.cfg),
            .line_number_mode => applyLineNumberMode(binding),
            .theme_preset => {}, // Already handled above
        }
    }
}

fn applyBool(binding: Binding) void {
    const sw: *gtk.Switch = castBinding(*gtk.Switch, binding.widget);
    const target: *bool = castBinding(*bool, binding.target);
    target.* = sw.getActive() != 0;
}

fn applyIntU8(binding: Binding) void {
    const spin: *gtk.SpinButton = castBinding(*gtk.SpinButton, binding.widget);
    const target: *u8 = castBinding(*u8, binding.target);
    const value: c_int = spin.getValueAsInt();
    target.* = @intCast(@max(value, 0));
}

fn applyIntU16(binding: Binding) void {
    const spin: *gtk.SpinButton = castBinding(*gtk.SpinButton, binding.widget);
    const target: *u16 = castBinding(*u16, binding.target);
    const value: c_int = spin.getValueAsInt();
    target.* = @intCast(@max(value, 0));
}

fn applyIntU32(binding: Binding) void {
    const spin: *gtk.SpinButton = castBinding(*gtk.SpinButton, binding.widget);
    const target: *u32 = castBinding(*u32, binding.target);
    const value: c_int = spin.getValueAsInt();
    target.* = @intCast(@max(value, 0));
}

fn applyString(binding: Binding, cfg: *config.Config) void {
    const entry: *gtk.Entry = castBinding(*gtk.Entry, binding.widget);
    const target: *[]const u8 = castBinding(*[]const u8, binding.target);
    const text_ptr = entry.as(gtk.Editable).getText();
    const text = std.mem.span(text_ptr);
    const duped = cfg.allocator.dupe(u8, text) catch return;
    cfg.allocator.free(target.*);
    target.* = duped;
}

fn applyColor(binding: Binding) void {
    const entry: *gtk.Entry = castBinding(*gtk.Entry, binding.widget);
    const target: *u32 = castBinding(*u32, binding.target);
    const text_ptr = entry.as(gtk.Editable).getText();
    const text = std.mem.span(text_ptr);
    if (parseHexColor(text)) |value| target.* = value;
}

fn applyLineNumberMode(binding: Binding) void {
    const combo: *gtk.ComboBoxText = castBinding(*gtk.ComboBoxText, binding.widget);
    const target: *config.LineNumberMode = castBinding(*config.LineNumberMode, binding.target);
    const active = combo.as(gtk.ComboBox).getActive();
    target.* = if (active == 0) .absolute else .relative;
}

fn applyThemePreset(binding: Binding, state: *SettingsState) void {
    const combo: *gtk.ComboBoxText = castBinding(*gtk.ComboBoxText, binding.widget);
    const active = combo.as(gtk.ComboBox).getActive();
    if (active < 0) return;

    const index: usize = @intCast(active);
    if (index < state.theme_names.items.len) {
        const name = state.theme_names.items[index];
        state.cfg.applyThemeByName(name) catch return;
    }
}

fn applyStringList(binding: Binding, cfg: *config.Config) void {
    const buffer: *gtk.TextBuffer = castBinding(*gtk.TextBuffer, binding.widget);
    const target: *std.ArrayList([]const u8) = castBinding(*std.ArrayList([]const u8), binding.target);

    var start: gtk.TextIter = undefined;
    var end: gtk.TextIter = undefined;
    buffer.getBounds(&start, &end);
    const text_ptr = buffer.getText(&start, &end, 0);
    const text = std.mem.span(text_ptr);
    defer glib.free(text_ptr);

    clearStringList(cfg, target);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const copy = cfg.allocator.dupe(u8, trimmed) catch continue;
        target.append(cfg.allocator, copy) catch {
            cfg.allocator.free(copy);
            return;
        };
    }
}

fn addStructSection(
    comptime title: []const u8,
    comptime path_prefix: []const u8,
    struct_ptr: anytype,
    allocator: Allocator,
    parent: *gtk.Box,
    bindings: *std.ArrayList(Binding),
) !void {
    const frame = makeFrame(allocator, title);
    const grid = gtk.Grid.new();
    grid.setRowSpacing(8);
    grid.setColumnSpacing(12);
    grid.as(gtk.Widget).setMarginStart(12);
    grid.as(gtk.Widget).setMarginEnd(12);
    grid.as(gtk.Widget).setMarginTop(12);
    grid.as(gtk.Widget).setMarginBottom(12);
    frame.setChild(grid.as(gtk.Widget));
    parent.append(frame.as(gtk.Widget));

    const T = @TypeOf(struct_ptr.*);
    const fields = @typeInfo(T).@"struct".fields;
    var row: c_int = 0;

    inline for (fields) |field| {
        const field_path = path_prefix ++ "." ++ field.name;
        const meta = getFieldMeta(field_path);
    const label_text = meta.label;
        const field_ptr = &@field(struct_ptr.*, field.name);

        const label = makeLabel(allocator, label_text);
        label.as(gtk.Widget).setHalign(gtk.Align.start);
        label.as(gtk.Widget).setValign(gtk.Align.center);
        grid.attach(label.as(gtk.Widget), 0, row, 1, 1);

        try addFieldWidget(field_path, field.type, field_ptr, allocator, grid, row, bindings);
        row += 1;
    }
}

fn addFieldWidget(
    field_path: []const u8,
    comptime field_type: type,
    field_ptr: anytype,
    allocator: Allocator,
    grid: *gtk.Grid,
    row: c_int,
    bindings: *std.ArrayList(Binding),
) !void {
    if (field_type == bool) {
        const sw = gtk.Switch.new();
        sw.setActive(if (field_ptr.*) 1 else 0);
        sw.as(gtk.Widget).setHalign(gtk.Align.start);
        grid.attach(sw.as(gtk.Widget), 1, row, 1, 1);
        try bindings.append(allocator, .{
            .widget = @ptrCast(sw),
            .target = @ptrCast(field_ptr),
            .kind = .boolean,
        });
        return;
    }

    if (field_type == []const u8) {
        const entry = gtk.Entry.new();
        setEntryText(allocator, entry, field_ptr.*);
        entry.as(gtk.Widget).setHexpand(1);
        grid.attach(entry.as(gtk.Widget), 1, row, 1, 1);
        try bindings.append(allocator, .{
            .widget = @ptrCast(entry),
            .target = @ptrCast(field_ptr),
            .kind = .string,
        });
        return;
    }

    const meta = getFieldMeta(field_path);

    if (field_type == config.LineNumberMode) {
        const combo = gtk.ComboBoxText.new();
        combo.appendText("Absolute");
        combo.appendText("Relative");
        combo.as(gtk.ComboBox).setActive(if (field_ptr.* == .absolute) 0 else 1);
        combo.as(gtk.Widget).setHexpand(1);
        grid.attach(combo.as(gtk.Widget), 1, row, 1, 1);
        try bindings.append(allocator, .{
            .widget = @ptrCast(combo),
            .target = @ptrCast(field_ptr),
            .kind = .line_number_mode,
        });
        return;
    }

    if (field_type == u32 and meta.kind == .color) {
        const entry = gtk.Entry.new();
        var buf: [9]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "#{X:0>6}", .{field_ptr.*}) catch "#000000";
        setEntryText(allocator, entry, text);
        entry.setPlaceholderText("#RRGGBB");
        entry.as(gtk.Widget).setHexpand(1);
        grid.attach(entry.as(gtk.Widget), 1, row, 1, 1);
        try bindings.append(allocator, .{
            .widget = @ptrCast(entry),
            .target = @ptrCast(field_ptr),
            .kind = .color,
        });
        return;
    }

    if (field_type == u8 or field_type == u16 or field_type == u32) {
        const min: f64 = @floatFromInt(meta.min orelse 0);
        const max: f64 = @floatFromInt(meta.max orelse 1_000_000);
        const step: f64 = @floatFromInt(meta.step orelse 1);
        const spin = gtk.SpinButton.newWithRange(min, max, step);
        spin.setValue(@floatFromInt(field_ptr.*));
        spin.as(gtk.Widget).setHexpand(1);
        grid.attach(spin.as(gtk.Widget), 1, row, 1, 1);
        try bindings.append(allocator, .{
            .widget = @ptrCast(spin),
            .target = @ptrCast(field_ptr),
            .kind = switch (field_type) {
                u8 => .int_u8,
                u16 => .int_u16,
                u32 => .int_u32,
                else => .int_u32,
            },
        });
        return;
    }
}

fn addThemePresetSelector(
    state: *SettingsState,
    parent: *gtk.Box,
) !void {
    const allocator = state.allocator;
    const cfg = state.cfg;

    const frame = makeFrame(allocator, "Theme");
    const box = gtk.Box.new(gtk.Orientation.horizontal, 12);
    box.as(gtk.Widget).setMarginStart(12);
    box.as(gtk.Widget).setMarginEnd(12);
    box.as(gtk.Widget).setMarginTop(12);
    box.as(gtk.Widget).setMarginBottom(12);
    frame.setChild(box.as(gtk.Widget));
    parent.append(frame.as(gtk.Widget));

    const label = makeLabel(allocator, "Select theme");
    label.as(gtk.Widget).setHalign(gtk.Align.start);
    box.append(label.as(gtk.Widget));

    const combo = gtk.ComboBoxText.new();
    combo.as(gtk.Widget).setHexpand(1);

    state.theme_names = try config.listThemeNames(allocator);

    // Add all themes (built-in + user)
    var current_index: c_int = 0;
    for (state.theme_names.items, 0..) |name, i| {
        const name_z = allocator.dupeZ(u8, name) catch continue;
        defer allocator.free(name_z);
        combo.appendText(name_z.ptr);
        if (std.mem.eql(u8, name, cfg.theme.name)) {
            current_index = @intCast(i);
        }
    }
    combo.as(gtk.ComboBox).setActive(current_index);
    box.append(combo.as(gtk.Widget));

    // Connect changed signal to immediately apply the theme
    _ = gtk.ComboBox.signals.changed.connect(
        combo.as(gtk.ComboBox),
        *SettingsState,
        &onThemePresetChanged,
        state,
        .{},
    );

    try state.bindings.append(allocator, .{
        .widget = @ptrCast(combo),
        .target = @ptrCast(state),
        .kind = .theme_preset,
    });
}

fn onThemePresetChanged(combo: *gtk.ComboBox, state: *SettingsState) callconv(.c) void {
    const active = combo.getActive();
    if (active < 0) return;

    const index: usize = @intCast(active);
    if (index < state.theme_names.items.len) {
        const name = state.theme_names.items[index];
        state.cfg.applyThemeByName(name) catch return;
    }
}

fn addStringListField(
    comptime title: []const u8,
    comptime field_path: []const u8,
    list: *std.ArrayList([]const u8),
    allocator: Allocator,
    parent: *gtk.Box,
    bindings: *std.ArrayList(Binding),
) !void {
    const frame = makeFrame(allocator, title);
    const box = gtk.Box.new(gtk.Orientation.vertical, 6);
    box.as(gtk.Widget).setMarginStart(12);
    box.as(gtk.Widget).setMarginEnd(12);
    box.as(gtk.Widget).setMarginTop(12);
    box.as(gtk.Widget).setMarginBottom(12);
    frame.setChild(box.as(gtk.Widget));
    parent.append(frame.as(gtk.Widget));

    const text_view = gtk.TextView.new();
    text_view.setMonospace(1);
    text_view.as(gtk.Widget).setVexpand(1);
    text_view.as(gtk.Widget).setHexpand(1);

    const scroll = gtk.ScrolledWindow.new();
    scroll.setPolicy(gtk.PolicyType.never, gtk.PolicyType.automatic);
    scroll.setMinContentHeight(100);
    scroll.setChild(text_view.as(gtk.Widget));
    box.append(scroll.as(gtk.Widget));

    const buffer = text_view.getBuffer();
    var list_text: std.ArrayList(u8) = .{};
    defer list_text.deinit(allocator);
    for (list.items, 0..) |item, i| {
        if (i != 0) list_text.append(allocator, '\n') catch break;
        list_text.appendSlice(allocator, item) catch break;
    }
    if (list_text.items.len > 0) {
        const z = allocator.dupeZ(u8, list_text.items) catch null;
        if (z) |text_z| {
            defer allocator.free(text_z);
            buffer.setText(text_z.ptr, -1);
        }
    }

    _ = field_path;
    try bindings.append(allocator, .{
        .widget = @ptrCast(buffer),
        .target = @ptrCast(list),
        .kind = .string_list,
    });
}

fn makeLabel(allocator: Allocator, text: []const u8) *gtk.Label {
    const z = allocator.dupeZ(u8, text) catch return gtk.Label.new(null);
    defer allocator.free(z);
    return gtk.Label.new(z.ptr);
}

fn makeFrame(allocator: Allocator, title: []const u8) *gtk.Frame {
    const z = allocator.dupeZ(u8, title) catch return gtk.Frame.new(null);
    defer allocator.free(z);
    return gtk.Frame.new(z.ptr);
}

fn parseHexColor(value: []const u8) ?u32 {
    if (value.len == 0) return null;
    var s = value;
    if (s[0] == '#') s = s[1..];
    if (s.len != 6) return null;
    return std.fmt.parseUnsigned(u32, s, 16) catch null;
}

fn setEntryText(allocator: Allocator, entry: *gtk.Entry, text: []const u8) void {
    const z = allocator.dupeZ(u8, text) catch return;
    defer allocator.free(z);
    entry.as(gtk.Editable).setText(z.ptr);
}

fn castBinding(comptime T: type, ptr: *anyopaque) T {
    return @ptrCast(@alignCast(ptr));
}

fn clearStringList(cfg: *config.Config, list: *std.ArrayList([]const u8)) void {
    for (list.items) |path| {
        cfg.allocator.free(path);
    }
    list.clearRetainingCapacity();
}

fn getFieldMeta(path: []const u8) FieldMeta {
    for (field_meta) |meta| {
        if (std.mem.eql(u8, meta.path, path)) return meta;
    }
    return .{ .path = path, .label = defaultLabel(path) };
}

fn defaultLabel(path: []const u8) []const u8 {
    const name = if (std.mem.lastIndexOfScalar(u8, path, '.')) |idx| path[idx + 1 ..] else path;
    return switch (name.len) {
        0 => "Field",
        else => name,
    };
}

const field_meta = [_]FieldMeta{
    .{ .path = "editor.font_family", .label = "Font family", .kind = .string },
    .{ .path = "editor.font_size", .label = "Font size", .kind = .int_u16, .min = 8, .max = 36, .step = 1 },
    .{ .path = "editor.tab_width", .label = "Tab width", .kind = .int_u8, .min = 1, .max = 8, .step = 1 },
    .{ .path = "editor.use_spaces", .label = "Use spaces", .kind = .boolean },
    .{ .path = "editor.show_line_numbers", .label = "Show line numbers", .kind = .boolean },
    .{ .path = "editor.line_number_mode", .label = "Line number mode", .kind = .line_number_mode },
    .{ .path = "editor.highlight_current_line", .label = "Highlight current line", .kind = .boolean },
    .{ .path = "editor.word_wrap", .label = "Word wrap", .kind = .boolean },
    .{ .path = "editor.auto_indent", .label = "Auto indent", .kind = .boolean },
    .{ .path = "editor.auto_save", .label = "Auto save", .kind = .boolean },
    .{ .path = "editor.auto_save_interval_ms", .label = "Auto save interval (ms)", .kind = .int_u32, .min = 1000, .max = 600000, .step = 1000 },
    .{ .path = "editor.vim_mode", .label = "Vim mode", .kind = .boolean },

    .{ .path = "theme.name", .label = "Theme name", .kind = .string },
    .{ .path = "theme.background", .label = "Background", .kind = .color },
    .{ .path = "theme.foreground", .label = "Foreground", .kind = .color },
    .{ .path = "theme.selection", .label = "Selection", .kind = .color },
    .{ .path = "theme.cursor", .label = "Cursor", .kind = .color },
    .{ .path = "theme.line_highlight", .label = "Line highlight", .kind = .color },
    .{ .path = "theme.comment", .label = "Comment", .kind = .color },
    .{ .path = "theme.keyword", .label = "Keyword", .kind = .color },
    .{ .path = "theme.string", .label = "String", .kind = .color },
    .{ .path = "theme.number", .label = "Number", .kind = .color },
    .{ .path = "theme.type", .label = "Type", .kind = .color },
    .{ .path = "theme.function", .label = "Function", .kind = .color },
    .{ .path = "theme.variable", .label = "Variable", .kind = .color },

    .{ .path = "ui.file_tree_width", .label = "File tree width", .kind = .int_u16, .min = 140, .max = 400, .step = 10 },
    .{ .path = "ui.window_width", .label = "Window width", .kind = .int_u16, .min = 640, .max = 3840, .step = 10 },
    .{ .path = "ui.window_height", .label = "Window height", .kind = .int_u16, .min = 480, .max = 2160, .step = 10 },
    .{ .path = "ui.nerd_font_icons", .label = "Nerd font icons", .kind = .boolean },

    .{ .path = "recent_files", .label = "Recent files", .kind = .string_list },
    .{ .path = "recent_folders", .label = "Recent folders", .kind = .string_list },
};
