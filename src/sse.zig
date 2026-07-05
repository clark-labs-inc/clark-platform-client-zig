//! Low-level Server-Sent-Events line reader shared by the two SSE shapes
//! documented in the contract:
//!
//!   1. `POST /v1/responses` streaming --- named events (`event: response.*`)
//!      each followed by one `data:` line.
//!   2. `POST /v1/chat/completions` streaming --- anonymous events, just
//!      `data:` lines, terminated by a literal `data: [DONE]` line.
//!
//! This module only knows about the SSE framing (lines, blank-line-terminated
//! events, multiple `data:` lines joined with `\n`, `:`-prefixed comment
//! lines ignored). It knows nothing about JSON; callers parse `RawEvent.data`
//! themselves.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;

pub const RawEvent = struct {
    /// From an `event: <name>` line, if present.
    event_name: ?[]const u8 = null,
    /// The joined body of all `data:` lines in this event (without the
    /// trailing newline). Empty string if the event carried no `data:`
    /// lines at all (never produced by the Clark server, but handled).
    data: []const u8 = "",
};

/// Reads one SSE event from `reader` into memory owned by `allocator`.
/// Returns `null` at a clean end-of-stream with no partial event pending.
///
/// Every string in the returned `RawEvent` is allocated via `allocator` and
/// owned by the caller (or by whatever arena `allocator` is bound to).
pub fn readEvent(allocator: Allocator, reader: *Reader) !?RawEvent {
    var event_name: ?[]const u8 = null;
    var data_parts: std.ArrayList([]const u8) = .empty;
    var saw_any_field = false;

    while (true) {
        const maybe_line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.SseLineTooLong,
            error.ReadFailed => return error.ReadFailed,
        };
        const raw_line = maybe_line orelse {
            // Connection closed. If we already collected fields for an
            // in-flight event, surface it; otherwise this is a clean EOF.
            if (!saw_any_field) return null;
            break;
        };
        const line = trimTrailingCr(raw_line);

        if (line.len == 0) {
            // Blank line: dispatch the event we've built so far, if any.
            if (!saw_any_field) continue;
            break;
        }

        if (line[0] == ':') continue; // comment line, ignored per SSE spec

        const colon = std.mem.indexOfScalar(u8, line, ':');
        const field = if (colon) |idx| line[0..idx] else line;
        var value = if (colon) |idx| line[idx + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];

        if (std.mem.eql(u8, field, "event")) {
            event_name = try allocator.dupe(u8, value);
            saw_any_field = true;
        } else if (std.mem.eql(u8, field, "data")) {
            try data_parts.append(allocator, try allocator.dupe(u8, value));
            saw_any_field = true;
        } else {
            // Unrecognized SSE field (e.g. `id:`, `retry:`); ignore per spec.
            saw_any_field = true;
        }
    }

    const data = try std.mem.join(allocator, "\n", data_parts.items);
    return .{ .event_name = event_name, .data = data };
}

fn trimTrailingCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

test "readEvent parses a named event with one data line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = "event: response.created\r\ndata: {\"type\":\"response.created\"}\r\n\r\n";
    var reader: Reader = .fixed(body);

    const event = (try readEvent(a, &reader)).?;
    try std.testing.expectEqualStrings("response.created", event.event_name.?);
    try std.testing.expectEqualStrings("{\"type\":\"response.created\"}", event.data);

    try std.testing.expectEqual(@as(?RawEvent, null), try readEvent(a, &reader));
}

test "readEvent parses anonymous chat.completion.chunk events and [DONE]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = "data: {\"a\":1}\n\ndata: [DONE]\n\n";
    var reader: Reader = .fixed(body);

    const first = (try readEvent(a, &reader)).?;
    try std.testing.expectEqual(@as(?[]const u8, null), first.event_name);
    try std.testing.expectEqualStrings("{\"a\":1}", first.data);

    const second = (try readEvent(a, &reader)).?;
    try std.testing.expectEqualStrings("[DONE]", second.data);

    try std.testing.expectEqual(@as(?RawEvent, null), try readEvent(a, &reader));
}

test "readEvent joins multiple data lines with newlines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = "data: line one\ndata: line two\n\n";
    var reader: Reader = .fixed(body);

    const event = (try readEvent(a, &reader)).?;
    try std.testing.expectEqualStrings("line one\nline two", event.data);
}
