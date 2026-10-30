# Evidence rules

Adapted from the measurement discipline of [The Grill](https://github.com/plotarmordev/thegrill) (`grill-perf`), the
benchmarking tool by plotarmordev used by Mia's AI Lab contributors, and from the agent-first contract of
[gb10-clock-cap](https://github.com/agjs/gb10-clock-cap) by agjs. Use `grill-perf` itself when the claim is a
performance claim that will go into a pull request.

## Performance

1. **Baseline, control, check.** Measure the unchanged build (baseline), measure it again with nothing changed
   (control, which shows the noise), then measure your change (check). A difference smaller than the control's spread is
   not a result.
2. **Alternate, do not batch.** A B, then B A (counterbalanced): drift (temperature, clocks, other load) then hits both sides.
3. **Record conditions**: GPU clock and temperature at start, concurrent load (agents, other clients), cache state
   (cold or warm), engine settings, image id.
4. **Verdict words** (Grill vocabulary): MEASURED FASTER / MEASURED SLOWER only with a control and a difference beyond
   its spread; INCONCLUSIVE when they overlap; DESCRIPTIVE ONLY without a control; INVALID when the control itself
   failed (a timeout, a crash, another workload).
5. Report medians with the range of all samples, and the number of runs.

## Correctness

1. **Same prompts, same seeds, greedy decoding**, compared by reply hash against the control build. "Identical" means
   the hashes matched; say how many of how many.
2. Cover the boundaries the change touches: chunk ends (2047/2048/2049 …), prefix-cache reuse (repeat, diverge,
   extend), long context, images, tool calls, both ranks' settings when they can differ.
3. A soak (minutes, client aborts mid-prefill, canary prompts whose replies must not change) for anything that touches
   lifetimes, threads or caches. Report errors, canary mismatches, restarts, and thread/descriptor counts; say
   "no sustained growth observed", not "flat", and make no memory claim unless memory was measured as such.

## Failure paths

1. Inject the failure (a test-only hook, never shipped) on each rank in turn. Record: did the request fail cleanly, did
   the process exit with the documented status in bounded time, did the next request after a restart match the
   reference reply.
2. Say how the restart happened (by the harness, or by a supervisor). If the design needs a supervisor that replaces
   every rank, say so in the PR.

## Wording

- "what the tests show" and "what the tests do not show" are separate sections; neither is optional.
- Numbers in text match the report exactly, with their units and conditions.
- A claim supplied from an earlier run says so ("in an earlier run on the previous pin").
