# Review request: <title>

**READ-ONLY review. Do not write, create, move or delete any file; do not run builds, network, docker or git commands
that change anything. Read files only (cat, sed -n, grep, ls, diff). Reply with the review as markdown on stdout.**
<Optional: keep it under N words.>

## Layout
- `src/<tree>/`: the full patched tree; cite file:line in it.
- `<patch files>`: the change; `<earlier versions or v1-to-v2.diff>` if this follows an earlier review.
- `PR-DRAFT.md`: the text that will be posted. Check every claim against the source and the evidence.
- `<evidence files>`: what was run, where, with which settings.
- Host tests: <N/M, known failures>. Canaries: <file>.

## What changed (verify each)
1. <claim>
2. <claim>

## Questions
1. Does each change do what it claims? Any new bug: lifetimes, locking, error paths, cross-rank agreement, cleanup?
2. Do the tests exercise the production code, and would they fail without the fix?
3. Is any statement in PR-DRAFT.md not supported by the source or the evidence?
4. Verdict per patch: SHIP / SHIP WITH CONDITIONS / DO NOT SHIP, with P1/P2/P3 findings (file:line), separating
   (a) bugs shown in the source from (b) test or evidence gaps.
