//! Streaming (SSE) iterators for the two streaming endpoints.
//!
//! Each `next()` call resets an internal arena and returns data valid only
//! until the *next* call to `next()` or to `deinit()` --- this mirrors how
//! `std.Io.Reader.take*` slices work and avoids the caller having to
//! individually free each parsed JSON tree per event. If you need an event
//! to outlive the following `next()` call, copy what you need out of it
//! first (e.g. `allocator.dupe(u8, event.body.object.get("delta").?.string)`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const client_mod = @import("client.zig");
const types = @import("types.zig");
const sse = @import("sse.zig");

const redirect_buf_len = 8 * 1024;

/// Result of opening a streaming request: either the stream is ready to
/// iterate, or the server rejected the request outright (auth, validation,
/// unsupported_parameter, ...) with the shared JSON error envelope instead
/// of an SSE body.
pub fn StreamOpenResult(comptime StreamT: type) type {
    return union(enum) {
        ok: *StreamT,
        api_error: std.json.Parsed(types.ErrorEnvelope),

        pub fn deinit(self: @This()) void {
            switch (self) {
                .ok => |s| s.deinit(),
                .api_error => |p| p.deinit(),
            }
        }
    };
}

/// Shared plumbing for opening a POST+SSE request. On success, fills in
/// `req`/`response`/`transfer_buf` on `self` (which must already be
/// allocated at a stable address) and returns `null`. On a non-2xx
/// response, cleans up everything it opened and returns the parsed error
/// envelope.
fn openSseRequest(
    self_allocator: Allocator,
    client: *client_mod.Client,
    url: []const u8,
    body: []const u8,
    req_out: *std.http.Client.Request,
    response_out: *std.http.Client.Response,
    transfer_buf_out: *[]u8,
) !?std.json.Parsed(types.ErrorEnvelope) {
    const auth_value = try client.authHeaderValue();
    defer client.allocator.free(auth_value);

    const uri = try std.Uri.parse(url);

    req_out.* = try client.http.request(.POST, uri, .{
        .headers = .{
            .authorization = .{ .override = auth_value },
            .content_type = .{ .override = "application/json" },
            // See client.zig's requestJson: force identity encoding since the
            // SSE line reader does not decompress the response body.
            .accept_encoding = .{ .override = "identity" },
        },
    });
    errdefer req_out.deinit();

    const mutable_body = try client.allocator.dupe(u8, body);
    defer client.allocator.free(mutable_body);
    try req_out.sendBodyComplete(mutable_body);

    var redirect_buf: [redirect_buf_len]u8 = undefined;
    response_out.* = try req_out.receiveHead(&redirect_buf);

    transfer_buf_out.* = try self_allocator.alloc(u8, client.io_buffer_bytes);
    errdefer self_allocator.free(transfer_buf_out.*);

    if (response_out.head.status.class() == .success) return null;

    const body_reader = response_out.reader(transfer_buf_out.*);
    var aw: Writer.Allocating = .init(self_allocator);
    defer aw.deinit();
    _ = body_reader.streamRemaining(&aw.writer) catch |err| switch (err) {
        error.ReadFailed => return response_out.bodyErr().?,
        else => |e| return e,
    };

    const parsed = try std.json.parseFromSlice(
        types.ErrorEnvelope,
        self_allocator,
        aw.written(),
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    return parsed;
}

/// Iterator over `POST /v1/responses` (`stream: true`) named SSE events.
pub const ResponseStream = struct {
    client: *client_mod.Client,
    url: []const u8,
    req: std.http.Client.Request,
    response: std.http.Client.Response,
    transfer_buf: []u8,
    body_reader: *std.Io.Reader,
    arena: std.heap.ArenaAllocator,

    pub fn open(client: *client_mod.Client, url: []const u8, body: []const u8) !StreamOpenResult(ResponseStream) {
        const allocator = client.allocator;
        const self = try allocator.create(ResponseStream);
        errdefer allocator.destroy(self);

        self.client = client;
        self.url = try allocator.dupe(u8, url);
        errdefer allocator.free(self.url);
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();

        const maybe_err = try openSseRequest(allocator, client, self.url, body, &self.req, &self.response, &self.transfer_buf);
        if (maybe_err) |parsed_err| {
            self.req.deinit();
            allocator.free(self.transfer_buf);
            self.arena.deinit();
            allocator.free(self.url);
            allocator.destroy(self);
            return .{ .api_error = parsed_err };
        }

        self.body_reader = self.response.reader(self.transfer_buf);
        return .{ .ok = self };
    }

    /// Returns the next named SSE event, or `null` once the stream ends
    /// (after `response.completed`/`response.failed`, the server closes
    /// the connection).
    pub fn next(self: *ResponseStream) !?types.ResponseStreamEvent {
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();

        const raw = (try sse.readEvent(a, self.body_reader)) orelse return null;
        const value = try std.json.parseFromSliceLeaky(std.json.Value, a, raw.data, .{});
        return .{ .event_name = raw.event_name orelse "", .body = value };
    }

    pub fn deinit(self: *ResponseStream) void {
        const allocator = self.client.allocator;
        self.req.deinit();
        allocator.free(self.transfer_buf);
        self.arena.deinit();
        allocator.free(self.url);
        allocator.destroy(self);
    }
};

/// Iterator over `POST /v1/chat/completions` (`stream: true`, agentic
/// tiers) `chat.completion.chunk` events, ending on a literal `[DONE]`.
pub const ChatCompletionStream = struct {
    client: *client_mod.Client,
    url: []const u8,
    req: std.http.Client.Request,
    response: std.http.Client.Response,
    transfer_buf: []u8,
    body_reader: *std.Io.Reader,
    arena: std.heap.ArenaAllocator,
    done: bool = false,

    pub fn open(client: *client_mod.Client, url: []const u8, body: []const u8) !StreamOpenResult(ChatCompletionStream) {
        const allocator = client.allocator;
        const self = try allocator.create(ChatCompletionStream);
        errdefer allocator.destroy(self);

        self.client = client;
        self.url = try allocator.dupe(u8, url);
        errdefer allocator.free(self.url);
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();
        self.done = false;

        const maybe_err = try openSseRequest(allocator, client, self.url, body, &self.req, &self.response, &self.transfer_buf);
        if (maybe_err) |parsed_err| {
            self.req.deinit();
            allocator.free(self.transfer_buf);
            self.arena.deinit();
            allocator.free(self.url);
            allocator.destroy(self);
            return .{ .api_error = parsed_err };
        }

        self.body_reader = self.response.reader(self.transfer_buf);
        return .{ .ok = self };
    }

    /// Returns the next chunk, or `null` after the literal `data: [DONE]`
    /// line (or a clean end-of-stream, defensively).
    pub fn next(self: *ChatCompletionStream) !?types.ChatCompletionChunk {
        if (self.done) return null;
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();

        const raw = (try sse.readEvent(a, self.body_reader)) orelse return null;
        if (std.mem.eql(u8, raw.data, "[DONE]")) {
            self.done = true;
            return null;
        }
        return try std.json.parseFromSliceLeaky(types.ChatCompletionChunk, a, raw.data, .{
            .ignore_unknown_fields = true,
        });
    }

    pub fn deinit(self: *ChatCompletionStream) void {
        const allocator = self.client.allocator;
        self.req.deinit();
        allocator.free(self.transfer_buf);
        self.arena.deinit();
        allocator.free(self.url);
        allocator.destroy(self);
    }
};

/// Iterator over the provider-qualified passthrough streaming shape. Chunks are
/// the raw upstream OpenAI-compatible JSON (see
/// `types.PassthroughChatCompletionRequest`), left untyped for the same
/// reason the non-streaming passthrough response is untyped.
pub const PassthroughStream = struct {
    client: *client_mod.Client,
    url: []const u8,
    req: std.http.Client.Request,
    response: std.http.Client.Response,
    transfer_buf: []u8,
    body_reader: *std.Io.Reader,
    arena: std.heap.ArenaAllocator,
    done: bool = false,

    pub fn open(client: *client_mod.Client, url: []const u8, body: []const u8) !StreamOpenResult(PassthroughStream) {
        const allocator = client.allocator;
        const self = try allocator.create(PassthroughStream);
        errdefer allocator.destroy(self);

        self.client = client;
        self.url = try allocator.dupe(u8, url);
        errdefer allocator.free(self.url);
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();
        self.done = false;

        const maybe_err = try openSseRequest(allocator, client, self.url, body, &self.req, &self.response, &self.transfer_buf);
        if (maybe_err) |parsed_err| {
            self.req.deinit();
            allocator.free(self.transfer_buf);
            self.arena.deinit();
            allocator.free(self.url);
            allocator.destroy(self);
            return .{ .api_error = parsed_err };
        }

        self.body_reader = self.response.reader(self.transfer_buf);
        return .{ .ok = self };
    }

    pub fn next(self: *PassthroughStream) !?std.json.Value {
        if (self.done) return null;
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();

        const raw = (try sse.readEvent(a, self.body_reader)) orelse return null;
        if (std.mem.eql(u8, raw.data, "[DONE]")) {
            self.done = true;
            return null;
        }
        return try std.json.parseFromSliceLeaky(std.json.Value, a, raw.data, .{});
    }

    pub fn deinit(self: *PassthroughStream) void {
        const allocator = self.client.allocator;
        self.req.deinit();
        allocator.free(self.transfer_buf);
        self.arena.deinit();
        allocator.free(self.url);
        allocator.destroy(self);
    }
};
