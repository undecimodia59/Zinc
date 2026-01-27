# Zinc

A lightweight, fast text editor with IDE features. Built with Zig and GTK4.

Inspired by Atom, Sublime Text, and Vim.

## Features

- **Fast startup** - Native performance with minimal resource usage
- **Vim mode** - Modal editing with Normal, Insert, Visual, and Command modes
- **File tree** - Navigate your project with a sidebar file browser
- **Theming** - 6 built-in themes + custom theme support
- **Configurable** - JSON configuration with sensible defaults
- **Modern UI** - Clean GTK4 interface with current line highlighting

## Building

### Prerequisites

- Zig 0.14.0 or later
- GTK4 development libraries

On Fedora:
```bash
sudo dnf install gtk4-devel
```

On Ubuntu/Debian:
```bash
sudo apt install libgtk-4-dev
```

On Arch:
```bash
sudo pacman -S gtk4
```

### Build

```bash
zig build
```

### Run

```bash
zig build run
```

Or run the binary directly:
```bash
./zig-out/bin/zinc
```

## Install

The easiest way is to use the provided install script:

```bash
./install.sh
```

If needed:
```bash
chmod +x install.sh
```

By default this installs to `~/.local`:

- Binary: `~/.local/bin/zinc`
- Desktop entry: `~/.local/share/applications/zinc.desktop`
- Icon: `~/.local/share/icons/hicolor/256x256/apps/zinc.png`

You can customize the prefix:

```bash
ZINC_PREFIX="$HOME/.local" ./install.sh
```

Make sure `~/.local/bin` (or your chosen prefix bin dir) is on your `PATH` to run `zinc` from the shell.

Alternatively, you can use Zig’s install step:

```bash
zig build install --prefix "$HOME/.local"
```

## Usage

### Opening Files

- Click a file in the file tree sidebar or scroll with arrows and click enter
- Use `:e <path>` in Vim command mode

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `Ctrl+S` | Save file |
| `Ctrl+O` | Open file |
| `Ctrl+,` | Open settings |
| `Ctrl+=` | Increase font size |
| `Ctrl+-` | Decrease font size |
| `Ctrl+Z` | Undo |
| `Ctrl+Shift+Z` | Redo |

## Vim Mode

Vim mode is disabled by default. Enable it in settings or set `"vim_mode": true` in config.

### Normal Mode

#### Movement

| Key | Action |
|-----|--------|
| `h`, `Left` | Move left |
| `j`, `Down` | Move down |
| `k`, `Up` | Move up |
| `l`, `Right` | Move right |
| `w` | Move to next word start |
| `b` | Move to previous word start |
| `e` | Move to end of word |
| `0` | Move to line start |
| `^` | Move to first non-blank character |
| `$` | Move to line end |
| `gg` | Move to file start |
| `G` | Move to file end |
| `[n]G` | Go to line n |
| `%` | Jump to matching bracket `()[]{}` or quote `"'` |
| `f{char}` | Find character forward on line |
| `F{char}` | Find character backward on line |
| `t{char}` | Till character forward (stop before) |
| `T{char}` | Till character backward (stop after) |
| `;` | Repeat last `f`/`F`/`t`/`T` |
| `,` | Repeat last `f`/`F`/`t`/`T` in opposite direction |

#### Search

| Key | Action |
|-----|--------|
| `/` | Search forward |
| `?` | Search backward |
| `n` | Next search result |
| `N` | Previous search result |
| `*` | Search word under cursor forward |
| `#` | Search word under cursor backward |

#### Mode Switching

| Key | Action |
|-----|--------|
| `i` | Enter Insert mode |
| `a` | Enter Insert mode after cursor |
| `A` | Enter Insert mode at line end |
| `o` | Open line below, enter Insert |
| `O` | Open line above, enter Insert |
| `v` | Enter Visual mode |
| `V` | Enter Visual Line mode |
| `:` | Enter Command mode |

#### Operators

| Key | Action |
|-----|--------|
| `d` | Delete (with motion) |
| `dd` | Delete entire line |
| `y` | Yank (copy) |
| `yy` | Yank entire line |
| `c` | Change (delete + insert) |
| `cc` | Change entire line |
| `p` | Paste after cursor |
| `P` | Paste before cursor |
| `x` | Delete character under cursor |

#### Other

| Key | Action |
|-----|--------|
| `[count]` | Repeat next motion/operator |
| `Escape` | Cancel pending operator |

### Visual Mode

| Key | Action |
|-----|--------|
| `h`, `j`, `k`, `l` | Extend selection |
| `w`, `b` | Extend selection by word |
| `0`, `$` | Extend to line start/end |
| `G`, `gg` | Extend to file end/start |
| `d` | Delete selection |
| `y` | Yank selection |
| `c` | Change selection |
| `Escape` | Return to Normal mode |

### Command Mode

| Command | Action |
|---------|--------|
| `:w` | Save file |
| `:q` | Quit |
| `:wq` | Save and quit |
| `:q!` | Force quit (discard changes) |
| `:e <file>` | Open file |
| `:!<cmd>` | Run shell command (output in popup) |

---

## Configuration

Configuration is stored in `~/.config/zinc/config.json` (or `$XDG_CONFIG_HOME/zinc/config.json`).

The config file supports JSON with comments (JSONC).

### Example Configuration

```json
{
  // Editor settings
  "editor": {
    "font_family": "JetBrains Mono",
    "font_size": 14,
    "tab_width": 4,
    "use_spaces": true,
    "show_line_numbers": true,
    "line_number_mode": "relative",
    "highlight_current_line": true,
    "word_wrap": false,
    "auto_indent": true,
    "auto_save": false,
    "auto_save_interval_ms": 30000,
    "vim_mode": false
  },

  // Theme settings
  "theme": {
    "name": "dracula"
  },

  // UI settings
  "ui": {
    "file_tree_width": 250,
    "window_width": 1200,
    "window_height": 800,
    "nerd_font_icons": false
  }
}
```

### Editor Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `font_family` | string | `"monospace"` | Font family for the editor |
| `font_size` | number | `12` | Font size in points |
| `tab_width` | number | `4` | Number of spaces per tab |
| `use_spaces` | boolean | `true` | Insert spaces instead of tabs |
| `show_line_numbers` | boolean | `true` | Show line number gutter |
| `line_number_mode` | string | `"relative"` | `"absolute"` or `"relative"` |
| `highlight_current_line` | boolean | `true` | Highlight the current line |
| `word_wrap` | boolean | `false` | Wrap long lines |
| `auto_indent` | boolean | `true` | Auto-indent on Enter |
| `auto_save` | boolean | `false` | Auto-save files periodically |
| `auto_save_interval_ms` | number | `30000` | Auto-save interval in milliseconds |
| `vim_mode` | boolean | `false` | Enable Vim keybindings |

### UI Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `file_tree_width` | number | `250` | Width of file tree sidebar (min: 140) |
| `window_width` | number | `1200` | Initial window width (min: 640) |
| `window_height` | number | `800` | Initial window height (min: 480) |
| `nerd_font_icons` | boolean | `false` | Use Nerd Font icons in file tree |

---

## Themes

Zinc includes 6 built-in themes:

| Theme | Description |
|-------|-------------|
| `dark` | VS Code-style dark theme (default) |
| `light` | Clean light theme |
| `dracula` | Popular purple-based dark theme |
| `gruvbox` | Retro groove color scheme |
| `nord` | Arctic, bluish color palette |
| `one-dark` | Atom One Dark inspired theme |

### Switching Themes

Set the theme name in your config:

```json
{
  "theme": {
    "name": "dracula"
  }
}
```

Or use the settings UI (`Ctrl+,`).

### Custom Themes

Create custom themes by adding JSON files to `~/.config/zinc/themes/`.

Example `~/.config/zinc/themes/mytheme.json`:

```json
{
  "name": "mytheme",
  "background": "#1a1a2e",
  "foreground": "#eaeaea",
  "selection": "#4a4a6a",
  "cursor": "#ffffff",
  "line_highlight": "#252540",
  "comment": "#6c6c8a",
  "keyword": "#e94560",
  "special": "#9b59b6",
  "string": "#0f9d58",
  "number": "#f39c12",
  "type": "#3498db",
  "function": "#9b59b6",
  "variable": "#1abc9c",
  "variable_decl": "#1f8ef1",
  "param": "#1f8ef1",
  "field": "#9b59b6",
  "enum_field": "#9b59b6",
  "field_value": "#0f9d58"
}
```

### Theme Color Properties

| Property | Description |
|----------|-------------|
| `background` | Editor background color |
| `foreground` | Default text color |
| `selection` | Selected text background |
| `cursor` | Cursor/caret color |
| `line_highlight` | Current line highlight background |
| `comment` | Comment text color |
| `keyword` | Keyword color (if, else, fn, etc.) |
| `special` | Special literals (null, true, false, etc.) |
| `string` | String literal color |
| `number` | Numeric literal color |
| `type` | Type name color |
| `function` | Function name color |
| `variable` | Variable name color |
| `variable_decl` | Variable/const declaration name color |
| `param` | Function parameter name color |
| `field` | Struct field name color |
| `enum_field` | Enum field name color |
| `field_value` | Struct field value color |

Colors are specified as hex strings with `#` prefix (e.g., `"#ff5500"`).

---

## License

MIT
