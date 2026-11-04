//! Streamed-vs-whole tool-call parity probe (not part of the patch). A streamed client gets the calls tool_stream's
//! Streamer emits while the answer grows, or, when it streamed none, the calls tool_parse.parse finds at the end
//! (openai.zig: parsed calls are sent only when tool_calls_streamed is false). A non-streamed client gets parse's.
const std = @import("std");
const json = @import("json.zig");
const parse = @import("tool_parse.zig").parse;
const tool_stream = @import("tool_stream.zig");
const D = "\u{ff5c}DSML\u{ff5c}";

fn streamedCalls(a: std.mem.Allocator, text: []const u8, tools: []const json.Value) !?[]const u8 {
    var s = try tool_stream.Streamer.init(a, tools);
    var out: std.ArrayList(json.Value) = .empty;
    for (1..text.len + 1) |n| try s.feed(text[0..n], &out); // byte by byte, as the answer grows
    if (!s.streamed) return null;
    var names: std.ArrayList(u8) = .empty;
    var args: std.ArrayList(u8) = .empty;
    for (out.items) |d| {
        const tc = d.get("tool_calls").?.array[0];
        const f = tc.get("function").?;
        if (f.get("name")) |nm| {
            if (names.items.len > 0) {
                try names.appendSlice(a, args.items);
                try names.appendSlice(a, ";");
                args.clearRetainingCapacity();
            }
            try names.appendSlice(a, nm.string);
        }
        if (f.get("arguments")) |ar| try args.appendSlice(a, ar.string);
    }
    try names.appendSlice(a, args.items);
    try names.appendSlice(a, ";");
    return names.items;
}

fn parsedCalls(a: std.mem.Allocator, text: []const u8, tools: []const json.Value) ![]const u8 {
    const r = try parse(a, text, tools, null);
    var buf: std.ArrayList(u8) = .empty;
    if (r.calls) |cs| for (cs) |c| {
        try buf.appendSlice(a, c.get("function").?.get("name").?.string);
        try buf.appendSlice(a, c.get("function").?.get("arguments").?.string);
        try buf.appendSlice(a, ";");
    };
    return buf.items;
}

fn check(a: std.mem.Allocator, name: []const u8, text: []const u8, tools: []const json.Value) !void {
    const whole = try parsedCalls(a, text, tools);
    const st = try streamedCalls(a, text, tools);
    const streamed = st orelse whole;
    std.debug.print("\nPARITY {s} | {s} | whole[{s}] | streamed[{s}]{s}\n", .{ if (std.mem.eql(u8, whole, streamed)) "same" else "DIFFER", name, whole, streamed, if (st != null) " (from the Streamer)" else " (parsed at the end)" });
}

test "parity" {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tools = (try json.parse(a, "[{\"type\":\"function\",\"function\":{\"name\":\"write\"}}]")).ok.array;
    const qwen = "<tool_call><function=write></function></tool_call>";
    for ([_]bool{ true, false }) |v41| {
        const x = if (v41) " " else "";
        const bn = if (v41) "calls" else "tool_calls";
        const open = try std.mem.concat(a, u8, &.{ "<", D, x, bn, ">" });
        const close = try std.mem.concat(a, u8, &.{ "</", D, x, bn, ">" });
        const inv = try std.mem.concat(a, u8, &.{ "<", D, x, "invoke name=\"write\">" });
        const invc = try std.mem.concat(a, u8, &.{ "</", D, x, "invoke>" });
        const par = try std.mem.concat(a, u8, &.{ "<", D, x, "parameter name=\"content\" string=\"true\">" });
        const parc = try std.mem.concat(a, u8, &.{ "</", D, x, "parameter>" });
        const sp = if (v41) "V4.1" else "V4";
        const call = struct {
            fn one(al: std.mem.Allocator, i: []const u8, p: []const u8, v: []const u8, pc: []const u8, ic: []const u8) ![]const u8 {
                return std.mem.concat(al, u8, &.{ "\n", i, "\n", p, v, pc, "\n", ic });
            }
        };
        const cases = [_][2][]const u8{
            .{ "value holds the closer (#14)", try std.mem.concat(a, u8, &.{ open, try call.one(a, inv, par, try std.mem.concat(a, u8, &.{ "end: ", close }), parc, invc), "\n", close }) },
            .{ "value holds Qwen markup only", try std.mem.concat(a, u8, &.{ open, try call.one(a, inv, par, qwen, parc, invc), "\n", close }) },
            .{ "two calls, the first value holds the closer and Qwen markup (Copilot)", try std.mem.concat(a, u8, &.{ open, try call.one(a, inv, par, try std.mem.concat(a, u8, &.{ close, qwen }), parc, invc), try call.one(a, inv, par, "two", parc, invc), "\n", close }) },
            .{ "prose quotes Qwen markup after a block", try std.mem.concat(a, u8, &.{ open, try call.one(a, inv, par, "x", parc, invc), "\n", close, "\nThe other format is ", qwen }) },
        };
        for (cases) |c| try check(a, try std.mem.concat(a, u8, &.{ sp, " ", c[0] }), c[1], tools);
    }
}
