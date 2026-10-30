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

## Questions, in this order
1. **Recompute from `results.json`**: identical boundary hashes (count and total), cut-in medians per target, soak
   counts and errors, each smoke check. Does `report.md` state them correctly? List every discrepancy, or say there is none.
2. **Read `pr.patch`.** Which code paths does it change? Did any suite exercise those paths (name the request or the
   condition that would, and whether it ran)? When the change sits on a failure path or a rare path the suites never
   trigger, say so plainly: the run then shows no regression, not that the change works.
3. **The claims in `PR.md`**: for each one, supported by this run, contradicted by it, or not tested.
4. **What weakens the evidence**: a single repetition with a fixed order, errors, a restore problem, different prompt
   sets between the targets, skipped suites, a control that is not the stated base, anything else you see.
5. **Verdict, one line**, one of: `EVIDENCE SUPPORTS THE CLAIM` / `NO REGRESSION SHOWN, CLAIM NOT TESTED` /
   `EVIDENCE CONTRADICTS THE CLAIM` / `EVIDENCE UNRELIABLE`, followed by the two or three facts that decide it.
