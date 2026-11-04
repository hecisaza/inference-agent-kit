# 2026-11-04: performance compared round by round

## What happened
A pull request (patch 0052 of the DeepSeek-V4.1-Flash 4x recipe, the fix for its issue #14) came back NOT READY from a
two-repetition hardware run on one metric: decode -1.10 % against a calibrated band of 1 %. Every other check was clean,
and the changed code does not run in the perf suite's requests (they carry no tools). Before looking further, one
replication was set with a fixed rule: four counterbalanced repetitions of the perf suite; within the band, the run
stands; beyond -1 %, the slowdown is treated as real and investigated, with no further rerun. The replication read
-1.87 %.

## What the investigation found
Decode speed depends on the prompt: with speculative decoding, each of the suite's prompts runs at one of two speeds,
about 56 or about 63 tok/s, on both builds alike. The verdict compared the median of each side's pooled rounds, so one
round landing in the other mode moved the result by one or two percent. The suite sends the same prompt to both targets
in the same round of a repetition, so the design is paired, and the paired comparison (the median of the round-by-round
ratios) is the estimator that matches it.

| run | pooled medians (old) | paired (new) |
|---|---|---|
| the PR, first version | decode -0.93 % | -0.42 % |
| the PR, second version | -0.92 % | -0.08 % |
| the PR, final version | -1.10 % | -0.34 % |
| the replication, four repetitions | -1.87 % | +0.08 % |
| same-image calibration runs | -0.26 %, +0.60 % | +0.33 %, +0.42 % |
| a deliberately slowed build (sensitivity check) | -3.97 %, -4.14 % | -3.63 %, -3.88 %, every round slower |

## What changed (kit 63fd325, 6cc9b1d)
- The perf suite records, next to each measurement, its round and a hash of its prompt; the verdict pairs rounds by that
  key, and by position for results recorded before it (marked "paired by position"). Only the perf suite's metrics
  (decode, prefill, aggregate) pair; cut-in, startup and the 16-stream aggregate keep medians. Each metric states how it
  was compared and how many rounds paired; unpaired rounds are counted, not shifted.
- A definite failure (a failed suite, memory growth, unexplained reply differences) now outranks a single-repetition
  slowdown: NOT READY, not RERUN.
- The calibration uses the same estimator. Two same-image runs bound nothing statistically, so the bands are provisional
  (expiring 2026-11-18) and none is narrower than the earlier calibration's. They are to be validated prospectively with
  more same-image runs.
- An independent read-only review of the change (Codex) concluded "adopt with changes"; the changes above are its
  conditions (recorded keys, the method per metric, provisional bands, this audit).

## Every verdict re-judged
All 20 runs with raw results on the evidence branches, judged by the old and the new code with identical inputs and the
same bands (the PR's own test results are not part of this re-judgment, so a READY earned from them shows as SAFE here):

| repository | PR | run | medians (old) | paired (new) |
|---|---|---|---|---|
| upstream | #27 | 20261102T004939 | RERUN | **SAFE, UNVERIFIED** |
| upstream | #37 | 20261101T194649 | SAFE, UNVERIFIED | SAFE, UNVERIFIED |
| upstream | #37 | 20261101T202723 | NOT READY | NOT READY |
| upstream | #37 | 20261101T213043 | SAFE, UNVERIFIED | SAFE, UNVERIFIED |
| upstream | #39 | 20261101T234801 | SAFE, UNVERIFIED | SAFE, UNVERIFIED |
| upstream | #41 | 20261102T013527 | RERUN | RERUN |
| upstream | #41 | 20261102T040358 | SAFE, UNVERIFIED | SAFE, UNVERIFIED |
| upstream | #42 | 20261101T224813 | SAFE, UNVERIFIED | **RERUN** |
| fork | #3 | 20261102T233015 | NOT READY | NOT READY |
| fork | #4 | 20261103T020546 | NOT READY | NOT READY |
| fork | #5 | 20261103T003117 | RERUN | RERUN |
| fork | #5 | 20261103T033538 | NOT READY | NOT READY |
| fork | #6 | 20261103T050851 | RERUN | **READY** |
| fork | #6 | 20261103T055023 | RERUN | RERUN |
| fork | #6 | 20261103T063435 | SAFE, UNVERIFIED | SAFE, UNVERIFIED |
| fork | #6 | 20261103T071745 | RERUN | **SAFE, UNVERIFIED** |
| fork | #6 | 20261103T104147 | READY | READY |
| fork | #6 | 20261104T030405 | READY | READY |
| fork | #6 | 20261104T055741 | NOT READY | **READY** |
| fork | #6 | 20261104T071712 | NOT READY | **READY** |

Six of twenty change. Four are runs of the PR above; upstream #27 moves from RERUN to SAFE, UNVERIFIED (decode -1 % by
medians, +0 % paired); upstream #42, already merged, moves from SAFE, UNVERIFIED to RERUN: prefill -1.x % paired over the
three rounds of a single repetition, for a change to start-script messages that no prefill runs through. Paired rounds
from a single repetition are few; a single-repetition slowdown asks for a counterbalanced rerun, as before, and does not
block. Both sensitivity checks that must fail (the memory leak and the decode slowdown) still come out NOT READY.

## Limits
A paired median estimates the typical prompt's effect and can hide a regression that affects a minority of prompts.
Six or twelve rounds over two or four repetitions give limited precision. Detection of the deliberate 4 % slowdown is
shown; detection of a 1.5 % slowdown under real noise is not.
