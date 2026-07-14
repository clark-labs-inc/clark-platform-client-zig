//! Typed wire structs for the Clark Platform API.
//!
//! These mirror `platform/clients/API_CONTRACT.md`. A few fields are
//! intentionally left as `std.json.Value` where the contract itself says
//! the shape "varies" (response/event `data`, memory records, chat-chunk
//! deltas' arbitrary extra fields) rather than being hand-modeled ---
//! modeling those as a closed set of structs would drift out of sync with
//! the server the moment a new event/tool label is added. Callers that need
//! typed access to those fields can walk the `std.json.Value` tree.
const std = @import("std");

// ---------------------------------------------------------------------
// Error envelope (shared across every non-2xx response).
// ---------------------------------------------------------------------

pub const ErrorDetail = struct {
    message: []const u8,
    @"type": []const u8,
    param: ?[]const u8 = null,
    code: []const u8,
};

pub const ErrorEnvelope = struct {
    @"error": ErrorDetail,
};

// ---------------------------------------------------------------------
// Models: GET /v1/models
// ---------------------------------------------------------------------

pub const Pricing = struct {
    currency: []const u8,
    unit: []const u8,
    input: f64,
    output: f64,
    cache_write: ?f64 = null,
    cache_read: ?f64 = null,
};

pub const Capabilities = struct {
    public_input_modalities: []const []const u8 = &.{},
    model_input_modalities: []const []const u8 = &.{},
    output_modalities: []const []const u8 = &.{},
    features: []const []const u8 = &.{},
    public_file_upload: bool = false,
};

/// Recursive: a top-level tier's `model_options` are themselves full model
/// entries with their own (usually empty) `model_options`.
pub const ClarkTierInfo = struct {
    tier_id: []const u8,
    label: []const u8,
    description: []const u8 = "",
    context_window_tokens: ?i64 = null,
    max_output_tokens: ?i64 = null,
    pricing: ?Pricing = null,
    capabilities: ?Capabilities = null,
    model_options: []const ModelOption = &.{},
};

pub const ModelOption = struct {
    id: []const u8,
    object: []const u8,
    owned_by: []const u8,
    clark: ClarkTierInfo,
};

pub const ModelEntry = struct {
    id: []const u8,
    object: []const u8,
    owned_by: []const u8,
    clark: ClarkTierInfo,
};

pub const ModelsList = struct {
    object: []const u8,
    data: []const ModelEntry,
};

// ---------------------------------------------------------------------
// Files: POST/GET/DELETE /v1/files.
// ---------------------------------------------------------------------

pub const PlatformFile = struct {
    id: []const u8,
    object: []const u8,
    @"type": []const u8,
    filename: []const u8,
    purpose: []const u8,
    bytes: i64,
    mime_type: ?[]const u8 = null,
    size_bytes: i64,
    downloadable: bool = false,
    created_at: i64,
    status: []const u8,
    status_details: ?std.json.Value = null,
};

pub const FilesList = struct {
    object: []const u8,
    data: []const PlatformFile,
    has_more: bool = false,
    first_id: ?[]const u8 = null,
    last_id: ?[]const u8 = null,
    cursor: ?[]const u8 = null,
};

pub const DeletedFile = struct {
    id: []const u8,
    @"type": []const u8,
    deleted: bool,
};

pub const FileUpload = struct {
    filename: []const u8,
    bytes: []const u8,
    purpose: []const u8,
    mime_type: ?[]const u8 = null,
};

pub const ListFilesOptions = struct {
    limit: ?i64 = null,
};

// ---------------------------------------------------------------------
// Usage / cost / artifacts (shared by ResponseObject and ChatCompletionObject).
// ---------------------------------------------------------------------

pub const CostInfo = struct {
    amount: ?[]const u8 = null,
    currency: ?[]const u8 = null,
    @"type": []const u8,
};

pub const InputTokensDetails = struct {
    cached_tokens: i64 = 0,
};

pub const OutputTokensDetails = struct {
    reasoning_tokens: i64 = 0,
};

pub const Usage = struct {
    input_tokens: i64 = 0,
    input_tokens_details: InputTokensDetails = .{},
    output_tokens: i64 = 0,
    output_tokens_details: OutputTokensDetails = .{},
    total_tokens: i64 = 0,
    artifact_bytes: ?i64 = null,
    cost: ?CostInfo = null,
};

pub const Artifact = struct {
    id: []const u8,
    name: []const u8,
    kind: []const u8,
    role: []const u8,
    mime_type: []const u8,
    size_bytes: i64 = 0,
    summary: ?[]const u8 = null,
    download_url: []const u8,
};

pub const ClarkMetadata = struct {
    response_id: []const u8,
    conversation_id: []const u8,
    run_id: []const u8,
    status: []const u8,
    artifacts: []const Artifact = &.{},
};

// ---------------------------------------------------------------------
// Responses: POST/GET /v1/responses[/{id}]
// ---------------------------------------------------------------------

pub const OutputContentPart = struct {
    @"type": []const u8,
    text: ?[]const u8 = null,
};

pub const OutputItem = struct {
    id: []const u8,
    @"type": []const u8,
    status: []const u8,
    role: []const u8,
    content: []const OutputContentPart = &.{},
};

pub const ResponseError = struct {
    @"type": []const u8,
    message: []const u8,
};

pub const ResponseObject = struct {
    id: []const u8,
    object: []const u8,
    status: []const u8,
    created_at: i64,
    model: []const u8,
    previous_response_id: ?[]const u8 = null,
    background: bool = false,
    output: []const OutputItem = &.{},
    artifacts: []const Artifact = &.{},
    usage: ?Usage = null,
    metadata: ?std.json.Value = null,
    clark: ClarkMetadata,
    @"error": ?ResponseError = null,
};

/// A named SSE event from `POST /v1/responses` streaming
/// (`response.created`, `response.output_text.delta`, ...). The contract
/// enumerates the event names but the JSON body's extra fields differ per
/// name, so the parsed body is exposed as `std.json.Value` --- use
/// `body.object.get("...")` to reach fields documented for a given
/// `event_name`/`type`.
pub const ResponseStreamEvent = struct {
    /// From the SSE `event:` line, e.g. "response.output_text.delta".
    event_name: []const u8,
    /// Parsed JSON from the `data:` line(s). Always an object per the
    /// contract; also repeats `type` and `sequence_number`.
    body: std.json.Value,
};

pub const ResponseEvent = struct {
    id: []const u8,
    object: []const u8,
    response_id: []const u8,
    sequence: i64,
    created_at: i64,
    @"type": []const u8,
    run_id: ?[]const u8 = null,
    data: std.json.Value = .null,
};

pub const ResponseEventsList = struct {
    object: []const u8,
    data: []const ResponseEvent,
    next_after_seq: ?i64 = null,
};

// ---------------------------------------------------------------------
// Chat Completions: POST /v1/chat/completions (agentic tiers)
// ---------------------------------------------------------------------

pub const ChatMessage = struct {
    role: []const u8,
    content: ?[]const u8 = null,
};

pub const ChatChoice = struct {
    index: i64 = 0,
    message: ChatMessage,
    finish_reason: ?[]const u8 = null,
};

pub const ChatCompletionObject = struct {
    id: []const u8,
    object: []const u8,
    created: i64,
    model: []const u8,
    choices: []const ChatChoice = &.{},
    usage: ?Usage = null,
    clark: ?ClarkMetadata = null,
};

pub const ChatDelta = struct {
    role: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

pub const ChatChunkChoice = struct {
    index: i64 = 0,
    delta: ChatDelta = .{},
    finish_reason: ?[]const u8 = null,
};

/// One `data:` line from a `chat.completion.chunk` SSE stream (agentic
/// tiers only --- see `PassthroughChunk` for `clark-code`).
pub const ChatCompletionChunk = struct {
    id: []const u8,
    object: []const u8,
    created: i64,
    model: []const u8,
    choices: []const ChatChunkChoice = &.{},
    usage: ?Usage = null,
    clark: ?ClarkMetadata = null,
};

// ---------------------------------------------------------------------
// Memories: GET /v1/memories
// ---------------------------------------------------------------------

/// The contract defines this shape only as "defined by clark_memory_service"
/// and does not enumerate its fields, so each record is left as raw JSON.
pub const MemoriesList = struct {
    object: []const u8,
    data: []const std.json.Value = &.{},
};

// ---------------------------------------------------------------------
// Clark Code repository context.
// ---------------------------------------------------------------------

pub const RepositoryCommitContext = struct {
    oid: []const u8,
    author_name: []const u8,
    committed_at: []const u8,
    subject: []const u8,
    body: []const u8,
};

pub const RepositoryContext = struct {
    fingerprint: []const u8,
    canonical_remote: ?[]const u8 = null,
    current_branch: ?[]const u8 = null,
    default_branch: ?[]const u8 = null,
    commits: []const RepositoryCommitContext = &.{},
};

pub const RepositoryContextOptions = struct {
    q: ?[]const u8 = null,
    limit: ?i64 = null,
};

// ---------------------------------------------------------------------
// Request bodies.
// ---------------------------------------------------------------------

/// `POST /v1/responses` request body.
///
/// The contract also allows `input` to be an array of role/content items,
/// but documents that only the last `role: "user"` item's plain-text parts
/// are ever read server-side --- everything else in the array form is
/// accepted-and-ignored. This client only exposes the plain-string form
/// since it covers every effective use of the endpoint.
pub const ResponseCreateRequest = struct {
    model: ?[]const u8 = null,
    tier_model_id: ?[]const u8 = null,
    input: []const u8,
    conversation_id: ?[]const u8 = null,
    memory_scope: ?[]const u8 = null,
    previous_response_id: ?[]const u8 = null,
    stream: bool = false,
    background: bool = false,
    metadata: ?std.json.Value = null,
};

pub const StreamOptions = struct {
    include_usage: bool = false,
};

/// `POST /v1/chat/completions` request body for the agentic tiers
/// (`clark`, `clark_max`, `openrouter:*`). `tools`/`tool_choice` are
/// deliberately not fields here: the server rejects them outright for
/// these tiers, so this type cannot construct an invalid request. Use
/// `PassthroughChatCompletionRequest` for `clark-code`.
pub const ChatCompletionCreateRequest = struct {
    model: ?[]const u8 = null,
    tier_model_id: ?[]const u8 = null,
    messages: []const ChatMessage,
    conversation_id: ?[]const u8 = null,
    memory_scope: ?[]const u8 = null,
    previous_response_id: ?[]const u8 = null,
    stream: bool = false,
    stream_options: ?StreamOptions = null,
    metadata: ?std.json.Value = null,
};

/// `POST /v1/chat/completions` request body for a provider-qualified
/// `author/model` or the legacy `clark-code` passthrough alias. Per the
/// contract, the entire `messages` array
/// (including prior `assistant` messages with `tool_calls` and `tool`
/// role messages with `tool_call_id`) is forwarded verbatim to the
/// upstream OpenAI-compatible provider, so `messages`/`tools`/`tool_choice`
/// are left as raw JSON rather than typed --- there is no stable Clark
/// shape to type against here, only the upstream's own OpenAI dialect.
pub const PassthroughChatCompletionRequest = struct {
    model: []const u8,
    messages: std.json.Value,
    tools: ?std.json.Value = null,
    tool_choice: ?std.json.Value = null,
    stream: bool = false,
    stream_options: ?StreamOptions = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    max_tokens: ?i64 = null,
    stop: ?std.json.Value = null,
    parallel_tool_calls: ?bool = null,
    /// "minimal" | "low" | "medium" | "high" | "xhigh"
    reasoning_effort: ?[]const u8 = null,
    metadata: ?std.json.Value = null,
};

pub const ListResponseEventsOptions = struct {
    after_seq: ?i64 = null,
    limit: ?i64 = null,
    /// Comma-separated allowlist filter, passed through verbatim.
    types: ?[]const u8 = null,
};

pub const ListMemoriesOptions = struct {
    q: ?[]const u8 = null,
    tags: ?[]const u8 = null,
    conversation_id: ?[]const u8 = null,
};
