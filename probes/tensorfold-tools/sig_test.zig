//! Signature probe (not part of the patch): for each case, the calls, the whole reply's content and the streamed text,
//! printed exactly, so two trees can be diffed case by case.
const std = @import("std");
const json = @import("json.zig");
const parse = @import("tool_parse.zig").parse;
const reply_text = @import("reply_text.zig");
const D = "\u{ff5c}DSML\u{ff5c}";

fn block(a: std.mem.Allocator, v41: bool, value: []const u8) ![]const u8 {
    const s = if (v41) " " else "";
    const b = if (v41) "calls" else "tool_calls";
    return std.mem.concat(a, u8, &.{ "<", D, s, b, ">\n<", D, s, "invoke name=\"write\">\n<", D, s, "parameter name=\"content\" string=\"true\">", value, "</", D, s, "parameter>\n</", D, s, "invoke>\n</", D, s, b, ">" });
}

fn sig(a: std.mem.Allocator, name: []const u8, text: []const u8, tools: []const json.Value) !void {
    const r = try parse(a, text, tools, null);
    var calls: std.ArrayList(u8) = .empty;
    if (r.calls) |cs| for (cs) |c| {
        try calls.appendSlice(a, c.get("function").?.get("name").?.string);
        try calls.appendSlice(a, c.get("function").?.get("arguments").?.string);
        try calls.appendSlice(a, ";");
    };
    var retracts = false;
    var before: []const u8 = "";
    for (0..text.len + 1) |n| {
        const shown = try reply_text.hideToolCalls(a, text[0..n], false);
        if (!std.mem.startsWith(u8, shown, before)) retracts = true;
        before = try a.dupe(u8, shown);
    }
    const final = try reply_text.hideToolCalls(a, text, true);
    if (!std.mem.startsWith(u8, final, before)) retracts = true; // the end keeps what the last streamed step showed
    std.debug.print("\nSIG {s} || calls[{s}] || content[{f}] || stream-end[{f}]{s}\n", .{ name, calls.items, std.zig.fmtString(r.content), std.zig.fmtString(final), if (retracts) " || RETRACTS" else "" });
}

test "sig" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tools = (try json.parse(a, "[{\"type\":\"function\",\"function\":{\"name\":\"write\"}}]")).ok.array;
    for ([_]bool{ true, false }) |v41| {
        const sp = if (v41) "V4.1" else "V4";
        const open = if (v41) "<" ++ D ++ " calls>" else "<" ++ D ++ "tool_calls>";
        const close = if (v41) "</" ++ D ++ " calls>" else "</" ++ D ++ "tool_calls>";
        const inv = if (v41) "<" ++ D ++ " invoke name=\"" else "<" ++ D ++ "invoke name=\"";
        const invc = if (v41) "</" ++ D ++ " invoke>" else "</" ++ D ++ "invoke>";
        const plain = try block(a, v41, "plain");
        const cases = [_][2][]const u8{
            .{ "value holds the closer (#14)", try block(a, v41, try std.mem.concat(a, u8, &.{ "end: ", close })) },
            .{ "value holds the opener", try block(a, v41, try std.mem.concat(a, u8, &.{ "start: ", open })) },
            .{ "value holds opener then closer", try block(a, v41, try std.mem.concat(a, u8, &.{ open, " in ", close })) },
            .{ "value holds closer then opener", try block(a, v41, try std.mem.concat(a, u8, &.{ close, " then ", open })) },
            .{ "value holds an invoke closer", try block(a, v41, try std.mem.concat(a, u8, &.{ "x", invc, "y" })) },
            .{ "value holds invoke closer and closer", try block(a, v41, try std.mem.concat(a, u8, &.{ "x", invc, close, "y" })) },
            .{ "plain block", plain },
            .{ "prose after quotes the closer", try std.mem.concat(a, u8, &.{ plain, "\nA block ends with ", close, "." }) },
            .{ "two blocks", try std.mem.concat(a, u8, &.{ plain, "\nThen.\n", plain }) },
            .{ "text between invokes", try std.mem.concat(a, u8, &.{ open, "\n", inv, "write\">", invc, "\nstray\n", inv, "write\">", invc, "\n", close }) },
            .{ "cut, value holds the closer", (try block(a, v41, try std.mem.concat(a, u8, &.{ "end: ", close })))[0..(try block(a, v41, try std.mem.concat(a, u8, &.{ "end: ", close }))).len - close.len] },
            .{ "cut, plain value", plain[0 .. plain.len - close.len] },
            .{ "cut in a name holding the closer", try std.mem.concat(a, u8, &.{ open, "\n", inv, "write\">", invc, "\n", inv, close }) },
            .{ "name holding the closer, completed", try std.mem.concat(a, u8, &.{ open, "\n", inv, "write\">", invc, "\n", inv, close, "\">", invc, close }) },
            .{ "name with a quote missing", try std.mem.concat(a, u8, &.{ open, "\n", inv, "write>", invc, "\n", close, " after" }) },
            .{ "no closer at all", try std.mem.concat(a, u8, &.{ open, "\n", inv, "write\">", invc }) },
            .{ "unclosed invoke, then a whole block", try std.mem.concat(a, u8, &.{ open, "\n", inv, "broken\">\n", close, "\n", open, "\n", inv, "write\">", invc, "\n", close }) },
        };
        for (cases) |c| try sig(a, try std.mem.concat(a, u8, &.{ sp, " ", c[0] }), c[1], tools);
    }
    try sig(a, "both spellings", try std.mem.concat(a, u8, &.{ try block(a, true, "one"), "\nand\n", try block(a, false, "two") }), tools);
}
