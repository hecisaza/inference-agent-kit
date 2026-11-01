# Evidence review: {{PR_URL}}, tested against its base on the lab

**READ-ONLY review. Do not write, create, move or delete any file; do not run builds, network, docker or git commands
that change anything. Read files only (cat, sed -n, grep, ls, diff; python3 only to compute on the data in this
bundle). Reply with the review as markdown on stdout, under 600 words. No host names, addresses or users: there are
none in this bundle, keep it that way.**

You are the second opinion on an automated hardware test of a pull request. A different system built the two images,
ran the suites and wrote the report. Your job is to say whether that evidence supports what the pull request claims,
and where it falls short. Do not trust the report: recompute.

## Layout
- `pr.patch`: the pull request's change, as a diff from its base to its head. `PR.md`: its title and description.
- `report.md`: the test report as generated. `results.json`: the raw results it was generated from, per suite, per
  target, per repetition; `meta` holds the candidate/control order, image ids, the public settings of each target and
  the restore outcome.
- `suites/`: the source of the tests that ran (`basic.py`: smoke, boundary, cutin, repro; `heavy.py`: soak, fault;
  `common.py`: the client and the prompt builders). `report.py`: what turned `results.json` into `report.md`.
- `run.txt`: candidate and control images with their ids, suites run, repetitions, restore outcome, wall clock.
- `executed-script.sh`, when present: the claim or reproduction script that ran as the repro suite (its rows are in
  `results.json` under `repro`). `hosttests.json`, when present: the pull request's own test files run on the PR and on
  the base with those files copied in, with the raw output of both runs.

## Questions, in this order
1. **Recompute from `results.json`**: identical boundary hashes (count and total), cut-in medians per target, soak
   counts and errors, each smoke check. Does `report.md` state them correctly? List every discrepancy, or say there is none.
2. **Read `pr.patch`.** Which code paths does it change? Did any suite exercise those paths (name the request or the
   condition that would, and whether it ran)? When the change sits on a failure path or a rare path the suites never
   trigger, say so plainly: the run then shows no regression, not that the change works.
3. **The claims in `PR.md`**: for each one, supported by this run, contradicted by it, or not tested.
4. **What weakens the evidence**: a single repetition with a fixed order, errors, a restore problem, different prompt
   sets between the targets, skipped suites, a control that is not the stated base, anything else you see.
5. **The oracles.** If `executed-script.sh` is present: does it test the stated claim (not a symptom that another
   change could also produce), does it assert the whole expected behaviour (a build that merely rejects the request
   must not pass), and does it keep a capability-preserving control? Answer on its own line, exactly one of
   `CLAIM TEST: SOUND`, `CLAIM TEST: UNSOUND`, or `CLAIM TEST: NONE` when there is no script, with one sentence why.
   If `hosttests.json` is present: read the test files named there in `pr.patch` and their raw output. Do they assert
   the behaviour the pull request claims, and does their failure on the base come from that behaviour rather than from
   setup (an import error, a missing file, a fixture)? Answer on its own line, exactly one of `AUTHOR TESTS: SOUND`,
   `AUTHOR TESTS: UNSOUND`, `AUTHOR TESTS: NOT INSPECTED` (when you could not read them), or `AUTHOR TESTS: NONE`,
   with one sentence why. The verdict reads these lines literally: an inspected, sound oracle is what turns a passing
   test into verification.
6. **Verdict, one line**, one of: `EVIDENCE SUPPORTS THE CLAIM` (the run verifies the stated claim with a sound oracle)
   / `NO REGRESSION SHOWN, CLAIM NOT TESTED` (the regression evidence is valid; the claim is not verified — including
   when the only claim test is unsound) / `EVIDENCE CONTRADICTS THE CLAIM` / `EVIDENCE UNRELIABLE` (the *measurement*
   itself cannot be trusted: an unhealthy control, an incomplete or inconsistent matrix, a restore problem, mismatched
   prompt sets — not merely an unsound claim test, which belongs to the previous line), followed by the two or three
   facts that decide it.
