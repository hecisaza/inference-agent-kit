//! Fuzz probe (not part of the patch): random replies built from DSML tags, names, prose and whitespace, both spellings.
//! For each: the calls, the whole content, the stream's end, and whether any streamed step (or the end) took text back.
const std = @import("std");
const json = @import("json.zig");
const parse = @import("tool_parse.zig").parse;
const reply_text = @import("reply_text.zig");
const D = "\u{ff5c}DSML\u{ff5c}";
const tool_stream = @import("tool_stream.zig");

fn streamedCalls(a: std.mem.Allocator, text: []const u8, tools: []const json.Value, dsml_template: bool) !?[]const u8 {
    var s = try tool_stream.Streamer.init(a, tools);
    if (dsml_template and @hasField(tool_stream.Streamer, "calls_off")) s.calls_off = true;
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



fn crashesMain(text: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, "<tool_call>")) |i| {
        pos = i + 1;
        const e = std.mem.indexOfPos(u8, text, i + 11, "</tool_call>") orelse return false;
        const inner = std.mem.trim(u8, text[i + 11 .. e], " \t\r\n");
        if (std.mem.startsWith(u8, inner, "<" ++ D ++ " calls>") or std.mem.startsWith(u8, inner, "<" ++ D ++ "tool_calls>")) return true;
    }
    return false;
}

test "fuzz" {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tools = (try json.parse(a, "[{\"type\":\"function\",\"function\":{\"name\":\"write\"}}]")).ok.array;
    var prng = std.Random.DefaultPrng.init(20261104);
    const rnd = prng.random();
    var case: usize = 0;
    while (case < 6000) : (case += 1) {
        const v41 = rnd.boolean();
        const sp = if (v41) " " else "";
        const blk = if (v41) "calls" else "tool_calls";
        const toks = [_][]const u8{
            try std.mem.concat(a, u8, &.{ "<", D, sp, blk, ">" }),                         // block opener
            try std.mem.concat(a, u8, &.{ "</", D, sp, blk, ">" }),                        // block closer
            try std.mem.concat(a, u8, &.{ "<", D, sp, "invoke name=\"write\">" }),         // invoke, offered tool
            try std.mem.concat(a, u8, &.{ "<", D, sp, "invoke name=\"other\">" }),         // invoke, unknown tool
            try std.mem.concat(a, u8, &.{ "<", D, sp, "invoke name=\"" }),                 // invoke opener, name unfinished
            try std.mem.concat(a, u8, &.{ "</", D, sp, "invoke>" }),                       // invoke closer
            try std.mem.concat(a, u8, &.{ "<", D, sp, "parameter name=\"content\" string=\"true\">" }),
            try std.mem.concat(a, u8, &.{ "</", D, sp, "parameter>" }),
            "\n", " ", "text", "\">", "\"", "<", "x y",
            "<tool_call><function=write></function></tool_call>", "<tool_call>{\"name\": \"write\", \"arguments\": {}}</tool_call>",
            "<|tool_call>call:write{}<tool_call|>", "<tool_call>", "</tool_call>", "<function=write>",
        };
        var buf: std.ArrayList(u8) = .empty;
        if (case % 2 == 0) {
            // random tag soup: openers, invokes, parameters and closers more often than noise
            const n = rnd.intRangeAtMost(usize, 1, 14);
            for (0..n) |_| {
                const w = rnd.uintLessThan(u32, 100);
                const k: usize = if (w < 70) rnd.uintLessThan(usize, 8) else 8 + rnd.uintLessThan(usize, toks.len - 8);
                try buf.appendSlice(a, toks[k]);
            }
        } else if (case % 4 == 3) {
            // mixed spellings: blocks of either spelling, values typed string or JSON, values holding the other
            // spelling's tags or a whole block of it; sometimes cut at a random byte
            const T = struct {
                fn tags(al: std.mem.Allocator, v: bool) ![8][]const u8 {
                    const x = if (v) " " else "";
                    const bn = if (v) "calls" else "tool_calls";
                    return .{
                        try std.mem.concat(al, u8, &.{ "<", D, x, bn, ">" }),
                        try std.mem.concat(al, u8, &.{ "</", D, x, bn, ">" }),
                        try std.mem.concat(al, u8, &.{ "<", D, x, "invoke name=\"write\">" }),
                        try std.mem.concat(al, u8, &.{ "</", D, x, "invoke>" }),
                        try std.mem.concat(al, u8, &.{ "<", D, x, "parameter name=\"content\" string=\"true\">" }),
                        try std.mem.concat(al, u8, &.{ "<", D, x, "parameter name=\"content\" string=\"false\">" }),
                        try std.mem.concat(al, u8, &.{ "</", D, x, "parameter>" }),
                        try std.mem.concat(al, u8, &.{ "<", D, x, "invoke name=\"other\">" }),
                    };
                }
            };
            const both = [2][8][]const u8{ try T.tags(a, true), try T.tags(a, false) };
            const nb = rnd.intRangeAtMost(usize, 1, 3);
            for (0..nb) |bi| {
                if (bi > 0) try buf.appendSlice(a, if (rnd.boolean()) "\n" else "\nThen:\n");
                const t = both[rnd.uintLessThan(usize, 2)];
                try buf.appendSlice(a, t[0]);
                const ni = rnd.intRangeAtMost(usize, 1, 2);
                for (0..ni) |_| {
                    try buf.appendSlice(a, "\n");
                    try buf.appendSlice(a, t[if (rnd.uintLessThan(u32, 5) == 0) 7 else 2]);
                    if (rnd.boolean()) {
                        try buf.appendSlice(a, "\n");
                        try buf.appendSlice(a, t[if (rnd.boolean()) 4 else 5]);
                        const vn = rnd.intRangeAtMost(usize, 0, 4);
                        for (0..vn) |_| {
                            const o = both[rnd.uintLessThan(usize, 2)];
                            switch (rnd.uintLessThan(u32, 7)) {
                                6 => try buf.appendSlice(a, toks[15 + rnd.uintLessThan(usize, 6)]),
                                0 => try buf.appendSlice(a, "{\"a\": 1}"),
                                1 => try buf.appendSlice(a, "\n"),
                                2 => {
                                    try buf.appendSlice(a, o[0]);
                                    try buf.appendSlice(a, o[2]);
                                    try buf.appendSlice(a, o[3]);
                                    try buf.appendSlice(a, o[1]);
                                },
                                else => try buf.appendSlice(a, o[rnd.uintLessThan(usize, 8)]),
                            }
                        }
                        try buf.appendSlice(a, t[6]);
                    }
                    try buf.appendSlice(a, "\n");
                    try buf.appendSlice(a, t[3]);
                }
                try buf.appendSlice(a, "\n");
                try buf.appendSlice(a, t[1]);
            }
            if (rnd.uintLessThan(u32, 4) == 0) buf.shrinkRetainingCapacity(rnd.uintLessThan(usize, buf.items.len + 1));
        } else {
            // a reply as a model writes it: prose, then one or two whole blocks of one to three calls, each value a
            // short run of random tokens (a file about DSML), prose between and after; sometimes cut at a random byte
            const blocks = rnd.intRangeAtMost(usize, 1, 2);
            if (rnd.boolean()) try buf.appendSlice(a, "Writing the file.\n\n");
            for (0..blocks) |bi| {
                if (bi > 0) try buf.appendSlice(a, "\nThen:\n");
                try buf.appendSlice(a, toks[0]);
                const invokes = rnd.intRangeAtMost(usize, 1, 3);
                for (0..invokes) |_| {
                    try buf.appendSlice(a, "\n");
                    try buf.appendSlice(a, toks[if (rnd.uintLessThan(u32, 4) == 0) 3 else 2]);
                    const params = rnd.intRangeAtMost(usize, 0, 2);
                    for (0..params) |_| {
                        try buf.appendSlice(a, "\n");
                        try buf.appendSlice(a, toks[6]);
                        const vn = rnd.intRangeAtMost(usize, 0, 4);
                        for (0..vn) |_| try buf.appendSlice(a, toks[if (rnd.uintLessThan(u32, 3) == 0) 8 + rnd.uintLessThan(usize, toks.len - 8) else rnd.uintLessThan(usize, 6)]);
                        try buf.appendSlice(a, toks[7]);
                    }
                    try buf.appendSlice(a, "\n");
                    try buf.appendSlice(a, toks[5]);
                }
                try buf.appendSlice(a, "\n");
                try buf.appendSlice(a, toks[1]);
            }
            if (rnd.boolean()) try buf.appendSlice(a, "\nDone.");
            if (rnd.uintLessThan(u32, 4) == 0) buf.shrinkRetainingCapacity(rnd.uintLessThan(usize, buf.items.len + 1));
        }
        const text = buf.items;
        // main's parser crashes on a <tool_call> block whose payload starts with a DSML opener (a separate bug, on main
        // too): such inputs are counted and skipped, so the rest of the comparison can run
        if (crashesMain(text)) {
            std.debug.print("\nFUZZ {d}\tSKIP\n", .{case});
            continue;
        }
        const r = try parse(a, text, tools, null);
        var calls: std.ArrayList(u8) = .empty;
        var ncalls: usize = 0;
        if (r.calls) |cs| for (cs) |c| {
            ncalls += 1;
            try calls.appendSlice(a, c.get("function").?.get("name").?.string);
            try calls.appendSlice(a, c.get("function").?.get("arguments").?.string);
            try calls.appendSlice(a, ";");
        };
        var retracts = false;
        var before: []const u8 = "";
        for (0..text.len + 2) |i| {
            const shown = if (i <= text.len) try reply_text.hideToolCalls(a, text[0..i], false) else try reply_text.hideToolCalls(a, text, true);
            if (!std.mem.startsWith(u8, shown, before)) retracts = true;
            before = try a.dupe(u8, shown);
        }
        const streamed = (try streamedCalls(a, text, tools, false)) orelse calls.items;
        const streamed_dsml = (try streamedCalls(a, text, tools, true)) orelse calls.items;
        std.debug.print("\nFUZZ {d}\t{d}\t{s}\t{f}\t{f}\t{s}\t{f}\t{s}\t{s}\n", .{ case, ncalls, calls.items, std.zig.fmtString(r.content), std.zig.fmtString(before), if (retracts) "RETRACTS" else "ok", std.zig.fmtString(text), streamed, streamed_dsml });
    }
}
