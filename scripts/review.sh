#!/usr/bin/env bash
# review.sh init DIR | run DIR [--timeout MIN]: stage 2 of AGENTS.md.
#   init: makes DIR with TASK.md (from templates/REVIEW-TASK.md) and src/; you add the patch, tree, draft text, evidence.
#   run:  runs a read-only reviewer on DIR/TASK.md (REVIEWER, default "codex exec --skip-git-repo-check") in its own
#         process group, writes the raw log to DIR/review-run.raw, waits for the reviewer to exit (or for its final
#         answer plus a grace period, since some reviewers stay alive after answering), extracts the answer that follows
#         the LAST "tokens used" line into DIR/REVIEW.md, and stops the whole reviewer process group if it is still
#         running. Exit 0 only with a non-empty REVIEW.md. The read-only rule is enforced by the task text (and by the
#         reviewer's own sandbox where it has one), not by this script: review the bundle, not the live tree.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
cmd=${1:-}; dir=${2:-}
[[ -n "$cmd" && -n "$dir" ]] || { echo "usage: $0 init DIR | run DIR [--timeout MIN]" >&2; exit 2; }
case "$cmd" in
init)
  [[ -e "$dir" ]] && { echo "$dir exists" >&2; exit 1; }
  mkdir -p "$dir/src" && cp "$here/templates/REVIEW-TASK.md" "$dir/TASK.md"
  echo "made $dir: edit $dir/TASK.md, put the code under $dir/src and the evidence next to TASK.md, then: $0 run $dir" ;;
run)
  timeout_min=90; [[ "${3:-}" == --timeout ]] && timeout_min=${4:?}
  [[ -s "$dir/TASK.md" ]] || { echo "$dir/TASK.md missing" >&2; exit 1; }
  grep -qi "read-only" "$dir/TASK.md" || { echo "TASK.md must state the read-only rule (see templates/REVIEW-TASK.md)" >&2; exit 1; }
  REVIEWER=${REVIEWER:-codex exec --skip-git-repo-check}
  raw="$dir/review-run.raw"; : > "$raw"; rm -f "$dir/REVIEW.md"
  # the task text is the reviewer's last argument; setsid gives the reviewer its own process group so it can be stopped whole
  ( cd "$dir" && exec setsid bash -c "$REVIEWER \"\$0\"" "$(cat TASK.md)" ) > "$raw" 2>&1 &
  pid=$!; echo "reviewer pid $pid (its own process group), log $raw"
  deadline=$(( $(date +%s) + timeout_min * 60 )); grace=""
  while kill -0 "$pid" 2>/dev/null; do
    if [[ -z "$grace" ]] && grep -q "^tokens used" "$raw"; then grace=$(( $(date +%s) + 60 )); fi   # answered: give it a minute to exit on its own
    [[ -n "$grace" && $(date +%s) -gt $grace ]] && { echo "reviewer answered but did not exit: stopping its process group"; break; }
    (( $(date +%s) > deadline )) && { echo "timeout after $timeout_min min" >&2; break; }
    sleep 10
  done
  if kill -0 "$pid" 2>/dev/null; then kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true; sleep 2; kill -9 -- "-$pid" 2>/dev/null || true; fi
  wait "$pid" 2>/dev/null; rc=$?
  n=$(grep -n "^tokens used" "$raw" | tail -1 | cut -d: -f1 || true)
  if [[ -z "$n" ]]; then echo "no final answer in $raw (reviewer exit $rc)" >&2; exit 1; fi
  tail -n +"$((n + 2))" "$raw" | sed -e '/^[[:space:]]*$/{1d;}' > "$dir/REVIEW.md"
  if [[ ! -s "$dir/REVIEW.md" || $(wc -w < "$dir/REVIEW.md") -lt 20 ]]; then echo "answer too short in $raw (reviewer exit $rc)" >&2; exit 1; fi
  echo "wrote $dir/REVIEW.md ($(wc -w < "$dir/REVIEW.md") words; reviewer exit $rc)"; grep -nE "SHIP|P1|P2|Verdict|verdict" "$dir/REVIEW.md" | head -20 || true ;;
*) echo "usage: $0 init DIR | run DIR" >&2; exit 2 ;;
esac
