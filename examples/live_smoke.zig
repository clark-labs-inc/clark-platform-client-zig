//! Opt-in live smoke test against a real Clark deployment. Never run this
//! automatically --- it makes real network calls and consumes real credits.
//!
//! Usage:
//!   CLARK_API_BASE_URL=https://www.clarkchat.com \
//!   CLARK_API_KEY=ck_live_xxx \
//!   CLARK_TEST_MODEL=openrouter:qwen35_flash \
//!   zig build live-smoke
const std = @import("std");
const clark_platform = @import("clark_platform");

/// Zig 0.16 lets `main` take a `std.process.Init` to receive a
/// ready-to-use allocator and parsed environment map instead of querying
/// them by hand.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const env = init.environ_map;

    const base_url = env.get("CLARK_API_BASE_URL") orelse {
        std.debug.print(
            "CLARK_API_BASE_URL not set; skipping live smoke test.\n" ++
                "Set CLARK_API_BASE_URL, CLARK_API_KEY, and optionally CLARK_TEST_MODEL to run it.\n",
            .{},
        );
        return;
    };
    const api_key = env.get("CLARK_API_KEY") orelse {
        std.debug.print("CLARK_API_KEY not set; skipping live smoke test.\n", .{});
        return;
    };
    const model = env.get("CLARK_TEST_MODEL") orelse "openrouter:qwen35_flash";

    const client = try clark_platform.Client.create(gpa, .{
        .base_url = base_url,
        .api_key = api_key,
    });
    defer client.destroy();

    std.debug.print("Listing models from {s} ...\n", .{base_url});
    var models_result = try client.listModels();
    defer models_result.deinit();
    switch (models_result) {
        .ok => |parsed| {
            std.debug.print("Got {d} model tier(s):\n", .{parsed.value.data.len});
            for (parsed.value.data) |entry| {
                std.debug.print("  - {s} ({s})\n", .{ entry.id, entry.clark.label });
            }
        },
        .api_error => |parsed| {
            std.debug.print("models.list failed: {s} ({s})\n", .{
                parsed.value.@"error".message,
                parsed.value.@"error".@"type",
            });
            return;
        },
    }

    std.debug.print("Sending a trivial chat completion with model={s} ...\n", .{model});
    var chat_result = try client.createChatCompletion(.{
        .model = model,
        .messages = &.{.{ .role = "user", .content = "Say the single word: pong" }},
    });
    defer chat_result.deinit();
    switch (chat_result) {
        .ok => |parsed| {
            const choice = parsed.value.choices[0];
            std.debug.print("Assistant replied: {s}\n", .{choice.message.content orelse "(no content)"});
        },
        .api_error => |parsed| {
            std.debug.print("chat.completions.create failed: {s} ({s})\n", .{
                parsed.value.@"error".message,
                parsed.value.@"error".@"type",
            });
        },
    }
}
