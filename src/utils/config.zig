//! Configuration management
//!
//! This module handles loading and saving user configuration:
//! - Editor settings (font, tab size, etc.)
//! - Theme settings
//! - Keybindings
//! - Recent files/projects

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Line number display mode
pub const LineNumberMode = enum {
    absolute,
    relative,
};

/// Editor configuration
pub const EditorConfig = struct {
    font_family: []const u8 = "monospace",
    font_size: u16 = 12,
    tab_width: u8 = 4,
    use_spaces: bool = true,
    show_line_numbers: bool = true,
    line_number_mode: LineNumberMode = .relative,
    highlight_current_line: bool = true,
    word_wrap: bool = false,
    auto_indent: bool = true,
    auto_save: bool = false,
    auto_save_interval_ms: u32 = 30000,
    vim_mode: bool = false,
};

/// Theme configuration
pub const ThemeConfig = struct {
    name: []const u8 = "dark",
    background: u32 = 0x1e1e1e,
    foreground: u32 = 0xd4d4d4,
    selection: u32 = 0x264f78,
    cursor: u32 = 0xffffff,
    line_highlight: u32 = 0x2d2d2d,
    comment: u32 = 0x6a9955,
    keyword: u32 = 0x569cd6,
    special: u32 = 0xc586c0,
    string: u32 = 0xce9178,
    number: u32 = 0xb5cea8,
    type: u32 = 0x4ec9b0,
    function: u32 = 0xdcdcaa,
    variable: u32 = 0xd4d4d4,
    variable_decl: u32 = 0x9cdcfe,
    param: u32 = 0x9cdcfe,
    field: u32 = 0xdcdcaa,
    enum_field: u32 = 0xc586c0,
    field_value: u32 = 0xce9178,

    /// Apply a preset theme by name
    pub fn applyPreset(self: *ThemeConfig, allocator: Allocator, name: []const u8) !void {
        for (theme_presets) |preset| {
            if (std.mem.eql(u8, preset.name, name)) {
                allocator.free(self.name);
                self.name = try allocator.dupe(u8, preset.name);
                self.background = preset.background;
                self.foreground = preset.foreground;
                self.selection = preset.selection;
                self.cursor = preset.cursor;
                self.line_highlight = preset.line_highlight;
                self.comment = preset.comment;
                self.keyword = preset.keyword;
                self.special = preset.special;
                self.string = preset.string;
                self.number = preset.number;
                self.type = preset.type;
                self.function = preset.function;
                self.variable = preset.variable;
                self.variable_decl = preset.variable_decl;
                self.param = preset.param;
                self.field = preset.field;
                self.enum_field = preset.enum_field;
                self.field_value = preset.field_value;
                return;
            }
        }
    }
};

/// Theme preset definition
pub const ThemePreset = struct {
    name: []const u8,
    background: u32,
    foreground: u32,
    selection: u32,
    cursor: u32,
    line_highlight: u32,
    comment: u32,
    keyword: u32,
    special: u32,
    string: u32,
    number: u32,
    type: u32,
    function: u32,
    variable: u32,
    variable_decl: u32,
    param: u32,
    field: u32,
    enum_field: u32,
    field_value: u32,
};

/// Available theme presets
pub const theme_presets = [_]ThemePreset{
    // Dark (VS Code style) - default
    .{
        .name = "dark",
        .background = 0x1e1e1e,
        .foreground = 0xd4d4d4,
        .selection = 0x264f78,
        .cursor = 0xffffff,
        .line_highlight = 0x2d2d2d,
        .comment = 0x6a9955,
        .keyword = 0x569cd6,
        .special = 0xc586c0,
        .string = 0xce9178,
        .number = 0xb5cea8,
        .type = 0x4ec9b0,
        .function = 0xdcdcaa,
        .variable = 0xd4d4d4,
        .variable_decl = 0x9cdcfe,
        .param = 0x9cdcfe,
        .field = 0xdcdcaa,
        .enum_field = 0xc586c0,
        .field_value = 0xce9178,
    },
    // Light
    .{
        .name = "light",
        .background = 0xffffff,
        .foreground = 0x000000,
        .selection = 0xadd6ff,
        .cursor = 0x000000,
        .line_highlight = 0xf0f0f0,
        .comment = 0x008000,
        .keyword = 0x0000ff,
        .special = 0x7a3e9d,
        .string = 0xa31515,
        .number = 0x098658,
        .type = 0x267f99,
        .function = 0x795e26,
        .variable = 0x000000,
        .variable_decl = 0x001080,
        .param = 0x001080,
        .field = 0x795e26,
        .enum_field = 0x7a3e9d,
        .field_value = 0xa31515,
    },
    // Dracula
    .{
        .name = "dracula",
        .background = 0x282a36,
        .foreground = 0xf8f8f2,
        .selection = 0x44475a,
        .cursor = 0xf8f8f2,
        .line_highlight = 0x44475a,
        .comment = 0x6272a4,
        .keyword = 0xff79c6,
        .special = 0xbd93f9,
        .string = 0xf1fa8c,
        .number = 0xbd93f9,
        .type = 0x8be9fd,
        .function = 0x50fa7b,
        .variable = 0xf8f8f2,
        .variable_decl = 0x8be9fd,
        .param = 0x8be9fd,
        .field = 0x50fa7b,
        .enum_field = 0xff79c6,
        .field_value = 0xf1fa8c,
    },
    // Gruvbox Dark
    .{
        .name = "gruvbox",
        .background = 0x282828,
        .foreground = 0xebdbb2,
        .selection = 0x504945,
        .cursor = 0xebdbb2,
        .line_highlight = 0x3c3836,
        .comment = 0x928374,
        .keyword = 0xfb4934,
        .special = 0xd3869b,
        .string = 0xb8bb26,
        .number = 0xd3869b,
        .type = 0x83a598,
        .function = 0xfabd2f,
        .variable = 0xebdbb2,
        .variable_decl = 0x83a598,
        .param = 0x83a598,
        .field = 0xfabd2f,
        .enum_field = 0xd3869b,
        .field_value = 0xb8bb26,
    },
    // Nord
    .{
        .name = "nord",
        .background = 0x2e3440,
        .foreground = 0xd8dee9,
        .selection = 0x434c5e,
        .cursor = 0xd8dee9,
        .line_highlight = 0x3b4252,
        .comment = 0x616e88,
        .keyword = 0x81a1c1,
        .special = 0xb48ead,
        .string = 0xa3be8c,
        .number = 0xb48ead,
        .type = 0x8fbcbb,
        .function = 0x88c0d0,
        .variable = 0xd8dee9,
        .variable_decl = 0x81a1c1,
        .param = 0x81a1c1,
        .field = 0x88c0d0,
        .enum_field = 0xb48ead,
        .field_value = 0xa3be8c,
    },
    // One Dark
    .{
        .name = "one-dark",
        .background = 0x282c34,
        .foreground = 0xabb2bf,
        .selection = 0x3e4451,
        .cursor = 0xabb2bf,
        .line_highlight = 0x2c313c,
        .comment = 0x5c6370,
        .keyword = 0xc678dd,
        .special = 0xd19a66,
        .string = 0x98c379,
        .number = 0xd19a66,
        .type = 0xe5c07b,
        .function = 0x61afef,
        .variable = 0xabb2bf,
        .variable_decl = 0xe06c75,
        .param = 0xe06c75,
        .field = 0x61afef,
        .enum_field = 0xc678dd,
        .field_value = 0x98c379,
    },
};

/// UI configuration
pub const UiConfig = struct {
    file_tree_width: u16 = 250,
    window_width: u16 = 1200,
    window_height: u16 = 800,
    nerd_font_icons: bool = false,
};

/// Application configuration
pub const Config = struct {
    allocator: Allocator,
    editor: EditorConfig,
    theme: ThemeConfig,
    ui: UiConfig,
    recent_files: std.ArrayList([]const u8),
    recent_folders: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator) Config {
        // NOTE: recent_files/recent_folders are initialized as empty structs which works
        // because std.ArrayList methods take allocator as parameter. Ideally should use
        // std.ArrayList(...).init(allocator) for proper initialization.
        var cfg = Config{
            .allocator = allocator,
            .editor = .{},
            .theme = .{},
            .ui = .{},
            .recent_files = .{},
            .recent_folders = .{},
        };
        cfg.editor.font_family = allocator.dupe(u8, cfg.editor.font_family) catch unreachable;
        cfg.theme.name = allocator.dupe(u8, cfg.theme.name) catch unreachable;
        return cfg;
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.editor.font_family);
        self.allocator.free(self.theme.name);
        for (self.recent_files.items) |path| {
            self.allocator.free(path);
        }
        self.recent_files.deinit(self.allocator);

        for (self.recent_folders.items) |path| {
            self.allocator.free(path);
        }
        self.recent_folders.deinit(self.allocator);
    }

    /// Load configuration from file
    pub fn load(self: *Config) !void {
        const config_path = try getConfigPath(self.allocator);
        defer self.allocator.free(config_path);

        ensureExampleTheme(self.allocator) catch {};

        const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try self.save();
                return;
            },
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size == 0) {
            try self.save();
            return;
        }

        const raw = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(raw);

        const cleaned = try stripJsonComments(self.allocator, raw);
        defer self.allocator.free(cleaned);

        const trimmed = std.mem.trim(u8, cleaned, " \t\r\n");
        if (trimmed.len == 0) {
            try self.save();
            return;
        }

        var parsed = std.json.parseFromSlice(ConfigFile, self.allocator, cleaned, .{
            .ignore_unknown_fields = true,
        }) catch {
            try self.save();
            return;
        };
        defer parsed.deinit();

        const theme_colors_set = try applyConfigFile(self, parsed.value);
        try applyThemeByNameInternal(self, self.theme.name, !theme_colors_set);
        normalizeUi(self);
    }

    /// Save configuration to file
    pub fn save(self: *Config) !void {
        normalizeUi(self);
        const config_path = try getConfigPath(self.allocator);
        defer self.allocator.free(config_path);

        // Ensure config directory exists
        if (std.fs.path.dirname(config_path)) |dir| {
            std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        const file = try std.fs.createFileAbsolute(config_path, .{ .truncate = true });
        defer file.close();

        var buffer: [4096]u8 = undefined;
        var writer = file.writer(&buffer);
        try writeConfigJsonc(self, &writer.interface);
        try writer.interface.flush();
    }

    /// Add a file to recent files list
    pub fn addRecentFile(self: *Config, path: []const u8) !void {
        // Remove if already exists
        var i: usize = 0;
        while (i < self.recent_files.items.len) {
            if (std.mem.eql(u8, self.recent_files.items[i], path)) {
                self.allocator.free(self.recent_files.orderedRemove(i));
            } else {
                i += 1;
            }
        }

        // Add to front
        const path_copy = try self.allocator.dupe(u8, path);
        try self.recent_files.insert(self.allocator, 0, path_copy);

        // Limit to 10 recent files
        while (self.recent_files.items.len > 10) {
            self.allocator.free(self.recent_files.pop());
        }
    }

    /// Add a folder to recent folders list
    pub fn addRecentFolder(self: *Config, path: []const u8) !void {
        // Remove if already exists
        var i: usize = 0;
        while (i < self.recent_folders.items.len) {
            if (std.mem.eql(u8, self.recent_folders.items[i], path)) {
                self.allocator.free(self.recent_folders.orderedRemove(i));
            } else {
                i += 1;
            }
        }

        // Add to front
        const path_copy = try self.allocator.dupe(u8, path);
        try self.recent_folders.insert(self.allocator, 0, path_copy);

        // Limit to 10 recent folders
        while (self.recent_folders.items.len > 10) {
            self.allocator.free(self.recent_folders.pop());
        }
    }

    pub fn applyThemeByName(self: *Config, name: []const u8) !void {
        try applyThemeByNameInternal(self, name, true);
    }
};

const ConfigFile = struct {
    editor: ?EditorConfigFile = null,
    theme: ?ThemeConfigFile = null,
    ui: ?UiConfigFile = null,
    recent_files: ?[]const []const u8 = null,
    recent_folders: ?[]const []const u8 = null,
};

const EditorConfigFile = struct {
    font_family: ?[]const u8 = null,
    font_size: ?u16 = null,
    tab_width: ?u8 = null,
    use_spaces: ?bool = null,
    show_line_numbers: ?bool = null,
    line_number_mode: ?[]const u8 = null,
    highlight_current_line: ?bool = null,
    word_wrap: ?bool = null,
    auto_indent: ?bool = null,
    auto_save: ?bool = null,
    auto_save_interval_ms: ?u32 = null,
    vim_mode: ?bool = null,
};

const ThemeConfigFile = struct {
    name: ?[]const u8 = null,
    background: ?[]const u8 = null,
    foreground: ?[]const u8 = null,
    selection: ?[]const u8 = null,
    cursor: ?[]const u8 = null,
    line_highlight: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    keyword: ?[]const u8 = null,
    special: ?[]const u8 = null,
    string: ?[]const u8 = null,
    number: ?[]const u8 = null,
    type: ?[]const u8 = null,
    function: ?[]const u8 = null,
    variable: ?[]const u8 = null,
    variable_decl: ?[]const u8 = null,
    param: ?[]const u8 = null,
    field: ?[]const u8 = null,
    enum_field: ?[]const u8 = null,
    field_value: ?[]const u8 = null,
};

const UiConfigFile = struct {
    file_tree_width: ?u16 = null,
    window_width: ?u16 = null,
    window_height: ?u16 = null,
    nerd_font_icons: ?bool = null,
};

fn applyConfigFile(self: *Config, parsed: ConfigFile) !bool {
    var theme_colors_set = false;

    if (parsed.editor) |e| {
        if (e.font_family) |v| try replaceString(self, &self.editor.font_family, v);
        if (e.font_size) |v| self.editor.font_size = v;
        if (e.tab_width) |v| self.editor.tab_width = v;
        if (e.use_spaces) |v| self.editor.use_spaces = v;
        if (e.show_line_numbers) |v| self.editor.show_line_numbers = v;
        if (e.line_number_mode) |v| {
            if (std.mem.eql(u8, v, "absolute")) {
                self.editor.line_number_mode = .absolute;
            } else if (std.mem.eql(u8, v, "relative")) {
                self.editor.line_number_mode = .relative;
            }
        }
        if (e.highlight_current_line) |v| self.editor.highlight_current_line = v;
        if (e.word_wrap) |v| self.editor.word_wrap = v;
        if (e.auto_indent) |v| self.editor.auto_indent = v;
        if (e.auto_save) |v| self.editor.auto_save = v;
        if (e.auto_save_interval_ms) |v| self.editor.auto_save_interval_ms = v;
        if (e.vim_mode) |v| self.editor.vim_mode = v;
    }

    if (parsed.theme) |t| {
        theme_colors_set = try applyThemeFields(self, t);
    }

    if (parsed.ui) |u| {
        if (u.file_tree_width) |v| self.ui.file_tree_width = v;
        if (u.window_width) |v| self.ui.window_width = v;
        if (u.window_height) |v| self.ui.window_height = v;
        if (u.nerd_font_icons) |v| self.ui.nerd_font_icons = v;
    }

    if (parsed.recent_files) |list| {
        clearStringList(self, &self.recent_files);
        for (list) |path| {
            const path_copy = try self.allocator.dupe(u8, path);
            try self.recent_files.append(self.allocator, path_copy);
        }
    }

    if (parsed.recent_folders) |list| {
        clearStringList(self, &self.recent_folders);
        for (list) |path| {
            const path_copy = try self.allocator.dupe(u8, path);
            try self.recent_folders.append(self.allocator, path_copy);
        }
    }

    return theme_colors_set;
}

fn applyThemeFields(self: *Config, parsed: ThemeConfigFile) !bool {
    var colors_set = false;

    if (parsed.name) |v| try replaceString(self, &self.theme.name, v);
    if (parsed.background) |v| {
        if (parseHexColor(v)) |c| {
            self.theme.background = c;
            colors_set = true;
        }
    }
    if (parsed.foreground) |v| {
        if (parseHexColor(v)) |c| {
            self.theme.foreground = c;
            colors_set = true;
        }
    }
    if (parsed.selection) |v| {
        if (parseHexColor(v)) |c| {
            self.theme.selection = c;
            colors_set = true;
        }
    }
    if (parsed.cursor) |v| {
        if (parseHexColor(v)) |c| {
            self.theme.cursor = c;
            colors_set = true;
        }
    }
    if (parsed.line_highlight) |v| {
        if (parseHexColor(v)) |c| {
            self.theme.line_highlight = c;
            colors_set = true;
        }
    }
    if (parsed.comment) |v| {
        if (parseHexColor(v)) |c| {
            self.theme.comment = c;
            colors_set = true;
        }
    }
    if (parsed.keyword) |v| {
        if (parseHexColor(v)) |c| {
            self.theme.keyword = c;
            colors_set = true;
        }
    }
    if (parsed.special) |v| {
        if (parseHexColor(v)) |c| {
            self.theme.special = c;
            colors_set = true;
        }
    }
    if (parsed.string) |v| {
        if (parseHexColor(v)) |c| {
            self.theme.string = c;
            colors_set = true;
        }
    }
    if (parsed.number) |v| {
        if (parseHexColor(v)) |c| {
            self.theme.number = c;
            colors_set = true;
        }
    }
    if (parsed.type) |v| {
        if (parseHexColor(v)) |c| {
            self.theme.type = c;
            colors_set = true;
        }
    }
    if (parsed.function) |v| {
        if (parseHexColor(v)) |c| {
            self.theme.function = c;
            colors_set = true;
        }
    }
    if (parsed.variable) |v| {
        if (parseHexColor(v)) |c| {
            self.theme.variable = c;
            colors_set = true;
        }
    }
    if (parsed.variable_decl) |v| {
        if (parseHexColor(v)) |c| {
            self.theme.variable_decl = c;
            colors_set = true;
        }
    }
    if (parsed.param) |v| {
        if (parseHexColor(v)) |c| {
            self.theme.param = c;
            colors_set = true;
        }
    }
    if (parsed.field) |v| {
        if (parseHexColor(v)) |c| {
            self.theme.field = c;
            colors_set = true;
        }
    }
    if (parsed.enum_field) |v| {
        if (parseHexColor(v)) |c| {
            self.theme.enum_field = c;
            colors_set = true;
        }
    }
    if (parsed.field_value) |v| {
        if (parseHexColor(v)) |c| {
            self.theme.field_value = c;
            colors_set = true;
        }
    }

    return colors_set;
}

fn applyThemeByNameInternal(self: *Config, name: []const u8, allow_preset: bool) !void {
    try replaceString(self, &self.theme.name, name);
    if (try loadThemeFileByName(self, name)) return;
    if (!allow_preset) return;
    try self.theme.applyPreset(self.allocator, name);
}

fn loadThemeFileByName(self: *Config, name: []const u8) !bool {
    const themes_dir = getThemesDir(self.allocator) catch return false;
    defer self.allocator.free(themes_dir);

    const path = std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ themes_dir, name }) catch return false;
    defer self.allocator.free(path);

    return loadThemeFile(self, path);
}

fn loadThemeFile(self: *Config, path: []const u8) !bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();

    const raw = file.readToEndAlloc(self.allocator, 1024 * 1024) catch return false;
    defer self.allocator.free(raw);

    var parsed = std.json.parseFromSlice(ThemeConfigFile, self.allocator, raw, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();

    _ = try applyThemeFields(self, parsed.value);
    return true;
}

pub fn listThemeNames(allocator: Allocator) !std.ArrayList([]const u8) {
    var names: std.ArrayList([]const u8) = .{};

    for (theme_presets) |preset| {
        const copy = try allocator.dupe(u8, preset.name);
        try names.append(allocator, copy);
    }

    const themes_dir = getThemesDir(allocator) catch return names;
    defer allocator.free(themes_dir);

    var dir = std.fs.openDirAbsolute(themes_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return names,
        error.NotDir => return names,
        else => return err,
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const base = entry.name[0 .. entry.name.len - 5];
        if (containsName(names.items, base)) continue;

        const copy = try allocator.dupe(u8, base);
        try names.append(allocator, copy);
    }

    return names;
}

fn containsName(list: []const []const u8, name: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

fn replaceString(self: *Config, target: *[]const u8, value: []const u8) !void {
    if (target.*.len == value.len and (target.*.ptr == value.ptr or std.mem.eql(u8, target.*, value))) {
        return;
    }
    const duped = try self.allocator.dupe(u8, value);
    self.allocator.free(target.*);
    target.* = duped;
}

fn clearStringList(self: *Config, list: *std.ArrayList([]const u8)) void {
    for (list.items) |path| {
        self.allocator.free(path);
    }
    list.clearRetainingCapacity();
}

fn stripJsonComments(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    var i: usize = 0;
    var in_string = false;
    var in_line_comment = false;
    var in_block_comment = false;
    var escape = false;

    while (i < input.len) : (i += 1) {
        const c = input[i];
        const next = if (i + 1 < input.len) input[i + 1] else 0;

        if (in_line_comment) {
            if (c == '\n') {
                in_line_comment = false;
                try out.append(allocator, c);
            }
            continue;
        }

        if (in_block_comment) {
            if (c == '*' and next == '/') {
                in_block_comment = false;
                i += 1;
            }
            continue;
        }

        if (in_string) {
            try out.append(allocator, c);
            if (escape) {
                escape = false;
                continue;
            }
            if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }

        if (c == '/' and next == '/') {
            in_line_comment = true;
            i += 1;
            continue;
        }
        if (c == '/' and next == '*') {
            in_block_comment = true;
            i += 1;
            continue;
        }

        try out.append(allocator, c);
        if (c == '"') {
            in_string = true;
            escape = false;
        }
    }

    return out.toOwnedSlice(allocator);
}

fn writeConfigJsonc(self: *const Config, writer: anytype) !void {
    try writer.writeAll("{\n");
    try writer.writeAll("  // Editor settings\n");
    try writer.writeAll("  \"editor\": {\n");
    try writer.writeAll("    \"font_family\": ");
    try writeJsonString(writer, self.editor.font_family);
    try writer.writeAll(",\n");
    try writer.print("    \"font_size\": {d},\n", .{self.editor.font_size});
    try writer.print("    \"tab_width\": {d},\n", .{self.editor.tab_width});
    try writer.print("    \"use_spaces\": {s},\n", .{boolString(self.editor.use_spaces)});
    try writer.print("    \"show_line_numbers\": {s},\n", .{boolString(self.editor.show_line_numbers)});
    try writer.print("    \"line_number_mode\": \"{s}\",\n", .{@tagName(self.editor.line_number_mode)});
    try writer.print("    \"highlight_current_line\": {s},\n", .{boolString(self.editor.highlight_current_line)});
    try writer.print("    \"word_wrap\": {s},\n", .{boolString(self.editor.word_wrap)});
    try writer.print("    \"auto_indent\": {s},\n", .{boolString(self.editor.auto_indent)});
    try writer.print("    \"auto_save\": {s},\n", .{boolString(self.editor.auto_save)});
    try writer.print("    \"auto_save_interval_ms\": {d},\n", .{self.editor.auto_save_interval_ms});
    try writer.print("    \"vim_mode\": {s}\n", .{boolString(self.editor.vim_mode)});
    try writer.writeAll("  },\n\n");

    try writer.writeAll("  // Theme settings\n");
    try writer.writeAll("  \"theme\": {\n");
    try writer.writeAll("    \"name\": ");
    try writeJsonString(writer, self.theme.name);
    try writer.writeAll("\n");
    try writer.writeAll("  },\n\n");

    try writer.writeAll("  // UI settings\n");
    try writer.writeAll("  \"ui\": {\n");
    try writer.print("    \"file_tree_width\": {d},\n", .{self.ui.file_tree_width});
    try writer.print("    \"window_width\": {d},\n", .{self.ui.window_width});
    try writer.print("    \"window_height\": {d},\n", .{self.ui.window_height});
    try writer.print("    \"nerd_font_icons\": {s}\n", .{boolString(self.ui.nerd_font_icons)});
    try writer.writeAll("  },\n\n");

    try writer.writeAll("  \"recent_files\": ");
    try writeStringArray(writer, self.recent_files.items);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"recent_folders\": ");
    try writeStringArray(writer, self.recent_folders.items);
    try writer.writeAll("\n");
    try writer.writeAll("}\n");
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeStringArray(writer: anytype, values: []const []const u8) !void {
    try writer.writeAll("[");
    for (values, 0..) |value, i| {
        if (i != 0) try writer.writeAll(", ");
        try writeJsonString(writer, value);
    }
    try writer.writeAll("]");
}

fn writeColor(writer: anytype, name: []const u8, color: u32, trailing_comma: bool) !void {
    var buf: [8]u8 = undefined;
    const hex = std.fmt.bufPrint(&buf, "{X:0>6}", .{color}) catch "000000";
    try writer.writeAll("    \"");
    try writer.writeAll(name);
    try writer.writeAll("\": \"#");
    try writer.writeAll(hex);
    if (trailing_comma) {
        try writer.writeAll("\",\n");
    } else {
        try writer.writeAll("\"\n");
    }
}

fn boolString(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn normalizeUi(self: *Config) void {
    const min_tree_width: u16 = 140;
    const min_window_width: u16 = 640;
    const min_window_height: u16 = 480;

    if (self.ui.file_tree_width < min_tree_width) self.ui.file_tree_width = min_tree_width;
    if (self.ui.window_width < min_window_width) self.ui.window_width = min_window_width;
    if (self.ui.window_height < min_window_height) self.ui.window_height = min_window_height;
}

fn parseHexColor(value: []const u8) ?u32 {
    if (value.len == 0) return null;
    var s = value;
    if (s[0] == '#') s = s[1..];
    if (s.len != 6) return null;
    return std.fmt.parseUnsigned(u32, s, 16) catch null;
}

/// Get the configuration file path
pub fn getConfigPath(allocator: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |config_home| {
        defer allocator.free(config_home);
        return std.fmt.allocPrint(allocator, "{s}/zinc/config.json", .{config_home});
    } else |_| {
        if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
            defer allocator.free(home);
            return std.fmt.allocPrint(allocator, "{s}/.config/zinc/config.json", .{home});
        } else |_| {
            return error.NoHomeDirectory;
        }
    }
}

/// Get the themes directory path
pub fn getThemesDir(allocator: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |config_home| {
        defer allocator.free(config_home);
        return std.fmt.allocPrint(allocator, "{s}/zinc/themes", .{config_home});
    } else |_| {
        if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
            defer allocator.free(home);
            return std.fmt.allocPrint(allocator, "{s}/.config/zinc/themes", .{home});
        } else |_| {
            return error.NoHomeDirectory;
        }
    }
}

fn ensureExampleTheme(allocator: Allocator) !void {
    const themes_dir = try getThemesDir(allocator);
    defer allocator.free(themes_dir);

    std.fs.makeDirAbsolute(themes_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const example_path = try std.fmt.allocPrint(allocator, "{s}/example.json", .{themes_dir});
    defer allocator.free(example_path);

    const existing = std.fs.openFileAbsolute(example_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |file| {
        file.close();
        return;
    }

    const example_json =
        \\{
        \\  "name": "example",
        \\  "background": "#1e1e1e",
        \\  "foreground": "#d4d4d4",
        \\  "selection": "#264f78",
        \\  "cursor": "#ffffff",
        \\  "line_highlight": "#2d2d2d",
        \\  "comment": "#6a9955",
        \\  "keyword": "#569cd6",
        \\  "special": "#c586c0",
        \\  "string": "#ce9178",
        \\  "number": "#b5cea8",
        \\  "type": "#4ec9b0",
        \\  "function": "#dcdcaa",
        \\  "variable": "#d4d4d4",
        \\  "variable_decl": "#9cdcfe",
        \\  "param": "#9cdcfe",
        \\  "field": "#dcdcaa",
        \\  "enum_field": "#c586c0",
        \\  "field_value": "#ce9178"
        \\}
        \\
    ;

    const file = try std.fs.createFileAbsolute(example_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(example_json);
}

/// Get the data directory path
pub fn getDataPath(allocator: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_DATA_HOME")) |data_home| {
        defer allocator.free(data_home);
        return std.fmt.allocPrint(allocator, "{s}/zinc", .{data_home});
    } else |_| {
        if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
            defer allocator.free(home);
            return std.fmt.allocPrint(allocator, "{s}/.local/share/zinc", .{home});
        } else |_| {
            return error.NoHomeDirectory;
        }
    }
}
