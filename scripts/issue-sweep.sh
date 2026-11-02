#!/usr/bin/env bash
# issue-sweep.sh OWNER/REPO --fork OWNER/FORK [--dispatch] [--all] [--mode full|triage] [--limit N] [--workflow FILE]
#
# The open issues of a repository against the issue evidence the fork holds: one line per issue with the outcome of its
# latest run (from evidence/<owner>-<repo>-issue-<n> on the fork, written by the spark-issue workflow) or "no run".
# With --dispatch, starts the spark-issue workflow on the fork for every open issue that has no run (--all: every open
# issue), one dispatch per issue; the runner serializes them. --mode triage is the cheap sweep (no lab time): each run
# only classifies the issue. Dispatching runs third-party issue text through an agent on the runner and, for `api`
# issues, requests against the live build: do it for issues you have read.
set -euo pipefail
REPO=""; FORK=""; DISPATCH=0; ALL=0; MODE=full; LIMIT=100; WF=spark-issue.yml
while [ $# -gt 0 ]; do
  case "$1" in
    --fork) FORK=$2; shift 2;; --dispatch) DISPATCH=1; shift;; --all) ALL=1; shift;; --mode) MODE=$2; shift 2;;
    --limit) LIMIT=$2; shift 2;; --workflow) WF=$2; shift 2;; -h|--help) sed -n '2,11p' "$0"; exit 0;;
    *) [ -z "$REPO" ] && REPO=$1 || { echo "unexpected argument $1" >&2; exit 1; }; shift;;
  esac
done
[ -n "$REPO" ] && [ -n "$FORK" ] || { echo "usage: issue-sweep.sh OWNER/REPO --fork OWNER/FORK [--dispatch]" >&2; exit 1; }
case "$MODE" in full|triage) ;; *) echo "--mode is full or triage" >&2; exit 1;; esac
SLUG=$(tr / - <<<"$REPO")
issues=$(gh issue list -R "$REPO" --state open --limit "$LIMIT" --json number,title,createdAt,author,url)
branches=$(gh api "repos/$FORK/branches?per_page=100" --paginate 2>/dev/null | python3 -c '
import json, sys
s = sys.stdin.read().strip(); d = json.JSONDecoder(); i = 0   # --paginate concatenates one array per page
while i < len(s):
    arr, i = d.raw_decode(s, i); print("\n".join(b["name"] for b in arr))
    while i < len(s) and s[i].isspace(): i += 1
' 2>/dev/null || true)
printf '%-6s %-10s %-24s %-14s %s\n' "issue" "opened" "outcome" "latest run" "title"
todo=()
while IFS=$'\t' read -r n created url title; do
  [ -n "$n" ] || continue
  br="evidence/$SLUG-issue-$n"; outcome="no run"; latest="-"
  if grep -qx "$br" <<<"$branches"; then
    latest=$(gh api "repos/$FORK/contents/docs/evidence?ref=$br" 2>/dev/null | python3 -c 'import json,sys; d=[x["name"] for x in json.load(sys.stdin) if x["type"]=="dir"]; print(sorted(d)[-1] if d else "")' 2>/dev/null || true)
    if [ -n "$latest" ]; then
      outcome=$(gh api "repos/$FORK/contents/docs/evidence/$latest/verdict.json?ref=$br" -H "Accept: application/vnd.github.raw" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("class","?"))' 2>/dev/null || echo "?")
    else latest="-"; outcome="branch, no run"; fi
  fi
  printf '%-6s %-10s %-24s %-14s %s\n' "#$n" "${created:0:10}" "$outcome" "${latest:0:14}" "${title:0:70}"
  if [ "$ALL" = 1 ] || [ "$outcome" = "no run" ]; then todo+=("$url"); fi
done < <(python3 -c 'import json, sys
for i in json.load(sys.stdin): print(i["number"], i["createdAt"], i["url"], i["title"], sep="\t")' <<<"$issues")
echo
pending=$(gh run list -R "$FORK" --workflow "$WF" --limit 50 --json status --jq '[.[] | select(.status != "completed")] | length' 2>/dev/null || echo 0)
[ "${pending:-0}" != 0 ] && echo "$pending $WF run(s) queued or in progress on $FORK: their outcomes appear here when they finish"
if [ "$DISPATCH" = 1 ]; then
  for u in "${todo[@]:-}"; do [ -n "$u" ] || continue; gh workflow run "$WF" -R "$FORK" -f "issue=$u" -f "mode=$MODE" && echo "dispatched $u ($MODE)"; done
  echo "${#todo[@]} dispatched on $FORK ($WF, mode $MODE)"
else
  echo "${#todo[@]} issue(s) would be dispatched with --dispatch (mode $MODE): ${todo[*]:-none}"
fi
