# Task: issue {{ISSUE_URL}} — reproduce it, and fix it when it is real

You work in a checkout of `{{REPO}}` on branch `{{BRANCH}}`. Read `{{KIT}}/AGENTS.md` first: it is the contract for every
agent on this project, and it applies here.

## Rules that are never skipped

- You do not push, post, comment, open pull requests or contact anyone. The script that started you does that from the
  files you leave behind. You hold no token; do not look for one.
- The live build serves `{{LIVE_MODEL}}` at `{{LIVE_API}}` (an OpenAI-compatible API). Reproduce against it. Do not stop,
  restart or reconfigure it, and run nothing on the lab hosts beyond read-only commands (nvidia-smi, docker ps, reading logs).
  Downtime tests are the pipeline's job, after your pull request is opened.
- Public text stays neutral: no host names, addresses, users or hardware faults in anything that goes into the pull request.
- Credit stays: keep every author line and attribution already in the tree. The fix is contributed by the repository owner;
  no agent trailers in commit messages.
- A claim follows evidence: say "reproduced" only when you saw the problem with your own commands, and show them.

## What you leave behind (all paths relative to the checkout root)

1. `REPRO.md` — first line exactly one of `VERDICT: reproduced`, `VERDICT: not-reproduced`, `VERDICT: unclear`. Then, in
   plain prose with the commands and trimmed outputs: what the issue claims, what you ran, what you saw, your reading of
   it. Write it also when you could not reproduce: that is the useful answer to the issue.
2. When reproduced: `tests/repro-issue-{{N}}.sh API MODEL` — a script that exits non-zero while the problem shows and 0
   when it is gone, using only the API (curl or python3), finishing in under ten minutes, deterministic (temperature 0).
   The pipeline runs it against the base and against your fix. Commit it together with the fix.
3. When reproduced: the fix, committed on this branch in small commits with plain messages, following the repository's own
   conventions (an engine change is a new numbered patch under `zig/patches/`, listed in the README's patch table; a
   script change is the script). Run the repository's own checks if it has any, and your repro script against a local
   build when one can be made without the lab. Say in `REPRO.md` what you could not run.
4. When reproduced: `PR.md` — first line the pull request title; then the body in the shape of
   `{{KIT}}/templates/PR.md` (claim, change, evidence with the reproduction output before and after, what is not shown).

Do not commit `REPRO.md` or `PR.md`. Stop when the files above exist; do not open a pull request yourself.

## The issue

{{ISSUE_MD}}
