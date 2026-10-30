#!/usr/bin/env bash
# evidence-review.sh RUN_DIR --checkout DIR --base SHA --head SHA [--pr-url URL] [--pr-file FILE] [--timeout MIN]
#
# A second opinion on a pairtest run from a different model than the one that did the work, read-only. Bundles the
# pull request's diff, the report, the raw results, the suites' source and the run facts under RUN_DIR/review/, hands
# the bundle to review.sh (REVIEWER, default Codex) with templates/EVIDENCE-REVIEW-TASK.md, and leaves RUN_DIR/REVIEW.md.
# It never fails a pipeline: when no review could be produced, RUN_DIR/review-missing.txt says why and the exit is 0.
# Nothing private goes into the bundle: no log.txt (host names, launch commands), only the report, results.json (the
# public settings, as pairtest writes it), the suites and the pull request's own text and diff; a bundle that still
# contains an address is not sent.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
run=${1:?usage: evidence-review.sh RUN_DIR --checkout DIR --base SHA --head SHA [--pr-url URL] [--pr-file FILE] [--timeout MIN]}; shift
checkout=""; base=""; head=""; pr_url=""; pr_file=""; timeout_min=20
while [ $# -gt 0 ]; do
  case "$1" in
    --checkout) checkout=$2; shift 2;; --base) base=$2; shift 2;; --head) head=$2; shift 2;;
    --pr-url) pr_url=$2; shift 2;; --pr-file) pr_file=$2; shift 2;; --timeout) timeout_min=$2; shift 2;;
    *) echo "unexpected argument $1" >&2; exit 2;;
  esac
done
missing() { echo "$*" > "$run/review-missing.txt"; echo "no second opinion: $*"; exit 0; }
[ -s "$run/results.json" ] || missing "no results.json in $run"
[ -s "$run/report.md" ] || missing "no report.md in $run"
[ -n "$checkout" ] && [ -n "$base" ] && [ -n "$head" ] || missing "--checkout, --base and --head are needed for the diff"
b="$run/review"; rm -rf "$b"; mkdir -p "$b/suites"
git -C "$checkout" diff "$base" "$head" > "$b/pr.patch" 2>/dev/null || missing "git diff $base $head failed in $checkout"
[ -s "$b/pr.patch" ] || missing "empty diff between $base and $head"
cp "$run/report.md" "$run/results.json" "$b/"
cp "$here"/suites/*.py "$b/suites/"; cp "$here/scripts/report.py" "$b/report.py"
if [ -n "$pr_file" ] && [ -s "$pr_file" ]; then cp "$pr_file" "$b/PR.md"; else printf '%s\n\n(no description was available)\n' "${pr_url:-the pull request}" > "$b/PR.md"; fi
python3 - "$run" "$b/run.txt" <<'PY'
import json, os, re, sys
run, out = sys.argv[1], sys.argv[2]
m = json.load(open(os.path.join(run, "results.json"))).get("meta", {})
t = m.get("targets", {})
def img(n): x = t.get(n, {}); return f"{n}: image {x.get('image') or x.get('artifact') or '-'} id {x.get('artifact_id') or '-'}"
lines = ["candidate " + img(m.get("candidate")), "control " + img(m.get("control")), f"suites: {', '.join(m.get('suites', []))}",
         f"repetitions: {m.get('opts', {}).get('reps', 1)}; order: {m.get('order')}", f"restore: {m.get('restore')}", f"kit: {m.get('kit')}", f"started: {m.get('started')}"]
try:
    ts = [l[:8] for l in open(os.path.join(run, "log.txt")) if re.match(r"\d\d:\d\d:\d\d ", l)]
    if ts: lines.append(f"wall clock: {ts[0]} to {ts[-1]} (the runner's local time)")
except OSError:
    pass
open(out, "w").write("\n".join(lines) + "\n")
PY
sed "s#{{PR_URL}}#${pr_url:-the pull request}#g" "$here/templates/EVIDENCE-REVIEW-TASK.md" > "$b/TASK.md"
# nothing private leaves the lab: an address or user@host in the report, the results or the run facts stops the review
if grep -qE "([0-9]{1,3}\.){3}[0-9]{1,3}|[A-Za-z0-9_.-]+@[A-Za-z0-9.-]+" "$b/report.md" "$b/results.json" "$b/run.txt"; then
  missing "the bundle contains an address or a user@host; not sent (check lab.public_env and the probes)"
fi
if "$here/scripts/review.sh" run "$b" --timeout "$timeout_min" > "$b/review.log" 2>&1 && [ -s "$b/REVIEW.md" ]; then
  sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/[address]/g' "$b/REVIEW.md" > "$run/REVIEW.md"   # belt and braces on the way out
  rm -f "$run/review-missing.txt"
  echo "second opinion: $run/REVIEW.md ($(wc -w < "$run/REVIEW.md") words, reviewer: ${REVIEWER:-codex exec --skip-git-repo-check})"
else
  missing "the reviewer gave no usable answer: $(tail -1 "$b/review.log" 2>/dev/null | cut -c1-160)"
fi
