# Zinc - Development Roadmap (v 0.2.3)

A lightweight, fast text editor with IDE features. Inspired by Atom, Sublime Text, and Vim.

## Core Principles
- Fast startup and low memory usage
- Keyboard-centric workflow
- Minimal but beautiful UI
- Extensible without bloat

---

## Phase 1: Foundation

### Settings System
- [x] Config file support (`~/.config/zinc/config.json` or TOML)
- [x] Font family setting
- [x] Font size setting (with Ctrl+= / Ctrl+- shortcuts)
- [x] Tab width setting (2, 4, 8 spaces)
- [x] Tabs vs spaces preference
- [x] Line numbers toggle
- [x] Theme selection (dark/light/dracula/gruvbox/nord/one-dark)
- [x] File tree width setting
- [x] Window size/position persistence

### Editor Basics
- [x] Line numbers gutter
- [x] Current line highlight
- [x] Auto-indent on Enter
- [x] Smart backspace (delete indent level)
- [x] Undo/Redo with proper history (GTK built-in: Ctrl+Z / Ctrl+Shift+Z)
- [x] Save file (Ctrl+S)
- [x] Unsaved changes indicator (dot in title/tab)

---

## Phase 2: Editing Power

### Vim Mode
- [x] Modal editing (Normal, Insert, Visual, Command)
- [x] Basic motions: h, j, k, l, w, b, 0, $, gg, G (+ arrow keys)
- [x] Operators: d, c, y, p, x (dd, yy, cc for lines)
- [x] Count prefix (e.g., 5j, 3w, 2dd)
- [ ] Text objects: iw, aw, i", a", i(, a(
- [x] Search with / and n/N
- [x] Command mode (:w, :q, :q!, :wq, :e file, :!cmd)
- [x] Shell command output popup (:!<cmd>)
- [x] Visual mode selection (v, V for line)
- [ ] Repeat with .
- [ ] Marks with m and '
- [x] Status line showing current mode
- [x] Toggle vim mode on/off in settings (disabled by default)

### Multiple Cursors
- [ ] Add cursor above/below (Ctrl+Alt+Up/Down)
- [ ] Add cursor at next occurrence (Ctrl+D)
- [ ] Select all occurrences (Ctrl+Shift+L)

### Search & Replace
- [ ] Find in file (Ctrl+F)
- [ ] Find and replace (Ctrl+H)
- [ ] Regex support
- [ ] Case sensitive toggle
- [ ] Whole word toggle
- [ ] Find in project (Ctrl+Shift+F)

---

## Phase 3: Syntax & Visuals

### Syntax Highlighting
- [x] Modular tokenizer-based highlighting core
- [ ] Language support:
  - [x] Zig (priority)
  - [x] C/C++
  - [x] Rust
  - [x] Python
  - [x] JavaScript/TypeScript
  - [x] Go
  - [x] Markdown
  - [x] JSON/YAML/TOML
  - [x] HTML/CSS
  - [x] Shell scripts
- [x] Theme-aware token colors
- [ ] Bracket matching highlight

### Themes
- [x] Built-in dark theme (current)
- [x] Built-in light theme
- [x] Dracula theme
- [x] Gruvbox theme
- [x] Nord theme
- [x] One Dark theme
- [ ] Theme file format for custom themes

### UI Polish
- [ ] Minimap (code overview sidebar)
- [ ] Smooth scrolling
- [ ] Cursor blink animation
- [ ] Indent guides (vertical lines)
- [ ] Git diff indicators in gutter (+, -, ~)

---

## Phase 4: Navigation

### Quick Open
- [ ] Fuzzy file finder (Ctrl+P)
- [ ] Recent files list
- [ ] File path in results
- [ ] File icons by type

### Command Palette
- [x] Command palette (Ctrl+Shift+P)
- [ ] Fuzzy search commands
- [ ] Show keybinding next to command
- [ ] Recent commands

### Go To
- [ ] Go to line (Ctrl+G)
- [ ] Go to symbol in file (Ctrl+Shift+O)
- [ ] Go to definition (F12) - requires LSP
- [ ] Go to references - requires LSP
- [ ] Breadcrumb navigation

### Tabs & Splits
- [ ] Tab bar for open files
- [ ] Tab reordering
- [ ] Close tab (Ctrl+W)
- [ ] Split view horizontal/vertical
- [ ] Focus between splits (Ctrl+1, 2, 3...)

---

## Phase 5: Intelligence (Optional LSP)

### Language Server Protocol
- [ ] LSP client implementation
- [ ] Auto-detect language servers
- [ ] Hover information
- [ ] Autocomplete
- [ ] Signature help
- [ ] Diagnostics (errors, warnings)
- [ ] Code actions
- [ ] Rename symbol
- [ ] Format document

### Built-in Intelligence (no LSP needed)
- [ ] Basic word completion from current file
- [ ] Bracket auto-close
- [ ] Quote auto-close
- [ ] Auto-indent based on brackets

---

## Phase 6: Workflow

### Terminal
- [ ] Integrated terminal panel
- [ ] Multiple terminal tabs
- [ ] Terminal split

### Git Integration
- [ ] Git status in file tree (colors/icons)
- [ ] Current branch in status bar
- [ ] Basic git commands from command palette

### Session
- [ ] Remember open files on close
- [ ] Restore session on start
- [ ] Workspace/project files

---

## Ideas (Maybe Later)

- [ ] Plugin system (Lua or WASM)
- [ ] Collaborative editing
- [ ] Zen mode (distraction-free)
- [ ] Snippet support
- [ ] Macro recording
- [ ] Column selection mode
- [ ] Diff viewer
- [ ] Image preview
- [ ] Markdown preview

---

## Technical Debt

- [ ] Remove debug print statements
- [ ] Proper error handling throughout
- [ ] Memory leak audit
- [ ] Use Blueprint UI files instead of programmatic UI
- [ ] Unit tests for core logic
- [ ] CI/CD pipeline

---

## Performance Goals

- Startup time: < 100ms
- File open (< 1MB): < 50ms
- Memory usage (idle): < 50MB
- Smooth scrolling at 60fps
- Handle files up to 1GB without lag
