# The process, stage by stage

The table in `AGENTS.md` is the summary. This page says what each stage produces and what has gone wrong before when
a stage was skipped.

## 0. Intake

Produces: a one-paragraph restatement of the task, and the output of

    scripts/sync.sh MiaAI-Lab/<recipe> <keywords...>

which lists the recipe's latest `main`, the patch numbers in use and the next free one, every open pull request with
the patches it adds or changes (and collisions between them), and open issues whose title matches the keywords.

Ask the owner to confirm: the scope, the base (latest `main`, or an open PR you stack on), and what to do about any
overlapping work (comment on it, wait for it, or stack on it).

Why: a fix built on a week-old pin collided with three new patch numbers, and a rebase PR made half of it obsolete;
a maintainer's open review questions turned out to be exactly what had been fixed locally.

## 1. Build and host-test

Produces: a branch, host test results, and a canary per fix.

- Branch from the base agreed in stage 0. Keep the diff to what the task needs.
- Run the recipe's host tests (CPU) before and after your change; record both totals. A test that fails the same way
  without your change is a known failure, not yours: show the before-run.
- For every fix, add a test that fails without it. Then prove it: `scripts/canary.py --tree <tree> --mutants mutants.yaml -- <test command with {tree}>`
  switches each fix back off in a scratch copy and checks the named test fails. A canary that survives means the test
  does not cover the fix; strengthen the test, not the canary.
- Paths no host test can reach (device code, collectives, a process restart) are listed as "checked by compile and
  reading only".

## 2. Review

Produces: `REVIEW.md` from a second, read-only agent.

    scripts/review.sh init bundles/<name>     # copies templates/REVIEW-TASK.md, makes src/
    # put the patch, the source tree, the draft PR text and the evidence in the bundle; edit TASK.md
    scripts/review.sh run bundles/<name>      # runs the reviewer, extracts REVIEW.md, stops a hung process

The task text itself states the read-only rule (some reviewers' sandbox flags do not work on every host). Ask for a
verdict per patch (SHIP / SHIP WITH CONDITIONS / DO NOT SHIP) with P1/P2/P3 findings at file:line, and for any claim in
the draft text the evidence does not support. Review code and text in the same pass; most late findings are wording.

## 3. Hardware

Produces: a run directory with a report.

    scripts/pairtest plan  --lab lab.yaml --target <name>         # print what would happen, change nothing
    scripts/pairtest build --lab lab.yaml --target <name>         # build on the build box, stream to all serving boxes
    scripts/pairtest run   --lab lab.yaml --target <name> --suite smoke,boundary,soak --compare <baseline-target>
    scripts/pairtest restore --lab lab.yaml                       # put back what lab.yaml says is live
    scripts/report.py runs/<time>                                 # (re)generate report.md, report.html and the charts

Get the owner's go for the downtime first (what goes down, how long, the fallback). The `restore` step always runs,
even when a suite fails. Compare against a control (the same build without your change), not against memory.

## 4. Pull request

Produces: the PR text, filled from `templates/PR.md` and the stage 3 report.

Re-read every sentence against the evidence: numbers match the report, "identical" means hashes matched, and the
"what the tests do not show" section is present. Follow the recipe's CHANGELOG and credits form.

Attach the run's visual documentation so reviewers can validate it without re-running anything: `pairtest run` leaves
`report.md` (a markdown section with the charts as relative SVG images), `report.html` (one self-contained page) and the
`.svg` files in the run directory. Copy the directory to `docs/evidence/<run>/` in the PR branch and link it from the PR
body, or attach the files to the PR by hand; fill in the "what this run does not show" list. Then ask for the go.

## 5. Follow-up

When the PR you stacked on merges, rebase and re-run stage 1 (and the smoke suite). Every public reply to a review
goes through the owner. When the PR merges, remove the local scratch state and note what is now live.
