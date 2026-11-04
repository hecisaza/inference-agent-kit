# Engine change review: {{TITLE}}

**READ-ONLY review. Do not write, create, move or delete any file; do not run builds, network, docker or git commands
that change anything. Read files only (cat, sed -n, grep, ls, diff; python3 only to compute on data in this bundle).
Reply with the review as markdown on stdout, under 1000 words.**

## What is in the bundle
- `tree-before/` and `tree-after/`: the WHOLE engine source (not a selection), without and with the change.
- `change.patch`: the change. `PR.md`: its description. `evidence/`: hardware runs, probe outputs, local tests.

## Questions
1. **Every consumer.** List every caller of each function the change touches, and every component that reads the same
   input (for a reply parser: the final parse, the stream filter, the live tool-call streamer, each API route, the
   parity checks). For each: does the change reach it, and does it still agree with the others? Name the file and line.
2. **Every client.** For each kind of client (streamed and non-streamed, each API route, with and without limits such as
   `max_calls`), what does it receive before and after the change? Is any of them worse, or do two of them now disagree
   where they agreed before? Show the input.
3. **Every format.** The engine reads several markups (for tool calls: Qwen's, Gemma's, both DSML spellings, namespaced
   `<x:tool_call>`). Try inputs that mix them, nest one inside another's values, and cut a reply at any byte.
4. **Never worse.** Construct an input where the change is worse than before for any client, or show which families
   you tried. Check the probe outputs in `evidence/` against the description.
5. **Pre-existing faults** you meet on the way (a crash, an unchecked slice, a disagreement already on the base):
   report them separately, marked as not caused by this change.
6. **Verdict line**: `MERGE`, `MERGE AFTER CHANGES:` (each one line), or `DO NOT MERGE:` (the reason), and the facts.
