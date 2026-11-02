# The pipeline: a pull request or an issue, tested on the lab without a person at the keyboard

Two GitHub Actions workflows on a fork of the recipe, a self-hosted runner that can reach the lab, and this kit. The
workflows live in the fork's default branch (`.github/workflows/spark-test.yml` and `spark-issue.yml`); the runner runs
`pairtest`, `issue-agent.sh` and the rest of the kit from its checkout of this repository.

```
  PR here, labelled `test`  ─┐
  "Run workflow" + PR URL   ─┼─► spark-test ─► build PR + base ─► ship ─► pairtest PR vs base ─► restore live
  spark-issue opened a PR   ─┘                 (lab's local.sh minus TF_*)   smoke boundary cutin soak [repro]
                                                                                         │
                                                      evidence commit + comment on the PR (here) ◄┘
                                                      evidence/ branch + run summary (a PR elsewhere)

  issue here, labelled `agent` ─┐
  "Run workflow" + issue URL    ─┼─► spark-issue ─► triage (api / lab / feature / elsewhere)
  issue-sweep.sh --dispatch     ─┘                 api ─► agent: reproduce on live, fix on a branch ─► issue-agent.sh
                                                    confirms the repro on live ─► PR opened with `test` ─► spark-test
                                                    (same run) ─► issue outcome (FIXED … OUT OF SCOPE) ─► evidence/
                                                    …-issue-N branch + comment and label (here) / run summary (elsewhere)
```

## What is compared

The candidate is the pull request **merged onto its current base** (GitHub's test merge), the control is that base: the
difference between the two builds is exactly the PR's change on today's main, however old the branch is. A PR that
does not merge cleanly is tested as its head against the commit it branched from (the merge-base), and the comment
says so; the author still has to rebase before anyone can merge it. The evidence commit goes on the PR head, never on
the test merge.

## What is automatic, and what is not

| step | who | gate |
|---|---|---|
| start a test of a PR of the fork | a person adds the label `test` (authors in the workflow's allowlist) or runs the workflow | the label or the dispatch |
| start a test of a PR anywhere (the upstream recipe) | a person runs the workflow with the PR's URL | the dispatch: a PR's code and its `tests/repro-issue-*.sh` run on the lab and on the runner, so dispatch only a PR you have read |
| build, ship, test PR against base, restore live, evidence, comment on the fork's PR | the workflow | none; a failed build or suite is reported as such |
| anything on another repository (a comment on the upstream PR, a PR upstream) | a person, from the run summary and the evidence branch | the owner's go, every time |
| start the agent on an issue | a person adds the label `agent`, runs the workflow with the issue URL (mode `full` or `triage`), or runs `scripts/issue-sweep.sh OWNER/REPO --fork FORK --dispatch` for every open issue without a run | the label or the dispatch: an issue's text goes through an agent on the runner, and an `api` issue's reproduction hits the live build, so dispatch issues you have read |
| triage: how can this lab work on it | a triage agent, read-only, writes `triage.json` (`templates/ISSUE-TRIAGE-TASK.md`): `api` (reproducible through the served API), `lab` (needs a configuration, a restart, a crash, hardware or a load the live build does not take), `feature`, `elsewhere` | only `api` goes on; `lab` ends as NEEDS THE LAB with the condition written down, the others as OUT OF SCOPE; a missing or unusable triage is treated as `api` |
| reproduce, fix, write `REPRO.md`, `tests/repro-issue-N.sh`, `PR.md` | the agent, in a checkout, with no token | the task template (`templates/ISSUE-TASK.md`) and `AGENTS.md` |
| confirm the reproduction on the live build, push the branch, open the PR on the fork, label it | `scripts/issue-agent.sh` | the agent's script must exit non-zero against live; otherwise the verdict becomes `unclear` and no PR is opened. A reproduction without a fix is confirmed the same way and ends as REPRODUCED, no PR |
| test that PR against its base | spark-test, in the same run | the repro suite: the script must show the problem on the base and not on the PR, or the run fails |
| issue outcome | `scripts/issue-verdict.py`, from the agent's `outcome.json` and the PR's test verdict: **FIXED** (PR open, test READY) / **FIX PROPOSED** (PR open, test SAFE, UNVERIFIED or RERUN) / **FIX FAILS** (test NOT READY) / **REPRODUCED** (confirmed on live, no fix) / **NOT REPRODUCIBLE HERE** / **UNCLEAR** / **NEEDS THE LAB** / **OUT OF SCOPE** / **TRIAGED** | a comment and the label `issue:<outcome>` on an issue of the fork; the run summary for an issue elsewhere; FIXED is verified, not merged |
| second opinion on the evidence | `scripts/evidence-review.sh`: a different model (Codex by default), read-only, gets the PR diff, the report, the raw results and the suites' source; recomputes the report, says which changed paths the suites exercised, grades each claim | advisory: its verdict is appended to the comment and kept with the evidence; a missing reviewer is reported, never hidden |
| merge readiness | `scripts/verdict.py`, from the results, the second opinion and stage 0's collision check: **READY** (every suite green, replies identical or different exactly as claimed, no slowdown, the claim exercised and confirmed — repro, a supporting second opinion, or a measured speed-up — no collision) / **SAFE, UNVERIFIED** (no regression, no slowdown, the changed path not exercised) / **NOT READY** (a failed suite, unexplained differences, a slowdown beyond the noise, a repro still failing, a collision, a contradicting second opinion) / **RERUN** (restore failed, the control failed, evidence unreliable). Performance = decode, prefill and aggregate tokens/s from the `perf` suite and the cut-in latency, candidate against control, counted only beyond the larger of ±3 % and the rounds' spread | first lines of the comment; label `evidence:ready|unverified|blocked|rerun` on PRs of the fork |
| merge, or carry the fix upstream | a person | READY is the evidence's word, not the merge; SAFE, UNVERIFIED is a code-review decision; the owner's go for anything upstream |
| keep the fork's main at upstream's latest | `sync-upstream.yml`, daily and on demand: merges the upstream default branch into main (a merge commit keeps the workflows); a conflict fails the job and changes nothing | GitHub keeps scheduled runs off on a fork until enabled once in the Actions tab |

The agent's trust boundary is the runner host: it works as the runner's user with the runner's SSH keys, under the rules
of its task (read-only on the lab hosts, the live API only, no pushing or posting). Those rules are an instruction, not a
sandbox. Give it issues you would give a new contributor with the same access.

## From SAFE, UNVERIFIED to READY: the verify step

SAFE, UNVERIFIED means no suite exercised what the pull request changes. The second opinion says in its section 2 what
would. On the first attempt of a run that ends there, the `verify` job hands the diff, the description, the second
opinion and the report to an agent (`scripts/claim-agent.sh`, task `templates/CLAIM-TASK.md`, no token) that writes
`claim.sh API MODEL`: evidence lines, then `CLAIM: holds` (exit 0) or `CLAIM: does not hold` (exit 1). The script is
run against the live build, which normally serves the current main and so stands in for the base (a lab whose live
build is older than the PR's base weakens this check; the rerun against the real base is what counts): it must say the
claim does not hold there, or it does not isolate the change; the agent gets one correction round. An accepted claim is committed under `claims/<owner>-<repo>-pr-<n>.sh`
on the fork's main and the pipeline is dispatched again for the same PR (`attempt=2`, the cap). That run picks the
claim up as the repro suite: fails on the base and passes on the PR → READY; passes on both → stays UNVERIFIED, the
test does not isolate the change; fails on both → inconclusive, the test observes nothing (UNVERIFIED, never a mark
against the PR); passes on the base and fails on the PR → NOT READY; a script that errors (exit other than 0 or 1,
or a timeout) on either side → inconclusive. The claims accumulate on the
fork as a library a PR author can be handed. A NOT READY on someone else's PR is theirs to fix; the pipeline reports.

## Three more ways a change gets verified

- **The pull request's own tests** (`scripts/hosttests.sh`): the test files the PR adds or changes under `tests/` run on
  the PR tree and on a copy of the base tree with those files copied in. Pass on the PR and fail on the base is the
  author's own isolation of the change and counts as verified; pass on both means the tests do not depend on the
  change; fail on the PR blocks. No lab time, no agent.
- **Startup time**: every switch records the seconds from stopping the previous configuration to the new one
  answering, compared like the other performance metrics (a load-path PR claims exactly this).
- **The server log for claim scripts**: a target may carry `log_cmd` (a command that prints the head's recent log);
  the claim script receives it as its third argument, so a claim about what the server logs can be tested. Output
  tails are redacted of addresses before they become evidence.

## What a run produces

- `docs/evidence/<run>/report.md`, `report.html` and the charts, committed to the PR branch (a PR of the fork) or to
  `evidence/<owner>-<repo>-pr-<n>` on the fork (a PR elsewhere), and the same files as a run artifact.
- A comment on the PR of the fork with the first 200 lines of the report and the second opinion; for a PR elsewhere,
  the same text in the run summary, ready to paste once the owner says so.
- `VERDICT.md` and `verdict.json`: the merge-readiness class with its reasons and the facts it rests on.
- On a verify run: the agent's claim attempt (task, rounds, the run on the base) as an artifact, and `claims/…sh` on main.
- `REVIEW.md`: the second opinion (verdict line: EVIDENCE SUPPORTS THE CLAIM / NO REGRESSION SHOWN, CLAIM NOT TESTED /
  EVIDENCE CONTRADICTS THE CLAIM / EVIDENCE UNRELIABLE), or `review-missing.txt` with the reason there is none.
- For an issue: `docs/evidence/issue-<n>-<time>-run<id>/` on `evidence/<owner>-<repo>-issue-<n>` (append-only) with
  `VERDICT.md`, `verdict.json`, `outcome.json`, `triage.json`, the agent's `REPRO.md` and `COMMENT.md`, the live
  reproduction log and the run log (redacted copies), and the PR's test verdict when there was one; the same as a run
  artifact; a PR with `Closes #n` when the issue is on the fork, or `Issue: <url>` when it is elsewhere.
  `scripts/evidence-page.py` lists issue branches in their own table.

## Setting it up on another lab

1. `lab.pipeline.yaml` next to `lab.yaml` (both private): the live section, a `base` and a `pr` target whose images are
   `__BASE_IMAGE__` and `__PR_IMAGE__` (the workflow substitutes them), with `build:` sections pointing at checkouts on
   the build host; see `lab.example.yaml`.
2. A build script on the build host that builds the checkout in `$CHECKOUT` as `$IMAGE` the way the recipe's own
   `prepare.sh` does (same patch hash). The workflow passes `CHECKOUT` per target.
3. The runner: GitHub's self-hosted runner on a host with SSH to the lab, labels `self-hosted,spark-lab`, registered on
   the fork. Install it as a service so it survives a reboot: in the runner directory, `sudo ./svc.sh install <user>`
   then `sudo ./svc.sh start` (a plain `./run.sh` dies with the shell). One runner with that label is what serializes
   the lab: it takes one job at a time and GitHub queues the rest. Do not add a `concurrency` group for this: a group
   keeps a single pending run and cancels every other one that arrives while a run is in progress.
4. The two workflow files on the fork's default branch, with the author allowlist, the lab addresses and the live model
   edited for the lab. `pull_request_target` reads the workflow from the default branch, so changes to it go there.
5. The second opinion needs a reviewer on the runner host: Codex (`codex exec`) logged in as the runner's user, or
   `REVIEWER` set in the workflow to another read-only agent command. Use a different model than the one that writes
   the code; the point is an independent reading of the same evidence.
6. For the issue workflow, the agent command on the runner host: the default is Claude Code headless
   (`claude -p --permission-mode acceptEdits --allowedTools ...`); set `AGENT_CMD` in the workflow for another agent.
   The kit's `scripts/install-skill.sh` gives Claude Code the process skill.

## Running it by hand

```
scripts/pairtest build --lab lab.run.yaml --target base && scripts/pairtest build --lab lab.run.yaml --target pr
scripts/pairtest run --lab lab.run.yaml --target pr --compare base --suite smoke,boundary,cutin,perf,soak,repro --opt reps=2 \
    --opt "repro_cmd=bash tests/repro-issue-12.sh {api} {model}"      # the repro suite, when the PR fixes an issue
scripts/evidence-review.sh runs/<run> --checkout . --base <base sha> --head <head sha> --pr-url <url>   # the second opinion
LIVE_API=http://head:8888/v1 LIVE_MODEL=<model> scripts/issue-agent.sh https://github.com/<owner>/<repo>/issues/12 --repo <fork>
scripts/issue-verdict.py ~/.cache/inference-agent-kit/issues/<owner>-<repo>-12 [--test-verdict runs/<run>/verdict.json]
scripts/issue-sweep.sh <owner>/<repo> --fork <fork>              # every open issue against the fork's issue evidence; --dispatch runs the missing ones
```

`tests/selftest.sh` covers the repro suite, `issue-agent.sh` (triage, reproduction with and without a fix, posting),
`issue-verdict.py` and `issue-sweep.sh` with a fake agent and a fake `gh`, no hardware needed.
