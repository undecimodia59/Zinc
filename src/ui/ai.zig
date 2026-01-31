const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk4");
const glib = @import("glib");

const app = @import("app.zig");
const gobject = @import("gobject");

// Layout constants
const DIALOG_WIDTH: c_int = 560;
const DIALOG_HEIGHT: c_int = 200;
const DIALOG_MARGIN: c_int = 12;
const DIALOG_SPACING: c_int = 8;
const MIN_PROMPT_HEIGHT: c_int = 90;

const Provider = enum {
    gemini,
    codex,
    claude,
};

var ai_css_provider: ?*gtk.CssProvider = null;

const prompt_header_rewrite =
    \\You are an AI code assistant.
    \\Rewrite the selected code according to the user's instruction.
    \\Return ONLY the rewritten code snippet. No explanations. No code fences.
    \\
;

const prompt_header_generate =
    \\You are an AI code assistant.
    \\Generate code according to the user's instruction.
    \\Return ONLY the code snippet. No explanations. No code fences.
    \\
;

/// Runs an AI prompt from the command palette.
/// If there's a selection, rewrites it; otherwise generates new code at cursor.
pub fn runFromPalette(prompt: []const u8) void {
    const s = app.state orelse return;
    const cfg = s.config;
    if (!cfg.editor.ai_enabled) {
        s.setStatus("AI is disabled in settings");
        return;
    }
    if (std.mem.trim(u8, prompt, " \t\r\n").len == 0) {
        s.setStatus("AI: prompt required");
        return;
    }

    const selection = getSelectionText(s.code_view);
    const code = if (selection) |sel| sel.text else "";
    if (selection) |sel| {
        defer s.allocator.free(sel.text);
    }

    const full_prompt = buildPrompt(s.allocator, prompt, code) orelse {
        s.setStatus("AI: out of memory");
        return;
    };
    defer s.allocator.free(full_prompt);

    const provider = providerFromName(cfg.editor.ai_provider);
    const result = runProvider(s.allocator, provider, full_prompt);
    if (result.output) |out| {
        defer s.allocator.free(out);
        const start_off: i32 = if (selection) |sel| sel.start_offset else 0;
        const end_off: i32 = if (selection) |sel| sel.end_offset else 0;
        showResultDialog(s, out, start_off, end_off, null);
        return;
    }
    if (result.err_msg.len > 0) {
        s.setStatus(result.err_msg);
    }
}

/// Opens the AI prompt dialog.
/// Optionally pre-fills with the given prompt text.
pub fn openPromptDialog() void {
    openPromptDialogImpl("");
}

fn openPromptDialogImpl(prompt: []const u8) void {
    const s = app.state orelse return;
    const cfg = s.config;
    if (!cfg.editor.ai_enabled) {
        s.setStatus("AI is disabled in settings");
        return;
    }

    const dialog = gtk.Window.new();
    dialog.setTitle("AI Prompt");
    dialog.setDecorated(0);
    dialog.setDefaultSize(DIALOG_WIDTH, DIALOG_HEIGHT);
    dialog.setTransientFor(s.window.as(gtk.Window));
    dialog.setModal(1);
    dialog.setResizable(0);

    const vbox = gtk.Box.new(gtk.Orientation.vertical, DIALOG_SPACING);
    vbox.as(gtk.Widget).setMarginStart(DIALOG_MARGIN);
    vbox.as(gtk.Widget).setMarginEnd(DIALOG_MARGIN);
    vbox.as(gtk.Widget).setMarginTop(DIALOG_MARGIN);
    vbox.as(gtk.Widget).setMarginBottom(DIALOG_MARGIN);

    const prompt_scroll = gtk.ScrolledWindow.new();
    prompt_scroll.setPolicy(gtk.PolicyType.never, gtk.PolicyType.automatic);
    prompt_scroll.setMinContentHeight(MIN_PROMPT_HEIGHT);
    prompt_scroll.setPropagateNaturalHeight(1);

    const prompt_view = gtk.TextView.new();
    prompt_view.setWrapMode(gtk.WrapMode.word_char);
    prompt_view.as(gtk.Widget).setVexpand(1);
    prompt_view.as(gtk.Widget).setHexpand(1);
    if (prompt.len > 0) {
        const prompt_z = s.allocator.dupeZ(u8, prompt) catch null;
        if (prompt_z) |pz| {
            defer s.allocator.free(pz);
            prompt_view.getBuffer().setText(pz.ptr, @intCast(prompt.len));
        }
    }
    prompt_scroll.setChild(prompt_view.as(gtk.Widget));
    vbox.append(prompt_scroll.as(gtk.Widget));

    const status = gtk.Label.new("");
    status.as(gtk.Widget).setHalign(gtk.Align.start);
    status.setText("Enter to run • Shift+Enter for newline");
    vbox.append(status.as(gtk.Widget));

    const buttons = gtk.Box.new(gtk.Orientation.horizontal, DIALOG_SPACING);
    buttons.as(gtk.Widget).setHalign(gtk.Align.end);
    const cancel_btn = gtk.Button.newWithLabel("Cancel");
    const run_btn = gtk.Button.newWithLabel("Run");
    buttons.append(cancel_btn.as(gtk.Widget));
    buttons.append(run_btn.as(gtk.Widget));
    vbox.append(buttons.as(gtk.Widget));

    dialog.setChild(vbox.as(gtk.Widget));

    applyPromptStyles(s.allocator);

    const ctx = s.allocator.create(PromptContext) catch return;
    ctx.* = .{
        .dialog = dialog,
        .prompt_view = prompt_view,
        .status = status,
        .allocator = s.allocator,
        .defer_free = false,
        .provider = providerFromName(cfg.editor.ai_provider),
    };

    _ = gtk.Button.signals.clicked.connect(run_btn, *PromptContext, &onPromptRun, ctx, .{});
    _ = gtk.Button.signals.clicked.connect(cancel_btn, *PromptContext, &onPromptCancel, ctx, .{});
    _ = gtk.Window.signals.close_request.connect(dialog, *PromptContext, &onPromptClose, ctx, .{});

    const key_controller = gtk.EventControllerKey.new();
    dialog.as(gtk.Widget).addController(key_controller.as(gtk.EventController));
    _ = gtk.EventControllerKey.signals.key_pressed.connect(
        key_controller,
        *PromptContext,
        &onPromptKeyPress,
        ctx,
        .{},
    );

    const prompt_key_controller = gtk.EventControllerKey.new();
    prompt_view.as(gtk.Widget).addController(prompt_key_controller.as(gtk.EventController));
    _ = gtk.EventControllerKey.signals.key_pressed.connect(
        prompt_key_controller,
        *PromptContext,
        &onPromptTextKeyPress,
        ctx,
        .{},
    );

    dialog.as(gtk.Widget).setVisible(1);
    _ = prompt_view.as(gtk.Widget).grabFocus();
}

const Selection = struct {
    text: []u8,
    start_offset: i32,
    end_offset: i32,
};

fn getSelectionText(view: *gtk.TextView) ?Selection {
    const buffer = view.getBuffer();
    var start: gtk.TextIter = undefined;
    var end: gtk.TextIter = undefined;
    if (buffer.getSelectionBounds(&start, &end) == 0) return null;

    const start_off = start.getOffset();
    const end_off = end.getOffset();
    if (start_off == end_off) return null;

    const text_ptr = buffer.getText(&start, &end, 0);
    defer glib.free(@constCast(text_ptr));
    const span = std.mem.span(text_ptr);

    const alloc = app.allocator();
    const copy = alloc.dupe(u8, span) catch return null;
    return .{
        .text = copy,
        .start_offset = start_off,
        .end_offset = end_off,
    };
}

fn buildPrompt(allocator: std.mem.Allocator, user_prompt: []const u8, code: []const u8) ?[]u8 {
    const header = if (code.len > 0) prompt_header_rewrite else prompt_header_generate;
    return std.fmt.allocPrint(
        allocator,
        \\{s}
        \\User instruction:
        \\{s}
        \\
        \\Selected code:
        \\{s}
        \\
        \\Output:
    ,
        .{ header, user_prompt, code },
    ) catch null;
}

fn providerFromName(name: []const u8) Provider {
    if (std.mem.eql(u8, name, "codex")) return .codex;
    if (std.mem.eql(u8, name, "claude")) return .claude;
    return .gemini;
}

const ProviderResult = struct {
    output: ?[]u8,
    err_msg: []const u8,
};

fn runProvider(allocator: std.mem.Allocator, provider: Provider, prompt: []const u8) ProviderResult {

    const argv = switch (provider) {
        .gemini => &[_][]const u8{ "gemini", "-p", prompt },
        .codex => &[_][]const u8{ "codex", "-p", prompt },
        .claude => &[_][]const u8{ "claude", "-p", prompt },
    };

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    }) catch |err| {
        return switch (err) {
            error.FileNotFound => .{ .output = null, .err_msg = "AI provider not found in PATH" },
            else => .{ .output = null, .err_msg = "AI run failed" },
        };
    };
    const use_stdout = result.stdout.len > 0;
    const output = if (use_stdout) result.stdout else result.stderr;
    if (use_stdout) {
        allocator.free(result.stderr);
    } else {
        allocator.free(result.stdout);
    }
    if (output.len == 0) {
        return .{ .output = null, .err_msg = "AI: empty response" };
    }

    return .{ .output = output, .err_msg = "" };
}

fn showResultDialog(_: *app.AppState, output: []const u8, start_offset: i32, end_offset: i32, insert_offset: ?i32) void {
    const s = app.state orelse return;
    const ctx = s.allocator.create(ApplyContext) catch return;
    ctx.* = .{
        .buffer = s.code_view.getBuffer(),
        .output = s.allocator.dupe(u8, output) catch {
            s.allocator.destroy(ctx);
            return;
        },
        .start_offset = start_offset,
        .end_offset = end_offset,
        .insert_offset = insert_offset,
        .replace_selection = insert_offset == null,
        .allocator = s.allocator,
    };
    applyResult(ctx);
}

const ApplyContext = struct {
    buffer: *gtk.TextBuffer,
    output: []u8,
    start_offset: i32,
    end_offset: i32,
    insert_offset: ?i32,
    replace_selection: bool,
    allocator: std.mem.Allocator,
};

const PromptContext = struct {
    dialog: *gtk.Window,
    prompt_view: *gtk.TextView,
    status: *gtk.Label,
    allocator: std.mem.Allocator,
    defer_free: bool,
    provider: Provider,
};

fn applyResult(ctx: *ApplyContext) void {
    if (ctx.replace_selection) {
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        ctx.buffer.getIterAtOffset(&start, ctx.start_offset);
        ctx.buffer.getIterAtOffset(&end, ctx.end_offset);
        ctx.buffer.delete(&start, &end);
    } else if (ctx.insert_offset) |off| {
        var iter: gtk.TextIter = undefined;
        ctx.buffer.getIterAtOffset(&iter, off);
        ctx.buffer.placeCursor(&iter);
    }

    const out_z = ctx.allocator.dupeZ(u8, ctx.output) catch {
        ctx.allocator.free(ctx.output);
        ctx.allocator.destroy(ctx);
        return;
    };
    defer ctx.allocator.free(out_z);
    ctx.buffer.insertAtCursor(out_z.ptr, @intCast(ctx.output.len));
    ctx.allocator.free(ctx.output);
    ctx.allocator.destroy(ctx);
}

fn getPromptText(ctx: *PromptContext) ?[]u8 {
    const buffer = ctx.prompt_view.getBuffer();
    var start: gtk.TextIter = undefined;
    var end: gtk.TextIter = undefined;
    buffer.getBounds(&start, &end);
    const text_ptr = buffer.getText(&start, &end, 0);
    defer glib.free(@constCast(text_ptr));
    const span = std.mem.span(text_ptr);
    return ctx.allocator.dupe(u8, span) catch null;
}

fn applyPromptStyles(allocator: std.mem.Allocator) void {
    const display = gdk.Display.getDefault() orelse return;

    if (ai_css_provider) |old| {
        gtk.StyleContext.removeProviderForDisplay(display, old.as(gtk.StyleProvider));
        old.as(gobject.Object).unref();
    }

    const provider = gtk.CssProvider.new();
    ai_css_provider = provider;

    const css =
        \\.zinc-ai-overlay {{
        \\  padding: 6px 12px;
        \\}}
        \\.zinc-ai-overlay-label {{
        \\  background: rgba(0, 0, 0, 0.55);
        \\  color: #ffffff;
        \\  border-radius: 999px;
        \\  padding: 6px 12px;
        \\}}
    ;

    const css_z = allocator.allocSentinel(u8, css.len, 0) catch return;
    defer allocator.free(css_z);
    @memcpy(css_z, css);
    provider.loadFromData(css_z.ptr, @intCast(css_z.len));
    gtk.StyleContext.addProviderForDisplay(
        display,
        provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
}

fn showEditorOverlay(message: []const u8) void {
    const s = app.state orelse return;
    const label = s.ai_overlay_label;
    const box = s.ai_overlay_box;
    const z = s.allocator.dupeZ(u8, message) catch {
        box.as(gtk.Widget).setVisible(1);
        return;
    };
    defer s.allocator.free(z);
    label.setText(z.ptr);
    box.as(gtk.Widget).setVisible(1);
}

fn hideEditorOverlay() void {
    const s = app.state orelse return;
    s.ai_overlay_box.as(gtk.Widget).setVisible(0);
}

fn applyResultFromMarks(job_ctx: *JobContext, output: []const u8) void {
    const buffer = job_ctx.buffer;

    if (job_ctx.start_mark != null and job_ctx.end_mark != null) {
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        buffer.getIterAtMark(&start, job_ctx.start_mark.?);
        buffer.getIterAtMark(&end, job_ctx.end_mark.?);
        buffer.delete(&start, &end);
        buffer.placeCursor(&start);
    } else if (job_ctx.insert_mark) |mark| {
        var iter: gtk.TextIter = undefined;
        buffer.getIterAtMark(&iter, mark);
        buffer.placeCursor(&iter);
    }

    const out_z = job_ctx.allocator.dupeZ(u8, output) catch return;
    defer job_ctx.allocator.free(out_z);
    buffer.insertAtCursor(out_z.ptr, @intCast(output.len));
}

fn clearJobMarks(job_ctx: *JobContext) void {
    const buffer = job_ctx.buffer;
    if (job_ctx.start_mark) |mark| buffer.deleteMark(mark);
    if (job_ctx.end_mark) |mark| buffer.deleteMark(mark);
    if (job_ctx.insert_mark) |mark| buffer.deleteMark(mark);
}

fn onPromptRun(_: *gtk.Button, ctx: *PromptContext) callconv(.c) void {
    const s = app.state orelse return;
    const prompt = getPromptText(ctx) orelse {
        ctx.status.setText("Out of memory");
        return;
    };
    defer ctx.allocator.free(prompt);
    const prompt_trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (prompt_trimmed.len == 0) {
        ctx.status.setText("Prompt required");
        return;
    }

    var cursor_offset: ?i32 = null;
    var selected_code: []const u8 = "";
    const selection = getSelectionText(s.code_view);
    if (selection) |sel| {
        selected_code = sel.text;
    } else {
        var iter: gtk.TextIter = undefined;
        s.code_view.getBuffer().getIterAtMark(&iter, s.code_view.getBuffer().getInsert());
        cursor_offset = iter.getOffset();
    }

    const full_prompt = buildPrompt(ctx.allocator, prompt_trimmed, selected_code) orelse {
        ctx.status.setText("Out of memory");
        return;
    };

    const provider = ctx.provider;
    const start_off: i32 = if (selection) |sel| sel.start_offset else 0;
    const end_off: i32 = if (selection) |sel| sel.end_offset else 0;
    const insert_off: ?i32 = cursor_offset;

    const buffer = s.code_view.getBuffer();
    var start_mark: ?*gtk.TextMark = null;
    var end_mark: ?*gtk.TextMark = null;
    var insert_mark: ?*gtk.TextMark = null;

    if (selection) |sel| {
        var iter_start: gtk.TextIter = undefined;
        var iter_end: gtk.TextIter = undefined;
        buffer.getIterAtOffset(&iter_start, sel.start_offset);
        buffer.getIterAtOffset(&iter_end, sel.end_offset);
        start_mark = buffer.createMark(null, &iter_start, 1);
        end_mark = buffer.createMark(null, &iter_end, 0);
    } else if (insert_off) |off| {
        var iter_ins: gtk.TextIter = undefined;
        buffer.getIterAtOffset(&iter_ins, off);
        insert_mark = buffer.createMark(null, &iter_ins, 1);
    }

    ctx.defer_free = true;
    ctx.dialog.close();
    showEditorOverlay("AI running...");
    if (app.state) |st| st.setStatus("AI running...");

    const job = ctx.allocator.create(JobContext) catch {
        hideEditorOverlay();
        if (app.state) |st| st.setStatus("AI: out of memory");
        ctx.allocator.free(full_prompt);
        return;
    };
    job.* = .{
        .prompt = full_prompt,
        .provider = provider,
        .allocator = ctx.allocator,
        .start_offset = start_off,
        .end_offset = end_off,
        .insert_offset = insert_off,
        .buffer = buffer,
        .start_mark = start_mark,
        .end_mark = end_mark,
        .insert_mark = insert_mark,
    };

    _ = std.Thread.spawn(.{}, runJob, .{job}) catch {
        hideEditorOverlay();
        if (app.state) |st| st.setStatus("AI: failed to start");
        ctx.allocator.free(full_prompt);
        ctx.allocator.destroy(job);
    };
    if (selection) |sel| {
        ctx.allocator.free(sel.text);
    }
    ctx.allocator.destroy(ctx);
}

fn onPromptCancel(_: *gtk.Button, ctx: *PromptContext) callconv(.c) void {
    ctx.dialog.close();
}

fn onPromptClose(_: *gtk.Window, ctx: *PromptContext) callconv(.c) c_int {
    if (!ctx.defer_free) {
        ctx.allocator.destroy(ctx);
    }
    return 0;
}

fn onPromptKeyPress(
    _: *gtk.EventControllerKey,
    keyval: c_uint,
    _: c_uint,
    _: gdk.ModifierType,
    ctx: *PromptContext,
) callconv(.c) c_int {
    if (keyval == gdk.KEY_Escape) {
        ctx.dialog.close();
        return 1;
    }
    return 0;
}

fn onPromptTextKeyPress(
    _: *gtk.EventControllerKey,
    keyval: c_uint,
    _: c_uint,
    modifiers: gdk.ModifierType,
    ctx: *PromptContext,
) callconv(.c) c_int {
    if (keyval == gdk.KEY_Escape) {
        ctx.dialog.close();
        return 1;
    }
    if (keyval == gdk.KEY_Return or keyval == gdk.KEY_KP_Enter) {
        if (modifiers.shift_mask) {
            return 0;
        }
        onPromptRun(undefined, ctx);
        return 1;
    }
    return 0;
}

const JobContext = struct {
    prompt: []u8,
    provider: Provider,
    allocator: std.mem.Allocator,
    start_offset: i32,
    end_offset: i32,
    insert_offset: ?i32,
    buffer: *gtk.TextBuffer,
    start_mark: ?*gtk.TextMark,
    end_mark: ?*gtk.TextMark,
    insert_mark: ?*gtk.TextMark,
    output: ?[]u8 = null,
    err_msg: []const u8 = "",
};

fn runJob(job: *JobContext) void {
    const result = runProvider(job.allocator, job.provider, job.prompt);
    job.output = result.output;
    job.err_msg = result.err_msg;
    _ = glib.idleAddFull(
        glib.PRIORITY_DEFAULT_IDLE,
        struct {
            fn cb(data: ?*anyopaque) callconv(.c) c_int {
                const job_ctx: *JobContext = @ptrCast(@alignCast(data orelse return 0));
                hideEditorOverlay();

                if (job_ctx.output) |out| {
                    applyResultFromMarks(job_ctx, out);
                    job_ctx.allocator.free(out);
                    if (app.state) |st| st.setStatus("AI done");
                } else {
                    if (job_ctx.err_msg.len > 0) {
                        if (app.state) |st| {
                            const z = st.allocator.dupeZ(u8, job_ctx.err_msg) catch {
                                st.setStatus("AI failed");
                                return 0;
                            };
                            defer st.allocator.free(z);
                            st.setStatus(z);
                        }
                    } else if (app.state) |st| {
                        st.setStatus("AI failed");
                    }
                }

                clearJobMarks(job_ctx);
                job_ctx.allocator.free(job_ctx.prompt);
                job_ctx.allocator.destroy(job_ctx);
                return 0;
            }
        }.cb,
        job,
        null,
    );
}
