//! `clark_platform` --- a typed, streaming-capable Zig client for the
//! Clark Platform API (see `platform/clients/API_CONTRACT.md`).
const client_mod = @import("client.zig");
const stream_mod = @import("stream.zig");

pub const types = @import("types.zig");
pub const sse = @import("sse.zig");

pub const Client = client_mod.Client;
pub const ApiResult = client_mod.ApiResult;

pub const StreamOpenResult = stream_mod.StreamOpenResult;
pub const ResponseStream = stream_mod.ResponseStream;
pub const ChatCompletionStream = stream_mod.ChatCompletionStream;
pub const PassthroughStream = stream_mod.PassthroughStream;

test {
    _ = @import("sse.zig");
    _ = @import("client_test.zig");
}
