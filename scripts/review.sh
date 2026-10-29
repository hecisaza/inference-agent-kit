#!/usr/bin/env bash
# review.sh init DIR | run DIR [--timeout MIN]: stage 2 of AGENTS.md.
#   init: makes DIR with TASK.md (from templates/REVIEW-TASK.md) and src/; you add the patch, tree, draft text, evidence.
#   run:  runs a read-only reviewer on DIR/TASK.md (REVIEWER, default "codex exec --skip-git-repo-check"), writes the raw
#         log to DIR/review-run.raw, extracts the final answer into DIR/REVIEW.md, and stops the reviewer if it is still
#         running after the answer (some reviewers keep the process alive after answering).
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
  raw="$dir/review-run.raw"; : > "$raw"
  # REVIEWER is a command line; the task text is passed as its last argument
  ( cd "$dir" && exec bash -c "$REVIEWER \"\$0\"" "$(cat TASK.md)" ) > "$raw" 2>&1 &
  pid=$!; echo "reviewer pid $pid, log $raw"
  deadline=$(( $(date +%s) + timeout_min * 60 )); answered=0
  while kill -0 "$pid" 2>/dev/null; do
    if grep -q "^tokens used" "$raw"; then answered=1; sleep 30; break; fi
    (( $(date +%s) > deadline )) && { echo "timeout after $timeout_min min" >&2; break; }
    sleep 15
  done
  grep -q "^tokens used" "$raw" && answered=1
  if kill -0 "$pid" 2>/dev/null; then echo "stopping reviewer pid $pid (still running after $( ((answered)) && echo answer || echo timeout))"; kill "$pid" 2>/dev/null || true; fi
  if ((answered)); then
    n=$(grep -n "^tokens used" "$raw" | tail -1 | cut -d: -f1)
    tail -n +"$((n + 2))" "$raw" > "$dir/REVIEW.md"
    echo "wrote $dir/REVIEW.md ($(wc -w < "$dir/REVIEW.md") words)"; grep -nE "SHIP|P1|P2" "$dir/REVIEW.md" | head -20 || true
  else
    echo "no final answer found in $raw" >&2; exit 1
  fi ;;
*) echo "usage: $0 init DIR | run DIR" >&2; exit 2 ;;
esac
