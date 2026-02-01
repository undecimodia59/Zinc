//! Integrated terminal with PTY support
//!
//! Provides an embedded terminal panel using pseudo-terminal (PTY) for
//! shell interaction, displayed in a GTK TextView widget.

const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk4");
const glib = @import("glib");
const gobject = @import("gobject");
const posix = std.posix;

const app = @import("app.zig");

// C library functions for PTY
const c = struct {
    extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*]u8, termp: ?*anyopaque, winp: ?*anyopaque) c_int;
    extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    const TIOCSCTTY: c_ulong = 0x540E;
};

/// Terminal state
pub const TerminalState = struct {
    master_fd: posix.fd_t,
    child_pid: ?posix.pid_t,
    container: *gtk.Box,
    text_view: *gtk.TextView,
    scroll: *gtk.ScrolledWindow,
    visible: bool,
    running: bool,
    io_source: c_uint,

    pub fn isActive(self: *const TerminalState) bool {
        return self.running and self.child_pid != null;
    }
};

var terminal_state: ?TerminalState = null;

/// Toggle terminal visibility
pub fn toggle() void {
    if (terminal_state) |*ts| {
        if (ts.visible) {
            hide();
        } else {
            show();
        }
    } else {
        show();
    }
}

/// Show the terminal panel
pub fn show() void {
    const app_state = app.state orelse return;

    if (terminal_state) |*ts| {
        if (ts.visible) return;
        ts.visible = true;
        ts.container.as(gtk.Widget).setVisible(1);
        app_state.terminal_paned.setPosition(getTerminalPosition(app_state));
        _ = ts.text_view.as(gtk.Widget).grabFocus();
        if (!ts.running) {
            restartTerminal(app_state, ts) catch |err| {
                std.debug.print("Failed to restart terminal: {}\n", .{err});
                app_state.setStatus("Error: Failed to restart terminal");
            };
        }
        return;
    }

    // First time: create terminal
    createTerminal(app_state) catch |err| {
        std.debug.print("Failed to create terminal: {}\n", .{err});
        app_state.setStatus("Error: Failed to create terminal");
        return;
    };
}

/// Hide the terminal panel
pub fn hide() void {
    const app_state = app.state orelse return;

    if (terminal_state) |*ts| {
        if (!ts.visible) return;
        ts.visible = false;
        ts.container.as(gtk.Widget).setVisible(0);
        // Maximize editor space by setting position to full height
        var w: c_int = 0;
        var h: c_int = 0;
        app_state.window.as(gtk.Window).getDefaultSize(&w, &h);
        app_state.terminal_paned.setPosition(h);
        _ = app_state.code_view.as(gtk.Widget).grabFocus();
    }
}

/// Clean up terminal resources
pub fn deinit() void {
    var ts = terminal_state orelse return;

    // Remove GLib I/O source
    if (ts.io_source != 0) {
        _ = glib.Source.remove(ts.io_source);
        ts.io_source = 0;
    }

    // Kill child process
    if (ts.child_pid) |pid| {
        if (ts.master_fd >= 0) {
            posix.close(ts.master_fd);
            ts.master_fd = -1;
        }
        _ = posix.kill(-pid, posix.SIG.HUP) catch {};
        _ = posix.kill(pid, posix.SIG.TERM) catch {};
        _ = posix.waitpid(pid, 0);
        ts.child_pid = null;
    }

    // Close master fd
    if (ts.master_fd >= 0) {
        posix.close(ts.master_fd);
        ts.master_fd = -1;
    }

    ts.running = false;
    terminal_state = null;
}

/// Create terminal widget and spawn shell
fn createTerminal(app_state: *app.AppState) !void {
    // Create container
    const container = gtk.Box.new(gtk.Orientation.vertical, 0);
    container.as(gtk.Widget).setVexpand(0);

    // Header bar with title and close button
    const header = gtk.Box.new(gtk.Orientation.horizontal, 4);
    header.as(gtk.Widget).addCssClass("terminal-header");
    header.as(gtk.Widget).setMarginStart(8);
    header.as(gtk.Widget).setMarginEnd(4);
    header.as(gtk.Widget).setMarginTop(2);
    header.as(gtk.Widget).setMarginBottom(2);

    const title_label = gtk.Label.new("Terminal");
    title_label.as(gtk.Widget).setHexpand(1);
    title_label.as(gtk.Widget).setHalign(gtk.Align.start);
    header.append(title_label.as(gtk.Widget));

    const close_btn = gtk.Button.newFromIconName("window-close-symbolic");
    close_btn.as(gtk.Widget).addCssClass("flat");
    close_btn.as(gtk.Widget).setTooltipText("Hide Terminal (Ctrl+`)");
    _ = gtk.Button.signals.clicked.connect(close_btn, *gtk.Button, &onCloseClicked, close_btn, .{});
    header.append(close_btn.as(gtk.Widget));

    container.append(header.as(gtk.Widget));

    // Scrolled window for text view
    const scroll = gtk.ScrolledWindow.new();
    scroll.as(gtk.Widget).setVexpand(1);
    scroll.setMinContentHeight(150);

    // Text view for terminal output
    const text_view = gtk.TextView.new();
    text_view.setEditable(0);
    text_view.setCursorVisible(0);
    text_view.setMonospace(1);
    text_view.setWrapMode(gtk.WrapMode.char);
    text_view.as(gtk.Widget).setVexpand(1);
    text_view.as(gtk.Widget).addCssClass("terminal-view");

    // Apply terminal styling
    applyTerminalStyle(text_view, app_state);

    scroll.setChild(text_view.as(gtk.Widget));
    container.append(scroll.as(gtk.Widget));

    // Add to terminal paned
    app_state.terminal_paned.setEndChild(container.as(gtk.Widget));

    // Set up key controller for input
    const key_controller = gtk.EventControllerKey.new();
    text_view.as(gtk.Widget).addController(key_controller.as(gtk.EventController));
    _ = gtk.EventControllerKey.signals.key_pressed.connect(
        key_controller,
        *gtk.TextView,
        &onKeyPress,
        text_view,
        .{},
    );

    terminal_state = TerminalState{
        .master_fd = -1,
        .child_pid = null,
        .container = container,
        .text_view = text_view,
        .scroll = scroll,
        .visible = true,
        .running = false,
        .io_source = 0,
    };

    // Open PTY and spawn shell
    if (terminal_state) |*ts| {
        try restartTerminal(app_state, ts);
    }

    // Set initial paned position
    app_state.terminal_paned.setPosition(getTerminalPosition(app_state));

    // Focus terminal
    _ = text_view.as(gtk.Widget).grabFocus();
}

/// Apply terminal-specific styling
fn applyTerminalStyle(text_view: *gtk.TextView, app_state: *app.AppState) void {
    const cfg = app_state.config;

    // Get theme colors - stored as u32 (0xRRGGBB)
    const bg = cfg.theme.background;
    const fg = cfg.theme.foreground;

    // Extract RGB components
    const bg_r: u8 = @truncate((bg >> 16) & 0xFF);
    const bg_g: u8 = @truncate((bg >> 8) & 0xFF);
    const bg_b: u8 = @truncate(bg & 0xFF);
    const fg_r: u8 = @truncate((fg >> 16) & 0xFF);
    const fg_g: u8 = @truncate((fg >> 8) & 0xFF);
    const fg_b: u8 = @truncate(fg & 0xFF);

    // Header background slightly lighter
    const hdr_r: u8 = @min(255, @as(u16, bg_r) + 20);
    const hdr_g: u8 = @min(255, @as(u16, bg_g) + 20);
    const hdr_b: u8 = @min(255, @as(u16, bg_b) + 20);

    // Build CSS for terminal
    var css_buf: [768]u8 = undefined;
    const css = std.fmt.bufPrintZ(&css_buf,
        \\.terminal-view {{
        \\  background-color: #{x:0>2}{x:0>2}{x:0>2};
        \\  color: #{x:0>2}{x:0>2}{x:0>2};
        \\  font-family: "{s}";
        \\  font-size: {d}pt;
        \\  padding: 4px 8px;
        \\}}
        \\.terminal-header {{
        \\  background-color: #{x:0>2}{x:0>2}{x:0>2};
        \\  border-bottom: 1px solid #444;
        \\}}
    , .{
        bg_r,  bg_g,  bg_b,
        fg_r,  fg_g,  fg_b,
        cfg.editor.font_family,
        cfg.editor.font_size,
        hdr_r, hdr_g, hdr_b,
    }) catch return;

    const provider = gtk.CssProvider.new();
    provider.loadFromString(css.ptr);
    text_view.as(gtk.Widget).getStyleContext().addProvider(
        provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
}

/// Calculate terminal paned position (show ~1/3 of window for terminal)
fn getTerminalPosition(app_state: *app.AppState) c_int {
    var w: c_int = 0;
    var h: c_int = 0;
    app_state.window.as(gtk.Window).getDefaultSize(&w, &h);
    // Account for tab bar and status bar (~60px)
    const available = h - 60;
    // Terminal takes about 1/3 of available space
    return @intCast(@max(200, @divTrunc(available * 2, 3)));
}

/// Open a pseudo-terminal pair
fn openPty() !struct { master: posix.fd_t, slave: posix.fd_t } {
    var master: c_int = undefined;
    var slave: c_int = undefined;

    const result = c.openpty(&master, &slave, null, null, null);
    if (result != 0) {
        return error.OpenPtyFailed;
    }

    return .{ .master = master, .slave = slave };
}

/// Child process setup - runs in forked process
fn childProcess(slave_fd: posix.fd_t, master_fd: posix.fd_t) noreturn {
    // Create new session
    _ = posix.setsid() catch {};

    // Set slave as controlling terminal
    _ = c.ioctl(slave_fd, c.TIOCSCTTY, @as(c_int, 0));

    // Duplicate slave to stdin/stdout/stderr
    _ = posix.dup2(slave_fd, 0) catch {};
    _ = posix.dup2(slave_fd, 1) catch {};
    _ = posix.dup2(slave_fd, 2) catch {};

    // Close original fds
    if (slave_fd > 2) posix.close(slave_fd);
    posix.close(master_fd);

    // Get shell from environment or default to /bin/sh
    const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
    const shell_z: [*:0]const u8 = @ptrCast(shell.ptr);

    // Execute shell
    const argv = [_:null]?[*:0]const u8{ shell_z, null };
    const envp = @as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ));

    posix.execvpeZ(shell_z, &argv, envp) catch {};
    posix.exit(1);
}

/// Handle PTY output - called by GLib when data is available
fn onPtyReadable(fd: c_int, condition: glib.IOCondition, user_data: ?*anyopaque) callconv(.c) c_int {
    const text_view: *gtk.TextView = @ptrCast(@alignCast(user_data orelse return 0));
    const ts = terminal_state orelse return 0;
    _ = ts;

    // Check for hangup or error
    if (condition.hup or condition.err) {
        handleProcessExit(text_view);
        return 0; // Remove source
    }

    // Read available data
    var buf: [4096]u8 = undefined;
    const n = posix.read(fd, &buf) catch |err| {
        if (err == error.WouldBlock) return 1; // Continue watching
        handleProcessExit(text_view);
        return 0;
    };

    if (n == 0) {
        handleProcessExit(text_view);
        return 0;
    }

    // Process and append output
    const output = buf[0..n];
    appendOutput(text_view, output);

    return 1; // Continue watching
}

/// Handle process exit
fn handleProcessExit(text_view: *gtk.TextView) void {
    var ts = terminal_state orelse return;

    // Wait for child to clean up zombie
    if (ts.child_pid) |pid| {
        _ = posix.waitpid(pid, posix.W.NOHANG);
    }

    if (ts.io_source != 0) {
        _ = glib.Source.remove(ts.io_source);
        ts.io_source = 0;
    }
    if (ts.master_fd >= 0) {
        posix.close(ts.master_fd);
        ts.master_fd = -1;
    }
    ts.running = false;
    ts.child_pid = null;
    terminal_state = ts;

    const buffer = text_view.getBuffer();
    const empty: [1:0]u8 = .{0};
    buffer.setText(empty[0..:0].ptr, 0);

    if (ts.visible) {
        hide();
    }
}

/// Append text to terminal output
fn appendOutput(text_view: *gtk.TextView, data: []const u8) void {
    const buffer = text_view.getBuffer();

    var end_iter: gtk.TextIter = undefined;
    buffer.getEndIter(&end_iter);

    var scratch: [4097]u8 = undefined;
    var scratch_len: usize = 0;

    const flush = struct {
        fn call(buf: *gtk.TextBuffer, iter: *gtk.TextIter, scratch_ptr: *[4097]u8, len: *usize) void {
            if (len.* == 0) return;
            scratch_ptr.*[len.*] = 0;
            const slice = scratch_ptr.*[0..len.* :0];
            buf.insert(iter, slice.ptr, @intCast(len.*));
            len.* = 0;
        }
    }.call;

    var i: usize = 0;
    while (i < data.len) {
        const ch = data[i];

        if (ch == 0x1b and i + 1 < data.len) {
            flush(buffer, &end_iter, &scratch, &scratch_len);
            i += 1;
            if (data[i] == '[') {
                i += 1;
                var params: [4]u16 = .{ 0, 0, 0, 0 };
                var param_count: usize = 0;
                var have_value = false;
                while (i < data.len) {
                    const b = data[i];
                    if (b >= '0' and b <= '9') {
                        const d: u16 = @intCast(b - '0');
                        if (param_count < params.len) {
                            params[param_count] = params[param_count] * 10 + d;
                            have_value = true;
                        }
                        i += 1;
                        continue;
                    }
                    if (b == ';') {
                        if (param_count < params.len) {
                            if (!have_value) params[param_count] = 0;
                            param_count += 1;
                        }
                        have_value = false;
                        i += 1;
                        continue;
                    }
                    if (b >= 0x40 and b <= 0x7e) {
                        if (have_value or param_count == 0) {
                            if (param_count < params.len) param_count += 1;
                        }
                        const final = b;
                        i += 1;

                        switch (final) {
                            'J' => {
                                const mode: u16 = if (param_count > 0) params[0] else 0;
                                if (mode == 2 or mode == 3) {
                                    const empty: [1:0]u8 = .{0};
                                    buffer.setText(empty[0..:0].ptr, 0);
                                    buffer.getStartIter(&end_iter);
                                } else if (mode == 0) {
                                    var end2: gtk.TextIter = undefined;
                                    buffer.getEndIter(&end2);
                                    buffer.delete(&end_iter, &end2);
                                }
                            },
                            'K' => {
                                const mode: u16 = if (param_count > 0) params[0] else 0;
                                var line_start = end_iter;
                                var line_end = end_iter;
                                line_start.setLineOffset(0);
                                _ = line_end.forwardToLineEnd();
                                switch (mode) {
                                    2 => {
                                        buffer.delete(&line_start, &line_end);
                                        end_iter = line_start;
                                    },
                                    0 => buffer.delete(&end_iter, &line_end),
                                    1 => {
                                        buffer.delete(&line_start, &end_iter);
                                        end_iter = line_start;
                                    },
                                    else => {},
                                }
                            },
                            'H', 'f' => {
                                buffer.getStartIter(&end_iter);
                            },
                            else => {},
                        }
                        break;
                    }
                    i += 1;
                }
                continue;
            } else if (data[i] == ']') {
                i += 1;
                while (i < data.len) {
                    if (data[i] == 0x07) {
                        i += 1;
                        break;
                    }
                    if (data[i] == 0x1b and i + 1 < data.len and data[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                continue;
            }
            continue;
        }

        if (ch == '\r') {
            flush(buffer, &end_iter, &scratch, &scratch_len);
            if (i + 1 < data.len and data[i + 1] == '\n') {
                const newline: [2:0]u8 = .{ '\n', 0 };
                buffer.insert(&end_iter, newline[0..:0].ptr, 1);
                i += 2;
                continue;
            }
            var line_start = end_iter;
            line_start.setLineOffset(0);
            var line_end = line_start;
            _ = line_end.forwardToLineEnd();
            if (line_end.compare(&line_start) != 0) {
                buffer.delete(&line_start, &line_end);
            }
            end_iter = line_start;
            i += 1;
            continue;
        }

        if (ch == 0x08 or ch == 0x7f) {
            flush(buffer, &end_iter, &scratch, &scratch_len);
            var back_iter = end_iter;
            if (back_iter.backwardChar() != 0) {
                buffer.delete(&back_iter, &end_iter);
                end_iter = back_iter;
            }
            i += 1;
            continue;
        }

        if (ch < 0x20 and ch != '\n' and ch != '\t') {
            i += 1;
            continue;
        }

        if (scratch_len == scratch.len - 1) {
            flush(buffer, &end_iter, &scratch, &scratch_len);
        }
        scratch[scratch_len] = ch;
        scratch_len += 1;
        i += 1;
    }

    flush(buffer, &end_iter, &scratch, &scratch_len);

    // Scroll to end
    buffer.getEndIter(&end_iter);
    const mark = buffer.createMark(null, &end_iter, 0);
    text_view.scrollMarkOnscreen(mark);
    buffer.deleteMark(mark);
}


/// Handle key press in terminal
fn onKeyPress(
    _: *gtk.EventControllerKey,
    keyval: c_uint,
    _: c_uint,
    modifiers: gdk.ModifierType,
    text_view: *gtk.TextView,
) callconv(.c) c_int {
    _ = text_view;
    const ts = if (terminal_state) |*ts_ptr| ts_ptr else return 0;
    if (!ts.running) return 1;

    // Ctrl+` to toggle (let it propagate)
    if (modifiers.control_mask and (keyval == '`' or keyval == gdk.KEY_grave)) {
        return 0;
    }

    var buf: [8]u8 = undefined;
    var len: usize = 0;

    // Handle special keys
    if (modifiers.control_mask) {
        // Ctrl+C -> SIGINT (ETX)
        if (keyval == 'c' or keyval == 'C') {
            buf[0] = 0x03;
            len = 1;
        }
        // Ctrl+D -> EOF (EOT)
        else if (keyval == 'd' or keyval == 'D') {
            buf[0] = 0x04;
            len = 1;
        }
        // Ctrl+Z -> SIGTSTP (SUB)
        else if (keyval == 'z' or keyval == 'Z') {
            buf[0] = 0x1a;
            len = 1;
        }
        // Ctrl+L -> Clear (FF)
        else if (keyval == 'l' or keyval == 'L') {
            buf[0] = 0x0c;
            len = 1;
        }
        // Other ctrl keys
        else {
            const uni = gdk.keyvalToUnicode(keyval);
            if (uni >= 'a' and uni <= 'z') {
                buf[0] = @intCast(uni - 'a' + 1);
                len = 1;
            } else if (uni >= 'A' and uni <= 'Z') {
                buf[0] = @intCast(uni - 'A' + 1);
                len = 1;
            }
        }
    } else {
        switch (keyval) {
            gdk.KEY_Return, gdk.KEY_KP_Enter => {
                buf[0] = '\n';
                len = 1;
            },
            gdk.KEY_BackSpace => {
                buf[0] = 0x7f;
                len = 1;
            },
            gdk.KEY_Tab => {
                buf[0] = '\t';
                len = 1;
            },
            gdk.KEY_Escape => {
                buf[0] = 0x1b;
                len = 1;
            },
            gdk.KEY_Up => {
                buf[0] = 0x1b;
                buf[1] = '[';
                buf[2] = 'A';
                len = 3;
            },
            gdk.KEY_Down => {
                buf[0] = 0x1b;
                buf[1] = '[';
                buf[2] = 'B';
                len = 3;
            },
            gdk.KEY_Right => {
                buf[0] = 0x1b;
                buf[1] = '[';
                buf[2] = 'C';
                len = 3;
            },
            gdk.KEY_Left => {
                buf[0] = 0x1b;
                buf[1] = '[';
                buf[2] = 'D';
                len = 3;
            },
            gdk.KEY_Home => {
                buf[0] = 0x1b;
                buf[1] = '[';
                buf[2] = 'H';
                len = 3;
            },
            gdk.KEY_End => {
                buf[0] = 0x1b;
                buf[1] = '[';
                buf[2] = 'F';
                len = 3;
            },
            gdk.KEY_Delete => {
                buf[0] = 0x1b;
                buf[1] = '[';
                buf[2] = '3';
                buf[3] = '~';
                len = 4;
            },
            gdk.KEY_Page_Up => {
                buf[0] = 0x1b;
                buf[1] = '[';
                buf[2] = '5';
                buf[3] = '~';
                len = 4;
            },
            gdk.KEY_Page_Down => {
                buf[0] = 0x1b;
                buf[1] = '[';
                buf[2] = '6';
                buf[3] = '~';
                len = 4;
            },
            else => {
                // Regular character
                const uni = gdk.keyvalToUnicode(keyval);
                if (uni > 0 and uni < 0x110000) {
                    len = std.unicode.utf8Encode(@intCast(uni), &buf) catch 0;
                }
            },
        }
    }

    if (len > 0) {
        _ = posix.write(ts.master_fd, buf[0..len]) catch {};
        return 1;
    }

    return 0;
}

fn restartTerminal(app_state: *app.AppState, ts: *TerminalState) !void {
    if (ts.io_source != 0) {
        _ = glib.Source.remove(ts.io_source);
        ts.io_source = 0;
    }
    if (ts.master_fd >= 0) {
        posix.close(ts.master_fd);
        ts.master_fd = -1;
    }

    const pty = try openPty();
    const master_fd = pty.master;
    const slave_fd = pty.slave;

    const pid = try posix.fork();
    if (pid == 0) {
        childProcess(slave_fd, master_fd);
    }

    posix.close(slave_fd);

    const flags = posix.fcntl(master_fd, posix.F.GETFL, 0) catch 0;
    const nonblock_u32: u32 = @bitCast(posix.O{ .NONBLOCK = true });
    const nonblock = @as(usize, nonblock_u32);
    _ = posix.fcntl(master_fd, posix.F.SETFL, flags | nonblock) catch {};

    const condition = glib.IOCondition{
        .in = true,
        .hup = true,
        .err = true,
        .out = false,
        .pri = false,
        .nval = false,
    };
    const io_source = glib.unixFdAdd(
        master_fd,
        condition,
        &onPtyReadable,
        ts.text_view,
    );

    ts.master_fd = master_fd;
    ts.child_pid = pid;
    ts.running = true;
    ts.io_source = io_source;

    applyTerminalStyle(ts.text_view, app_state);
}

/// Close button clicked
fn onCloseClicked(_: *gtk.Button, _: *gtk.Button) callconv(.c) void {
    hide();
}

/// Get current terminal state (for external access)
pub fn getState() ?*TerminalState {
    if (terminal_state) |*ts| {
        return ts;
    }
    return null;
}
