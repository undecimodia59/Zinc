//! Language Server Protocol client
//!
//! This module will handle LSP communication for:
//! - Code completion
//! - Go to definition
//! - Find references
//! - Diagnostics (errors, warnings)
//! - Hover information
//! - Code actions

const std = @import("std");

const Allocator = std.mem.Allocator;

/// LSP client configuration
pub const Config = struct {
    server_path: []const u8,
    root_path: []const u8,
    language_id: []const u8,
};

/// LSP client state
pub const Client = struct {
    allocator: Allocator,
    config: Config,
    process: ?std.process.Child,
    initialized: bool,

    pub fn init(allocator: Allocator, config: Config) Client {
        return .{
            .allocator = allocator,
            .config = config,
            .process = null,
            .initialized = false,
        };
    }

    pub fn deinit(self: *Client) void {
        self.shutdown();
    }

    pub fn start(self: *Client) !void {
        // TODO: Start the LSP server process
        _ = self;
    }

    pub fn shutdown(self: *Client) void {
        if (self.process) |*proc| {
            _ = proc.kill() catch {};
        }
        self.process = null;
        self.initialized = false;
    }

    pub fn initialize(self: *Client) !void {
        // TODO: Send initialize request
        self.initialized = true;
    }

    pub fn textDocumentDidOpen(self: *Client, uri: []const u8, content: []const u8) !void {
        // TODO: Send textDocument/didOpen notification
        _ = self;
        _ = uri;
        _ = content;
    }

    pub fn textDocumentDidChange(self: *Client, uri: []const u8, content: []const u8) !void {
        // TODO: Send textDocument/didChange notification
        _ = self;
        _ = uri;
        _ = content;
    }

    pub fn textDocumentCompletion(self: *Client, uri: []const u8, line: u32, character: u32) !void {
        // TODO: Send textDocument/completion request
        _ = self;
        _ = uri;
        _ = line;
        _ = character;
    }

    pub fn textDocumentDefinition(self: *Client, uri: []const u8, line: u32, character: u32) !void {
        // TODO: Send textDocument/definition request
        _ = self;
        _ = uri;
        _ = line;
        _ = character;
    }
};

/// Diagnostic severity levels
pub const DiagnosticSeverity = enum {
    @"error",
    warning,
    information,
    hint,
};

/// A diagnostic message from the LSP server
pub const Diagnostic = struct {
    line: u32,
    character: u32,
    end_line: u32,
    end_character: u32,
    severity: DiagnosticSeverity,
    message: []const u8,
    source: ?[]const u8,
};

/// A completion item from the LSP server
pub const CompletionItem = struct {
    label: []const u8,
    kind: ?CompletionKind,
    detail: ?[]const u8,
    insert_text: ?[]const u8,
};

pub const CompletionKind = enum {
    text,
    method,
    function,
    constructor,
    field,
    variable,
    class,
    interface,
    module,
    property,
    unit,
    value,
    @"enum",
    keyword,
    snippet,
    color,
    file,
    reference,
    folder,
    enum_member,
    constant,
    @"struct",
    event,
    operator,
    type_parameter,
};
