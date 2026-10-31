#!/usr/bin/env bash
# hosttests.sh --pr DIR --base DIR --out FILE [--timeout S]
#
# The pull request's own tests, run the way a claim is run. The test files the PR adds or changes under tests/ are
# collected (diff of the two trees), run on the PR tree (they must pass) and then on a copy of the base tree with the
# PR's test files copied in (they must fail: that is the behaviour the tests were written for). Typed outcomes per
# side: passes (pytest exit 0), fails (exit 1), error (anything else: no tests collected, interrupted, usage). Verdict:
#   confirmed        pass on the PR, fail on the base   -> the author's tests isolate the change
#   not isolating    pass on both                       -> the tests do not depend on the change
#   fails on the PR  the PR's own tests fail on the PR
#   inconclusive     an error on either side
#   no tests         the PR adds or changes no test file
# Writes FILE as JSON ({files, candidate, control, verdict}) and prints the verdict line. Exit 0 always, 2 on usage.
# Needs python3 with pytest on this host (unittest files run under pytest). No network, no lab, no credentials.
set -uo pipefail
pr=""; base=""; out=""; timeout_s=600
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) pr=$2; shift 2;; --base) base=$2; shift 2;; --out) out=$2; shift 2;; --timeout) timeout_s=$2; shift 2;;
    *) echo "unexpected argument $1" >&2; exit 2;;
  esac
done
[ -d "$pr" ] && [ -d "$base" ] && [ -n "$out" ] || { echo "usage: hosttests.sh --pr DIR --base DIR --out FILE [--timeout S]" >&2; exit 2; }
pr=$(cd "$pr" && pwd); base=$(cd "$base" && pwd)
# the test files the PR adds or changes, and every other file it adds or changes under tests/ (helpers, fixtures)
changed=$( (cd "$pr" && find tests -type f 2>/dev/null) | while read -r f; do
  if [ ! -f "$base/$f" ] || ! cmp -s "$pr/$f" "$base/$f"; then echo "$f"; fi; done | sort)
tests=$(grep -E '^tests/(.*/)?test_[^/]*\.py$' <<<"$changed" || true)
py() { python3 - "$@"; }
if [ -z "$tests" ]; then
  py "$out" <<'PY'
import json, sys
json.dump({"files": [], "candidate": None, "control": None, "verdict": "no tests"}, open(sys.argv[1], "w"), indent=1)
PY
  echo "host tests: no tests — the pull request adds or changes no test file under tests/"; exit 0
fi
run() {  # $1: tree, $2: label -> prints "exit|outcome|summary"
  local rc o
  o=$(cd "$1" && env -u GH_TOKEN -u GITHUB_TOKEN timeout "$timeout_s" python3 -m pytest -q -p no:cacheprovider $tests 2>&1); rc=$?
  local outcome="error"; [ "$rc" = 0 ] && outcome="passes"; [ "$rc" = 1 ] && outcome="fails"
  printf '%s\n' "$o" > "$3"
  echo "$rc|$outcome|$(tail -n 3 <<<"$o" | tr '\n' ' ' | cut -c1-300)"
}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cand=$(run "$pr" candidate "$tmp/candidate.txt")
cp -a "$base" "$tmp/base"; mkdir -p "$tmp/base/tests"
while read -r f; do mkdir -p "$tmp/base/$(dirname "$f")"; cp "$pr/$f" "$tmp/base/$f"; done <<<"$changed"
ctrl=$(run "$tmp/base" control "$tmp/control.txt")
py "$out" "$cand" "$ctrl" "$tmp/candidate.txt" "$tmp/control.txt" <<EOF_FILES_PY
import json, sys
out, cand, ctrl, cf, kf = sys.argv[1:6]
def parse(s, f):
    rc, outcome, summary = s.split("|", 2)
    return {"exit": int(rc), "outcome": outcome, "summary": summary.strip(), "output_tail": open(f, errors="ignore").read()[-3000:]}
c, k = parse(cand, cf), parse(ctrl, kf)
files = """$tests""".split()
if c["outcome"] == "error" or k["outcome"] == "error": v = "inconclusive"
elif c["outcome"] == "fails": v = "fails on the PR"
elif k["outcome"] == "passes": v = "not isolating"
else: v = "confirmed"
json.dump({"files": files, "candidate": c, "control": k, "verdict": v}, open(out, "w"), indent=1)
print(f"host tests: {v} — {len(files)} test file(s); on the PR: {c['outcome']} (exit {c['exit']}); on the base with the PR's tests: {k['outcome']} (exit {k['exit']})")
EOF_FILES_PY
