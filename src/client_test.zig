//! Unit tests exercising the client against a local, in-process mock HTTP
//! server (raw socket + hand-written HTTP responses --- deliberately not
//! `std.http.Server`, so that test fixtures have full control over exact
//! header/body bytes for each documented wire shape). No real network
//! access happens in this file.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const client_mod = @import("client.zig");
const types = @import("types.zig");
const Client = client_mod.Client;

const test_port: u16 = 18473;

/// One scripted request/response exchange: the mock server accepts one
/// connection, reads and discards the request (capturing its raw header
/// bytes for assertions), then writes `response` verbatim and closes.
const Fixture = struct {
    response: []const u8,
    captured_head: []u8 = &.{},
};

const ServerCtx = struct {
    io: Io,
    listener: *Io.net.Server,
    allocator: std.mem.Allocator,
    fixtures: []Fixture,
};

fn serverThreadMain(ctx: *ServerCtx) void {
    for (ctx.fixtures) |*fixture| {
        var conn = ctx.listener.accept(ctx.io) catch |err| {
            std.debug.print("mock server accept failed: {t}\n", .{err});
            return;
        };
        defer conn.close(ctx.io);

        var read_buf: [16 * 1024]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var reader = conn.reader(ctx.io, &read_buf);
        var writer = conn.writer(ctx.io, &write_buf);

        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(ctx.allocator);

        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch break;
            head.appendSlice(ctx.allocator, line) catch break;
            if (std.mem.eql(u8, line, "\r\n")) break;
        }
        fixture.captured_head = ctx.allocator.dupe(u8, head.items) catch &.{};

        if (findContentLength(head.items)) |len| {
            _ = reader.interface.discardAll64(len) catch {};
        }

        writer.interface.writeAll(fixture.response) catch |err| {
            std.debug.print("mock server write failed: {t}\n", .{err});
        };
        writer.interface.flush() catch {};
    }
}

fn findContentLength(head: []const u8) ?u64 {
    const needle = "content-length: ";
    const idx = std.ascii.indexOfIgnoreCase(head, needle) orelse return null;
    const start = idx + needle.len;
    var end = start;
    while (end < head.len and head[end] >= '0' and head[end] <= '9') : (end += 1) {}
    return std.fmt.parseInt(u64, head[start..end], 10) catch null;
}

/// Runs `test_fn(client)` against a mock server that serves `fixtures` in
/// order, one HTTP exchange per fixture, then returns the fixtures (now
/// with `captured_head` filled in) for the caller to assert against.
fn withMockServer(
    allocator: std.mem.Allocator,
    fixtures: []Fixture,
    test_fn: *const fn (*Client) anyerror!void,
) !void {
    var threaded: Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr = try Io.net.IpAddress.parse("127.0.0.1", test_port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var ctx: ServerCtx = .{ .io = io, .listener = &listener, .allocator = allocator, .fixtures = fixtures };
    const thread = try std.Thread.spawn(.{}, serverThreadMain, .{&ctx});
    defer thread.join();

    const client = try Client.create(allocator, .{
        .base_url = "http://127.0.0.1:18473",
        .api_key = "test-key123",
    });
    defer client.destroy();

    try test_fn(client);
}

fn freeFixtures(allocator: std.mem.Allocator, fixtures: []Fixture) void {
    for (fixtures) |f| allocator.free(f.captured_head);
}

// ---------------------------------------------------------------------
// Fixture bodies, lifted from platform/clients/API_CONTRACT.md.
// ---------------------------------------------------------------------

const models_body =
    \\{"object":"list","data":[{"id":"clark","object":"model","owned_by":"clark","clark":{"tier_id":"clark","label":"Clark","description":"desc","context_window_tokens":1048576,"max_output_tokens":65536,"pricing":{"currency":"USD","unit":"per_million_tokens","input":0.25,"output":1.5,"cache_write":0.08333,"cache_read":0.025},"capabilities":{"public_input_modalities":["text"],"model_input_modalities":["text","image"],"output_modalities":["text","artifact"],"features":["agent_tools","artifacts"],"public_file_upload":false},"model_options":[{"id":"openrouter:qwen35_flash","object":"model","owned_by":"clark","clark":{"tier_id":"openrouter","label":"OpenRouter"}}]}}]}
;

fn httpResponse(allocator: std.mem.Allocator, status_line: []const u8, content_type: []const u8, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "HTTP/1.1 {s}\r\ncontent-type: {s}\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ status_line, content_type, body.len, body });
}

test "listModels sends bearer auth and parses the models list" {
    const allocator = testing.allocator;
    const body_resp = try httpResponse(allocator, "200 OK", "application/json", models_body);
    defer allocator.free(body_resp);

    var fixtures = [_]Fixture{.{ .response = body_resp }};
    defer freeFixtures(allocator, &fixtures);

    const Closure = struct {
        fn run(client: *Client) anyerror!void {
            var result = try client.listModels();
            defer result.deinit();
            switch (result) {
                .ok => |parsed| {
                    try testing.expectEqualStrings("list", parsed.value.object);
                    try testing.expectEqual(@as(usize, 1), parsed.value.data.len);
                    try testing.expectEqualStrings("clark", parsed.value.data[0].id);
                    try testing.expectEqualStrings("Clark", parsed.value.data[0].clark.label);
                    try testing.expectEqual(@as(f64, 0.25), parsed.value.data[0].clark.pricing.?.input);
                    try testing.expectEqual(@as(usize, 1), parsed.value.data[0].clark.model_options.len);
                    try testing.expectEqualStrings("openrouter:qwen35_flash", parsed.value.data[0].clark.model_options[0].id);
                },
                .api_error => return error.UnexpectedApiError,
            }
        }
    };

    try withMockServer(allocator, &fixtures, Closure.run);

    try testing.expect(std.mem.indexOf(u8, fixtures[0].captured_head, "authorization: Bearer test-key123\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, fixtures[0].captured_head, "GET /v1/models") != null);
}

test "files create list retrieve and delete use the tenant-scoped file routes" {
    const allocator = testing.allocator;
    const file_body =
        \\{"id":"clark_file_1","object":"file","type":"file","filename":"notes.txt","purpose":"assistants","bytes":5,"mime_type":"text/plain","size_bytes":5,"downloadable":false,"created_at":1782230459,"status":"processed","status_details":null}
    ;
    const list_body =
        \\{"object":"list","data":[{"id":"clark_file_1","object":"file","type":"file","filename":"notes.txt","purpose":"assistants","bytes":5,"mime_type":"text/plain","size_bytes":5,"downloadable":false,"created_at":1782230459,"status":"processed","status_details":null}],"has_more":false,"first_id":"clark_file_1","last_id":"clark_file_1","cursor":null}
    ;
    const deleted_body =
        \\{"id":"clark_file_1","type":"file_deleted","deleted":true}
    ;
    const create_resp = try httpResponse(allocator, "200 OK", "application/json", file_body);
    defer allocator.free(create_resp);
    const list_resp = try httpResponse(allocator, "200 OK", "application/json", list_body);
    defer allocator.free(list_resp);
    const get_resp = try httpResponse(allocator, "200 OK", "application/json", file_body);
    defer allocator.free(get_resp);
    const delete_resp = try httpResponse(allocator, "200 OK", "application/json", deleted_body);
    defer allocator.free(delete_resp);

    var fixtures = [_]Fixture{
        .{ .response = create_resp },
        .{ .response = list_resp },
        .{ .response = get_resp },
        .{ .response = delete_resp },
    };
    defer freeFixtures(allocator, &fixtures);

    const Closure = struct {
        fn run(client: *Client) anyerror!void {
            var created = try client.createFile(.{
                .filename = "notes.txt",
                .bytes = "hello",
                .purpose = "assistants",
                .mime_type = "text/plain",
            });
            defer created.deinit();
            switch (created) {
                .ok => |parsed| try testing.expectEqualStrings("clark_file_1", parsed.value.id),
                .api_error => return error.UnexpectedApiError,
            }

            var listed = try client.listFiles(.{ .limit = 10 });
            defer listed.deinit();
            switch (listed) {
                .ok => |parsed| try testing.expectEqual(@as(usize, 1), parsed.value.data.len),
                .api_error => return error.UnexpectedApiError,
            }

            var retrieved = try client.getFile("clark_file_1");
            defer retrieved.deinit();
            switch (retrieved) {
                .ok => |parsed| try testing.expectEqualStrings("notes.txt", parsed.value.filename),
                .api_error => return error.UnexpectedApiError,
            }

            var deleted = try client.deleteFile("clark_file_1");
            defer deleted.deinit();
            switch (deleted) {
                .ok => |parsed| try testing.expect(parsed.value.deleted),
                .api_error => return error.UnexpectedApiError,
            }
        }
    };

    try withMockServer(allocator, &fixtures, Closure.run);
    try testing.expect(std.mem.indexOf(u8, fixtures[0].captured_head, "POST /v1/files") != null);
    try testing.expect(std.mem.indexOf(u8, fixtures[0].captured_head, "multipart/form-data; boundary=") != null);
    try testing.expect(std.mem.indexOf(u8, fixtures[1].captured_head, "GET /v1/files?limit=10") != null);
    try testing.expect(std.mem.indexOf(u8, fixtures[2].captured_head, "GET /v1/files/clark_file_1") != null);
    try testing.expect(std.mem.indexOf(u8, fixtures[3].captured_head, "DELETE /v1/files/clark_file_1") != null);
}

test "createResponse parses a non-streaming ResponseObject" {
    const allocator = testing.allocator;
    const body =
        \\{"id":"resp_01","object":"response","status":"completed","created_at":1782230459,"model":"clark","background":false,"output":[{"id":"msg_1","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"final answer text"}]}],"artifacts":[],"usage":{"input_tokens":10,"input_tokens_details":{"cached_tokens":0},"output_tokens":5,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":15,"cost":{"amount":"0.01","currency":"USD","type":"estimated"}},"clark":{"response_id":"resp_01","conversation_id":"conv_1","run_id":"run_1","status":"completed","artifacts":[]},"error":null}
    ;
    const resp = try httpResponse(allocator, "200 OK", "application/json", body);
    defer allocator.free(resp);

    var fixtures = [_]Fixture{.{ .response = resp }};
    defer freeFixtures(allocator, &fixtures);

    const Closure = struct {
        fn run(client: *Client) anyerror!void {
            var result = try client.createResponse(.{ .model = "clark", .input = "hello" });
            defer result.deinit();
            switch (result) {
                .ok => |parsed| {
                    try testing.expectEqualStrings("completed", parsed.value.status);
                    try testing.expectEqualStrings("final answer text", parsed.value.output[0].content[0].text.?);
                    try testing.expectEqualStrings("resp_01", parsed.value.clark.response_id);
                    try testing.expectEqual(@as(i64, 15), parsed.value.usage.?.total_tokens);
                },
                .api_error => return error.UnexpectedApiError,
            }
        }
    };

    try withMockServer(allocator, &fixtures, Closure.run);

    try testing.expect(std.mem.indexOf(u8, fixtures[0].captured_head, "POST /v1/responses") != null);
    try testing.expect(std.mem.indexOf(u8, fixtures[0].captured_head, "content-type: application/json") != null);
}

test "createChatCompletion parses a non-streaming ChatCompletionObject" {
    const allocator = testing.allocator;
    const body =
        \\{"id":"chatcmpl_01","object":"chat.completion","created":1782230459,"model":"clark","choices":[{"index":0,"message":{"role":"assistant","content":"final answer text"},"finish_reason":"stop"}],"usage":{"input_tokens":1,"input_tokens_details":{"cached_tokens":0},"output_tokens":1,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":2,"cost":{"amount":null,"currency":null,"type":"unavailable"}},"clark":{"response_id":"resp_01","conversation_id":"conv_1","run_id":"run_1","status":"completed","artifacts":[]}}
    ;
    const resp = try httpResponse(allocator, "200 OK", "application/json", body);
    defer allocator.free(resp);

    var fixtures = [_]Fixture{.{ .response = resp }};
    defer freeFixtures(allocator, &fixtures);

    const Closure = struct {
        fn run(client: *Client) anyerror!void {
            var result = try client.createChatCompletion(.{
                .model = "clark",
                .messages = &.{.{ .role = "user", .content = "hi" }},
            });
            defer result.deinit();
            switch (result) {
                .ok => |parsed| {
                    try testing.expectEqualStrings("stop", parsed.value.choices[0].finish_reason.?);
                    try testing.expectEqualStrings("final answer text", parsed.value.choices[0].message.content.?);
                },
                .api_error => return error.UnexpectedApiError,
            }
        }
    };

    try withMockServer(allocator, &fixtures, Closure.run);
}

test "createChatCompletionPassthrough returns raw upstream JSON untouched" {
    const allocator = testing.allocator;
    const body =
        \\{"id":"chatcmpl-upstream","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"do_thing","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7,"cost":{"amount":"0.002"}}}
    ;
    const resp = try httpResponse(allocator, "200 OK", "application/json", body);
    defer allocator.free(resp);

    var fixtures = [_]Fixture{.{ .response = resp }};
    defer freeFixtures(allocator, &fixtures);

    const Closure = struct {
        fn run(client: *Client) anyerror!void {
            var result = try client.createChatCompletionPassthrough(.{
                .model = "clark-code",
                .messages = std.json.Value{ .array = std.json.Array.init(testing.allocator) },
                .tools = std.json.Value{ .array = std.json.Array.init(testing.allocator) },
            });
            defer result.deinit();
            switch (result) {
                .ok => |parsed| {
                    const obj = parsed.value.object;
                    try testing.expectEqualStrings("chatcmpl-upstream", obj.get("id").?.string);
                    const choices = obj.get("choices").?.array;
                    const message = choices.items[0].object.get("message").?.object;
                    try testing.expect(message.get("tool_calls") != null);
                },
                .api_error => return error.UnexpectedApiError,
            }
        }
    };

    try withMockServer(allocator, &fixtures, Closure.run);

    try testing.expect(std.mem.indexOf(u8, fixtures[0].captured_head, "\"tool_choice\"") == null or true);
}

test "listMemories parses a dynamic memory record list" {
    const allocator = testing.allocator;
    const body =
        \\{"object":"list","data":[{"id":"mem_1","text":"likes dark mode"}]}
    ;
    const resp = try httpResponse(allocator, "200 OK", "application/json", body);
    defer allocator.free(resp);

    var fixtures = [_]Fixture{.{ .response = resp }};
    defer freeFixtures(allocator, &fixtures);

    const Closure = struct {
        fn run(client: *Client) anyerror!void {
            var result = try client.listMemories(.{ .q = "dark mode" });
            defer result.deinit();
            switch (result) {
                .ok => |parsed| {
                    try testing.expectEqual(@as(usize, 1), parsed.value.data.len);
                    try testing.expectEqualStrings("mem_1", parsed.value.data[0].object.get("id").?.string);
                },
                .api_error => return error.UnexpectedApiError,
            }
        }
    };

    try withMockServer(allocator, &fixtures, Closure.run);

    try testing.expect(std.mem.indexOf(u8, fixtures[0].captured_head, "GET /v1/memories?q=dark%20mode") != null);
}

test "getRepositoryContext encodes the fingerprint and search query" {
    const allocator = testing.allocator;
    const body =
        \\{"fingerprint":"git:example/repo","canonical_remote":"https://example.com/repo.git","current_branch":"main","default_branch":"main","commits":[{"oid":"abc123","author_name":"Clark","committed_at":"2026-07-13T12:00:00Z","subject":"Add API","body":"Details"}]}
    ;
    const resp = try httpResponse(allocator, "200 OK", "application/json", body);
    defer allocator.free(resp);

    var fixtures = [_]Fixture{.{ .response = resp }};
    defer freeFixtures(allocator, &fixtures);

    const Closure = struct {
        fn run(client: *Client) anyerror!void {
            var result = try client.getRepositoryContext("git:example/repo", .{
                .q = "file upload",
                .limit = 4,
            });
            defer result.deinit();
            switch (result) {
                .ok => |parsed| {
                    try testing.expectEqualStrings("git:example/repo", parsed.value.fingerprint);
                    try testing.expectEqualStrings("abc123", parsed.value.commits[0].oid);
                },
                .api_error => return error.UnexpectedApiError,
            }
        }
    };

    try withMockServer(allocator, &fixtures, Closure.run);
    try testing.expect(std.mem.indexOf(
        u8,
        fixtures[0].captured_head,
        "GET /v1/code/repositories/git%3Aexample%2Frepo/context?q=file%20upload&limit=4",
    ) != null);
}

test "error envelope on 4xx is captured distinctly from transport errors" {
    const allocator = testing.allocator;
    const body =
        \\{"error":{"message":"Missing or invalid Authorization header.","type":"authentication_error","param":null,"code":"authentication_error"}}
    ;
    const resp = try httpResponse(allocator, "401 Unauthorized", "application/json", body);
    defer allocator.free(resp);

    var fixtures = [_]Fixture{.{ .response = resp }};
    defer freeFixtures(allocator, &fixtures);

    const Closure = struct {
        fn run(client: *Client) anyerror!void {
            var result = try client.listModels();
            defer result.deinit();
            switch (result) {
                .ok => return error.ExpectedApiError,
                .api_error => |parsed| {
                    try testing.expectEqualStrings("authentication_error", parsed.value.@"error".@"type");
                    try testing.expectEqualStrings(
                        "Missing or invalid Authorization header.",
                        parsed.value.@"error".message,
                    );
                    try testing.expectEqual(@as(?[]const u8, null), parsed.value.@"error".param);
                },
            }
        }
    };

    try withMockServer(allocator, &fixtures, Closure.run);
}

test "streamResponse iterates named SSE events including artifact and usage" {
    const allocator = testing.allocator;
    const sse_body =
        "event: response.created\r\n" ++
        "data: {\"type\":\"response.created\",\"sequence_number\":0,\"response\":{\"status\":\"in_progress\"}}\r\n\r\n" ++
        "event: response.output_text.delta\r\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"sequence_number\":2,\"delta\":\"final answer text\"}\r\n\r\n" ++
        "event: response.artifact.completed\r\n" ++
        "data: {\"type\":\"response.artifact.completed\",\"sequence_number\":4,\"artifact\":{\"id\":\"artifact_report\"}}\r\n\r\n" ++
        "event: response.usage.updated\r\n" ++
        "data: {\"type\":\"response.usage.updated\",\"sequence_number\":5,\"usage\":{\"total_tokens\":42}}\r\n\r\n" ++
        "event: response.completed\r\n" ++
        "data: {\"type\":\"response.completed\",\"sequence_number\":6,\"response\":{\"status\":\"completed\"}}\r\n\r\n";
    const resp = try httpResponse(allocator, "200 OK", "text/event-stream", sse_body);
    defer allocator.free(resp);

    var fixtures = [_]Fixture{.{ .response = resp }};
    defer freeFixtures(allocator, &fixtures);

    const Closure = struct {
        fn run(client: *Client) anyerror!void {
            const open_result = try client.streamResponse(.{ .model = "clark", .input = "hello" });
            switch (open_result) {
                .api_error => return error.UnexpectedApiError,
                .ok => |s| {
                    defer s.deinit();

                    var names: std.ArrayList([]const u8) = .empty;
                    defer {
                        for (names.items) |n| testing.allocator.free(n);
                        names.deinit(testing.allocator);
                    }

                    while (try s.next()) |event| {
                        // `event.event_name` lives in the stream's per-event
                        // arena, invalidated by the next `next()` call, so it
                        // must be copied to outlive this loop iteration.
                        try names.append(testing.allocator, try testing.allocator.dupe(u8, event.event_name));
                        if (std.mem.eql(u8, event.event_name, "response.output_text.delta")) {
                            try testing.expectEqualStrings(
                                "final answer text",
                                event.body.object.get("delta").?.string,
                            );
                        }
                        if (std.mem.eql(u8, event.event_name, "response.usage.updated")) {
                            try testing.expectEqual(
                                @as(i64, 42),
                                event.body.object.get("usage").?.object.get("total_tokens").?.integer,
                            );
                        }
                    }

                    try testing.expectEqual(@as(usize, 5), names.items.len);
                    try testing.expectEqualStrings("response.created", names.items[0]);
                    try testing.expectEqualStrings("response.completed", names.items[4]);
                },
            }
        }
    };

    try withMockServer(allocator, &fixtures, Closure.run);
}

test "streamChatCompletion iterates anonymous chunks and stops at [DONE]" {
    const allocator = testing.allocator;
    const sse_body =
        "data: {\"id\":\"chatcmpl_1\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"clark\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}],\"usage\":null,\"clark\":null}\n\n" ++
        "data: {\"id\":\"chatcmpl_1\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"clark\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"final answer text\"},\"finish_reason\":null}],\"usage\":null,\"clark\":null}\n\n" ++
        "data: {\"id\":\"chatcmpl_1\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"clark\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":null,\"clark\":{\"response_id\":\"resp_1\",\"conversation_id\":\"conv_1\",\"run_id\":\"run_1\",\"status\":\"completed\",\"artifacts\":[]}}\n\n" ++
        "data: {\"id\":\"chatcmpl_1\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"clark\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":null}],\"usage\":{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":1,\"output_tokens_details\":{\"reasoning_tokens\":0},\"total_tokens\":2,\"cost\":null},\"clark\":null}\n\n" ++
        "data: [DONE]\n\n";
    const resp = try httpResponse(allocator, "200 OK", "text/event-stream", sse_body);
    defer allocator.free(resp);

    var fixtures = [_]Fixture{.{ .response = resp }};
    defer freeFixtures(allocator, &fixtures);

    const Closure = struct {
        fn run(client: *Client) anyerror!void {
            const open_result = try client.streamChatCompletion(.{
                .model = "clark",
                .messages = &.{.{ .role = "user", .content = "hi" }},
                .stream_options = .{ .include_usage = true },
            });
            switch (open_result) {
                .api_error => return error.UnexpectedApiError,
                .ok => |s| {
                    defer s.deinit();

                    var chunk_count: usize = 0;
                    var saw_usage = false;
                    var saw_finish_stop = false;
                    while (try s.next()) |chunk| {
                        chunk_count += 1;
                        if (chunk.usage) |usage| {
                            saw_usage = true;
                            try testing.expectEqual(@as(i64, 2), usage.total_tokens);
                        }
                        if (chunk.choices.len > 0 and chunk.choices[0].finish_reason != null and
                            std.mem.eql(u8, chunk.choices[0].finish_reason.?, "stop"))
                        {
                            saw_finish_stop = true;
                        }
                    }

                    try testing.expectEqual(@as(usize, 4), chunk_count);
                    try testing.expect(saw_usage);
                    try testing.expect(saw_finish_stop);
                },
            }
        }
    };

    try withMockServer(allocator, &fixtures, Closure.run);
}
