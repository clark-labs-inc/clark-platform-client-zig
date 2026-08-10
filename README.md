# clark_platform (Zig)

A typed, streaming-capable Zig client for the [Clark Platform
API](../API_CONTRACT.md), built entirely on `std.http.Client` /
`std.http.Server` --- no external dependencies. Targets **Zig 0.16.0**;
`std.http`/`std.Io` changed substantially across Zig versions, so this
package will not compile as-is on older or newer Zig without porting.

## Adding as a dependency

Source of truth is
[clark-labs-inc/clark-platform-client-zig](https://github.com/clark-labs-inc/clark-platform-client-zig)
(this directory is a mirror inside the Clark monorepo). Zig has no central
package registry, so dependencies are pinned by git URL + content hash. Add
it with:

```sh
zig fetch --save https://github.com/clark-labs-inc/clark-platform-client-zig/archive/<commit>.tar.gz
```

which writes both the pinned URL and its matching content hash into your
`build.zig.zon`. Do not copy a hash from another release.

Or, for local development against this monorepo directly, a path dependency
works too:

```zig
.dependencies = .{
    .clark_platform = .{
        .path = "../path/to/clark/platform/clients/zig",
    },
},
```

and wire the module into your target in `build.zig`:

```zig
const clark_platform = b.dependency("clark_platform", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("clark_platform", clark_platform.module("clark_platform"));
```

## Quickstart: agentic tiers (`clark`, `clark_max`, `openrouter:*`)

```zig
const std = @import("std");
const clark_platform = @import("clark_platform");

pub fn main(init: std.process.Init) !void {
    const client = try clark_platform.Client.create(init.gpa, .{
        .api_key = init.environ_map.get("CLARK_API_KEY").?,
        // .base_url defaults to https://www.clarkchat.com
    });
    defer client.destroy();

    var result = try client.createChatCompletion(.{
        .model = "clark",
        .messages = &.{.{ .role = "user", .content = "Summarize this repo's README." }},
    });
    defer result.deinit();

    switch (result) {
        .ok => |parsed| {
            std.debug.print("{s}\n", .{parsed.value.choices[0].message.content orelse ""});
        },
        .api_error => |parsed| {
            std.debug.print("error ({s}): {s}\n", .{
                parsed.value.@"error".@"type",
                parsed.value.@"error".message,
            });
        },
    }
}
```

`client.createResponse(...)` / `client.getResponse(response_id)` /
`client.listResponseEvents(response_id, .{})` follow the same
`ApiResult(T)` shape for `POST /v1/responses`, `GET /v1/responses/{id}`,
and `GET /v1/responses/{id}/events`. `client.listModels()` and
`client.listMemories(.{})` round out the core run surface.

### Files and repository context

Version 0.2 adds the platform resources that shipped after the original
client: tenant-scoped file upload/management and Clark Code repository
context lookup.

```zig
var uploaded = try client.createFile(.{
    .filename = "notes.txt",
    .bytes = notes_bytes,
    .purpose = "assistants",
    .mime_type = "text/plain",
});
defer uploaded.deinit();

var files = try client.listFiles(.{ .limit = 100 });
defer files.deinit();

var context = try client.getRepositoryContext(repository_fingerprint, .{
    .q = current_prompt,
    .limit = 8,
});
defer context.deinit();
```

`client.getFile(id)` and `client.deleteFile(id)` complete the file lifecycle.
Only the returned `clark_file_*` id should be sent in later gateway requests;
raw provider file ids are deliberately never exposed.

### Images, organization knowledge, and artifacts

```zig
var image = try client.createImageGeneration(.{
    .prompt = "Turn this into a warm editorial illustration.",
    .input_images = &.{"data:image/png;base64,iVBORw0KGgo..."},
}, .{ .idempotency_key = "image-retry-1" });
defer image.deinit();

var knowledge = try client.searchOrganizationKnowledge(.{
    .query = "authentication changes",
    .limit = 8,
});
defer knowledge.deinit();

var artifact = try client.downloadArtifact("conversation-id", "report.pdf", .{
    .download = true,
    .range = "bytes=0-1023",
});
defer artifact.deinit();
```

### The `ApiResult(T)` / error model

Every non-streaming call returns `!ApiResult(T)`:

- The **outer** `!` is a plain Zig error union for transport-level failures
  (connection refused, TLS failure, malformed JSON, out of memory, ...).
- The **inner** `ApiResult(T)` is a tagged union:
  - `.ok: std.json.Parsed(T)` --- the typed success body.
  - `.api_error: std.json.Parsed(clark_platform.types.ErrorEnvelope)` ---
    the `{"error": {message, type, param, code}}` envelope the contract
    documents for every non-2xx response (auth, validation, not-found,
    upstream, server errors).

Call `.deinit()` on the `ApiResult` (not on `.ok`/`.api_error` directly) to
free whichever branch was populated.

Streaming calls (`client.streamResponse`, `client.streamChatCompletion`,
`client.streamChatCompletionPassthrough`) return
`!clark_platform.StreamOpenResult(StreamT)`, the same idea but with `.ok`
holding a `*StreamT` iterator instead of a `Parsed(T)`.

## Quickstart: streaming

```zig
var open_result = try client.streamChatCompletion(.{
    .model = "clark",
    .messages = &.{.{ .role = "user", .content = "hello" }},
    .stream_options = .{ .include_usage = true },
});
switch (open_result) {
    .api_error => |parsed| {
        std.debug.print("rejected: {s}\n", .{parsed.value.@"error".message});
        parsed.deinit();
    },
    .ok => |stream| {
        defer stream.deinit();
        while (try stream.next()) |chunk| {
            // chunk: clark_platform.types.ChatCompletionChunk
            if (chunk.choices.len > 0) {
                if (chunk.choices[0].delta.content) |text| std.debug.print("{s}", .{text});
            }
        }
        // The loop above exits after the literal `data: [DONE]` line.
    },
}
```

`client.streamResponse(...)` iterates the named-event SSE shape from
`POST /v1/responses` instead (`event.event_name`, e.g.
`"response.output_text.delta"`, plus `event.body: std.json.Value` for the
per-event-type fields). The contract notes the full answer arrives as a
**single** `response.output_text.delta`, not token-by-token, so don't
expect many small deltas from that endpoint the way you might from
`chat.completions.stream`.

**Iterator lifetime**: `next()` resets an internal arena on every call, so
the returned event's strings/`std.json.Value` tree are only valid until the
*next* `next()` call (or `deinit()`). Copy out anything you need to keep
(e.g. `allocator.dupe(u8, ...)`) before calling `next()` again.

## The stateless model gateway

Any provider-qualified `author/model` id, plus the legacy `clark-code`
compatibility alias, uses a fundamentally different mode: the entire request
(`messages`, `tools`, `tool_choice`, including prior `assistant`
messages with `tool_calls` and `tool` role messages) is forwarded verbatim
to the upstream OpenAI-compatible provider, and the response is the raw
upstream body --- not a Clark `ResponseObject`/`ChatCompletionObject`. This
client exposes it through distinctly named methods so you can't
accidentally parse a passthrough response as a Clark object:

```zig
var result = try client.createChatCompletionPassthrough(.{
    .model = selected_provider_model,
    .messages = my_messages_json_value, // std.json.Value, forwarded as-is
    .tools = my_tools_json_value,
});
defer result.deinit();
switch (result) {
    .ok => |parsed| {
        // parsed.value: std.json.Value --- the raw upstream OpenAI-shaped
        // response, including its own `usage.cost`.
    },
    .api_error => |parsed| { /* ... */ },
}
```

`client.streamChatCompletionPassthrough(...)` is the streaming twin. The
provider-qualified Responses gateway is also available on `/v1/responses`,
but its upstream-native event shapes are intentionally not parsed as Clark
agent events by this 0.2 client.

## Judgment calls / scope limits

The contract itself flags a few shapes as dynamic or as accepted-but-
unused; this client makes the following explicit, documented choices
rather than guessing at a closed schema:

- **`input`/`messages[].content` are plain strings only.** The contract
  states only the array form's *last* `role: "user"` item is ever read
  server-side (and only its `text`/`input_text` parts at that --- image/file
  parts are accepted and silently dropped). Since the string form covers
  every effective use of the endpoints, `types.ResponseCreateRequest.input`
  and `types.ChatMessage.content` are typed as `[]const u8`, not the full
  `ResponseInput::Items` union.
- **Event/memory/passthrough payloads that the contract itself says
  "vary" are left as `std.json.Value`** rather than a hand-modeled closed
  set of structs: `ResponseStreamEvent.body`, `ResponseEvent.data`,
  `MemoriesList.data[]`, and everything in the stateless passthrough
  path. The contract's own text points at
  `crates/clark-services/src/platform_api/events.rs` for per-type
  projections if you need typed variants --- this client gives you the
  parsed tree and lets you walk it.
- **No per-request timeout knob.** `std.http.Client.request`/
  `RequestOptions` in Zig 0.16 do not expose a timeout parameter (only
  `connectTcpOptions.timeout`, which this client does not thread through
  the public API). The contract notes non-background responses can
  legitimately take up to `CLARK_PLATFORM_RESPONSE_WAIT_MS` (120s default)
  server-side, so plan client-side cancellation (if you need it) around
  your own `std.Io` cancellation/timeout mechanism instead.
- **`io_buffer_bytes` (default 256 KiB)** sizes both the non-streaming
  response-body transfer buffer and, for SSE streams, the longest single
  line `sse.readEvent` can read before returning `error.SseLineTooLong`.
  Raise `Client.Options.io_buffer_bytes` if you expect a single `data:`
  line (e.g. one very large `response.output_text.delta`) to exceed that.

## Zig 0.16 `std.http`/`std.Io` notes

Zig's HTTP client/server APIs changed significantly in 0.16 (an `Io`
abstraction replaces blocking-by-default I/O). Two things worth knowing if
you're extending this package:

- `std.http.Client` needs an `io: Io` field, obtained from
  `std.Io.Threaded.init(allocator, .{}).io()`. Because that `Io` closes
  over the `Threaded` value's address, both the `Threaded` and the
  `http.Client` embedding it must live at a **stable heap address** for
  their whole lifetime --- hence `Client.create`/`Client.destroy` instead
  of a plain `init`/`deinit` you could put on the stack.
- `std.http.Client.Response` holds a `*Request` pointer back to the
  exact `Request` value used to call `receiveHead`, so the `Request` must
  also stay at a stable address once you've called `receiveHead` on it ---
  this package always keeps `Request`/`Response` as fields on a
  heap-allocated stream/request struct, never on the stack, for that
  reason.

## Running the tests

```sh
zig build test
```

This spins up a local, in-process mock HTTP server (a hand-rolled raw
socket responder, not `std.http.Server`, so fixtures have exact control
over header/body bytes) bound to `127.0.0.1:18473` and points the client
at it --- no real network access. It covers: bearer auth header
propagation, `models.list` parsing, non-streaming `responses.create` and
`chat.completions.create` parsing, the provider-gateway passthrough shape,
the file lifecycle, repository context, the `memories.list` dynamic shape,
the 4xx error envelope, and both SSE
streaming shapes (named `response.*` events including
`response.artifact.completed`/`response.usage.updated`, and anonymous
`chat.completion.chunk` events ending on `data: [DONE]` with the
`include_usage` terminal usage chunk).

## Live smoke test (opt-in, real network)

```sh
CLARK_API_BASE_URL=https://www.clarkchat.com \
CLARK_API_KEY=ck_live_xxxxxxxxxxxxxxxxxxxx \
CLARK_TEST_MODEL=openrouter:qwen37_flash \
zig build live-smoke
```

Never run this from an automated test suite --- it makes real network
calls against a live Clark deployment and consumes real credits. With no
environment variables set, `zig build live-smoke` still compiles and runs
cleanly; it just prints a message and exits.

## Known limitation: POST request bodies over real TLS (Zig 0.16)

`GET /v1/models` was verified live against a real deployment and works
correctly (after forcing `Accept-Encoding: identity` --- see the comment on
`requestJson` in `src/client.zig`; without it, Cloudflare gzip-compresses
the response body and this client's non-decompressing `response.reader()`
feeds raw gzip bytes into `std.json.parseFromSlice`, which is a real bug
this live test caught and fixed).

`POST /v1/chat/completions`, `/v1/responses`, and multipart `/v1/files`
could **not**
be verified live as of this writing. The client's outgoing JSON body is
byte-verified correct in memory (confirmed via debug logging before send),
and the offline `zig build test` suite --- which exercises the exact same
`requestJson`/`sendBodyComplete` path over a local plaintext mock server ---
passes cleanly. But against the real HTTPS endpoint:

- `req.sendBodyComplete(body)` (the documented one-shot "send head + body"
  API, which reuses the caller's buffer directly as the writer's staging
  buffer) reliably sends a request whose body is missing a **constant
  86-byte suffix** regardless of total body length (verified by padding the
  request to several different sizes and observing the cut point track
  `body.len - 86` every time) --- the server's JSON parser then reports
  "expected value" at the exact byte the truncation lands on.
- Routing the same bytes through the lower-level `sendBodyUnflushed` +
  `writer.writeAll(body)` + `end()` path (bypassing the buffer-aliasing
  shortcut) avoids the truncation but instead hangs indefinitely waiting on
  `receiveHead` --- the request never completes.

Both symptoms point at an issue in `std.http.Client`'s TLS body-writing
path in this Zig version (0.16.0), not at this library's request
construction or JSON encoding. Zig's new `std.Io`-based HTTP/TLS stack is
very recent and this exact code path (writing a request body, as opposed to
reading a response body) is comparatively undertested. If you hit this,
please check for a newer Zig release before filing against this package ---
`src/client.zig`'s `requestJson` is the only place a fix would need to
land.
