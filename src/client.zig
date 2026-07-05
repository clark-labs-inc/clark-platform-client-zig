//! HTTP client for the Clark Platform API, built on `std.http.Client`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const types = @import("types.zig");
const stream = @import("stream.zig");

/// Non-transport failure: the server responded with a well-formed
/// `{"error": {...}}` envelope (auth, validation, upstream, server errors).
/// Kept separate from ordinary Zig `error{...}` unions --- which this
/// library reserves for transport/JSON-decoding failures (connection
/// refused, malformed body, out of memory, etc.) --- per the contract's
/// error-shape section.
pub fn ApiResult(comptime T: type) type {
    return union(enum) {
        ok: std.json.Parsed(T),
        api_error: std.json.Parsed(types.ErrorEnvelope),

        pub fn deinit(self: @This()) void {
            switch (self) {
                .ok => |p| p.deinit(),
                .api_error => |p| p.deinit(),
            }
        }
    };
}

fn isQueryUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
}

fn percentEncodeQueryValue(w: *Writer, raw: []const u8) !void {
    try std.Uri.Component.percentEncode(w, raw, isQueryUnreserved);
}

pub const Client = struct {
    allocator: Allocator,
    threaded: Io.Threaded,
    http: std.http.Client,
    base_url: []const u8,
    api_key: []const u8,
    /// Size of the buffer used to decode each HTTP response body. For
    /// non-streaming calls this only bounds per-read chunk size (the full
    /// body is copied into a growable buffer regardless). For SSE streams
    /// it also bounds the longest single line (i.e. the longest single SSE
    /// `data:` line) that can be read at once --- see README for sizing
    /// guidance if you expect very large single-shot deltas.
    io_buffer_bytes: usize,

    pub const Options = struct {
        base_url: []const u8 = "https://www.clarkchat.com",
        api_key: []const u8,
        io_buffer_bytes: usize = 256 * 1024,
    };

    /// `std.http.Client` and the `std.Io.Threaded` backing it are
    /// self-referential (the client stores an `Io` pointing back at the
    /// `Threaded` value), so `Client` must live at a stable address for its
    /// whole lifetime. `create`/`destroy` heap-allocate it for that reason
    /// --- do not `Client{...}` it onto the stack or copy it by value.
    pub fn create(allocator: Allocator, options: Options) !*Client {
        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);

        const base_url = try allocator.dupe(u8, options.base_url);
        errdefer allocator.free(base_url);
        const api_key = try allocator.dupe(u8, options.api_key);
        errdefer allocator.free(api_key);

        self.* = .{
            .allocator = allocator,
            .threaded = .init(allocator, .{}),
            .http = undefined,
            .base_url = base_url,
            .api_key = api_key,
            .io_buffer_bytes = options.io_buffer_bytes,
        };
        self.http = .{ .allocator = allocator, .io = self.threaded.io() };
        return self;
    }

    pub fn destroy(self: *Client) void {
        self.http.deinit();
        self.threaded.deinit();
        self.allocator.free(self.base_url);
        self.allocator.free(self.api_key);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Exposed (not just used internally) so `stream.zig` can build
    /// request URLs identically for streaming endpoints, which must drive
    /// the request/response lifecycle themselves instead of going through
    /// `requestJson`.
    pub fn buildUrl(self: *Client, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
    }

    pub fn authHeaderValue(self: *Client) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
    }

    /// Performs a JSON-in/JSON-out request against a non-streaming
    /// endpoint and parses the body as either `T` (2xx) or the shared
    /// error envelope (non-2xx).
    fn requestJson(
        self: *Client,
        comptime T: type,
        method: std.http.Method,
        url: []const u8,
        json_body: ?[]const u8,
    ) !ApiResult(T) {
        const auth_value = try self.authHeaderValue();
        defer self.allocator.free(auth_value);

        const uri = try std.Uri.parse(url);

        var req = try self.http.request(method, uri, .{
            .headers = .{
                .authorization = .{ .override = auth_value },
                .content_type = if (json_body != null) .{ .override = "application/json" } else .default,
                // Force uncompressed responses. `response.reader()` (used below)
                // does not decompress — real upstreams (Cloudflare) happily
                // gzip/zstd the body when `Accept-Encoding` advertises support,
                // which corrupted JSON parsing in a live-network run even
                // though the local mock-server unit tests never exercise
                // content-encoding negotiation.
                .accept_encoding = .{ .override = "identity" },
            },
        });
        defer req.deinit();

        if (json_body) |body| {
            const mutable_body = try self.allocator.dupe(u8, body);
            defer self.allocator.free(mutable_body);
            try req.sendBodyComplete(mutable_body);
        } else {
            try req.sendBodiless();
        }

        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        const transfer_buf = try self.allocator.alloc(u8, self.io_buffer_bytes);
        defer self.allocator.free(transfer_buf);
        const body_reader = response.reader(transfer_buf);

        var aw: Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        _ = body_reader.streamRemaining(&aw.writer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };
        const body_bytes = aw.written();

        if (response.head.status.class() == .success) {
            const parsed = try std.json.parseFromSlice(T, self.allocator, body_bytes, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
            return .{ .ok = parsed };
        }

        const parsed_err = try std.json.parseFromSlice(types.ErrorEnvelope, self.allocator, body_bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        return .{ .api_error = parsed_err };
    }

    // -------------------------------------------------------------
    // GET /v1/models
    // -------------------------------------------------------------

    pub fn listModels(self: *Client) !ApiResult(types.ModelsList) {
        const url = try self.buildUrl("/v1/models");
        defer self.allocator.free(url);
        return self.requestJson(types.ModelsList, .GET, url, null);
    }

    // -------------------------------------------------------------
    // POST /v1/responses, GET /v1/responses/{id}, GET .../events
    // -------------------------------------------------------------

    pub fn createResponse(self: *Client, request: types.ResponseCreateRequest) !ApiResult(types.ResponseObject) {
        std.debug.assert(!request.stream); // use streamResponse for stream: true
        const url = try self.buildUrl("/v1/responses");
        defer self.allocator.free(url);
        const body = try std.json.Stringify.valueAlloc(self.allocator, request, .{});
        defer self.allocator.free(body);
        return self.requestJson(types.ResponseObject, .POST, url, body);
    }

    pub fn getResponse(self: *Client, response_id: []const u8) !ApiResult(types.ResponseObject) {
        const path = try std.fmt.allocPrint(self.allocator, "/v1/responses/{s}", .{response_id});
        defer self.allocator.free(path);
        const url = try self.buildUrl(path);
        defer self.allocator.free(url);
        return self.requestJson(types.ResponseObject, .GET, url, null);
    }

    pub fn listResponseEvents(
        self: *Client,
        response_id: []const u8,
        options: types.ListResponseEventsOptions,
    ) !ApiResult(types.ResponseEventsList) {
        var qs: Writer.Allocating = .init(self.allocator);
        defer qs.deinit();
        var first = true;

        if (options.after_seq) |v| {
            try appendQueryStart(&qs.writer, &first);
            try qs.writer.print("after_seq={d}", .{v});
        }
        if (options.limit) |v| {
            try appendQueryStart(&qs.writer, &first);
            try qs.writer.print("limit={d}", .{v});
        }
        if (options.types) |v| {
            try appendQueryStart(&qs.writer, &first);
            try qs.writer.writeAll("types=");
            try percentEncodeQueryValue(&qs.writer, v);
        }

        const path = try std.fmt.allocPrint(
            self.allocator,
            "/v1/responses/{s}/events{s}",
            .{ response_id, qs.written() },
        );
        defer self.allocator.free(path);
        const url = try self.buildUrl(path);
        defer self.allocator.free(url);
        return self.requestJson(types.ResponseEventsList, .GET, url, null);
    }

    /// Opens `POST /v1/responses` with `stream: true` and returns an
    /// iterator over the named SSE events. The contract notes that the
    /// full answer arrives as a single `response.output_text.delta`, not
    /// token-by-token, but this is still exposed as a stream for symmetry
    /// and future finer-grained deltas.
    pub fn streamResponse(
        self: *Client,
        request: types.ResponseCreateRequest,
    ) !stream.StreamOpenResult(stream.ResponseStream) {
        var streaming_request = request;
        streaming_request.stream = true;
        const url = try self.buildUrl("/v1/responses");
        defer self.allocator.free(url);
        const body = try std.json.Stringify.valueAlloc(self.allocator, streaming_request, .{});
        defer self.allocator.free(body);
        return stream.ResponseStream.open(self, url, body);
    }

    // -------------------------------------------------------------
    // POST /v1/chat/completions (agentic tiers)
    // -------------------------------------------------------------

    pub fn createChatCompletion(
        self: *Client,
        request: types.ChatCompletionCreateRequest,
    ) !ApiResult(types.ChatCompletionObject) {
        std.debug.assert(!request.stream);
        const url = try self.buildUrl("/v1/chat/completions");
        defer self.allocator.free(url);
        const body = try std.json.Stringify.valueAlloc(self.allocator, request, .{});
        defer self.allocator.free(body);
        return self.requestJson(types.ChatCompletionObject, .POST, url, body);
    }

    pub fn streamChatCompletion(
        self: *Client,
        request: types.ChatCompletionCreateRequest,
    ) !stream.StreamOpenResult(stream.ChatCompletionStream) {
        var streaming_request = request;
        streaming_request.stream = true;
        const url = try self.buildUrl("/v1/chat/completions");
        defer self.allocator.free(url);
        const body = try std.json.Stringify.valueAlloc(self.allocator, streaming_request, .{});
        defer self.allocator.free(body);
        return stream.ChatCompletionStream.open(self, url, body);
    }

    // -------------------------------------------------------------
    // POST /v1/chat/completions (clark-code passthrough tier)
    // -------------------------------------------------------------

    /// The `clark-code` passthrough tier returns the raw upstream
    /// OpenAI-compatible body, not a Clark `ChatCompletionObject` --- see
    /// the module doc on `types.PassthroughChatCompletionRequest`. Kept as
    /// a distinctly named method so callers can't accidentally parse a
    /// passthrough response as a Clark object.
    pub fn createChatCompletionPassthrough(
        self: *Client,
        request: types.PassthroughChatCompletionRequest,
    ) !ApiResult(std.json.Value) {
        std.debug.assert(!request.stream);
        const url = try self.buildUrl("/v1/chat/completions");
        defer self.allocator.free(url);
        const body = try std.json.Stringify.valueAlloc(self.allocator, request, .{});
        defer self.allocator.free(body);
        return self.requestJson(std.json.Value, .POST, url, body);
    }

    pub fn streamChatCompletionPassthrough(
        self: *Client,
        request: types.PassthroughChatCompletionRequest,
    ) !stream.StreamOpenResult(stream.PassthroughStream) {
        var streaming_request = request;
        streaming_request.stream = true;
        const url = try self.buildUrl("/v1/chat/completions");
        defer self.allocator.free(url);
        const body = try std.json.Stringify.valueAlloc(self.allocator, streaming_request, .{});
        defer self.allocator.free(body);
        return stream.PassthroughStream.open(self, url, body);
    }

    // -------------------------------------------------------------
    // GET /v1/memories
    // -------------------------------------------------------------

    pub fn listMemories(self: *Client, options: types.ListMemoriesOptions) !ApiResult(types.MemoriesList) {
        var qs: Writer.Allocating = .init(self.allocator);
        defer qs.deinit();
        var first = true;

        if (options.q) |v| {
            try appendQueryStart(&qs.writer, &first);
            try qs.writer.writeAll("q=");
            try percentEncodeQueryValue(&qs.writer, v);
        }
        if (options.tags) |v| {
            try appendQueryStart(&qs.writer, &first);
            try qs.writer.writeAll("tags=");
            try percentEncodeQueryValue(&qs.writer, v);
        }
        if (options.conversation_id) |v| {
            try appendQueryStart(&qs.writer, &first);
            try qs.writer.writeAll("conversation_id=");
            try percentEncodeQueryValue(&qs.writer, v);
        }

        const path = try std.fmt.allocPrint(self.allocator, "/v1/memories{s}", .{qs.written()});
        defer self.allocator.free(path);
        const url = try self.buildUrl(path);
        defer self.allocator.free(url);
        return self.requestJson(types.MemoriesList, .GET, url, null);
    }
};

fn appendQueryStart(w: *Writer, first: *bool) !void {
    try w.writeByte(if (first.*) '?' else '&');
    first.* = false;
}
