#!/usr/bin/env bash
# selftest.sh: checks the kit itself, no hardware or network needed. Exit 0 when everything passes.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0; ok() { echo "ok   $*"; }; bad() { echo "FAIL $*"; fail=1; }
for f in scripts/*.sh tests/*.sh; do bash -n "$f" && ok "bash -n $f" || bad "bash -n $f"; done
command -v shellcheck >/dev/null && { shellcheck -S warning scripts/*.sh tests/*.sh && ok shellcheck || bad shellcheck; }
for f in scripts/pairtest scripts/canary.py suites/*.py evals/agent26/*.py; do python3 -m py_compile "$f" && ok "compile $f" || bad "compile $f"; done
python3 -c "import yaml; yaml.safe_load(open('lab.example.yaml')); yaml.safe_load(open('owner.example.yaml'))" && ok "example yaml parses" || bad "example yaml"
out=$(python3 scripts/pairtest plan --lab lab.example.yaml --target control --dry 2>&1) && grep -q "tensorfold-dsv41:control" <<<"$out" && ok "pairtest plan (dry, inherit)" || bad "pairtest plan: $out"
# canary: a fix that a test catches, and one it does not
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/tree"; printf 'def add(a, b):\n    return a + b\n\ndef sub(a, b):\n    return a - b\n' > "$t/tree/m.py"
printf 'import sys; sys.path.insert(0, sys.argv[1]); import m\nassert m.add(2, 3) == 5, "add"\n' > "$t/test.py"
cat > "$t/mutants.yaml" <<'EOF'
- name: add_broken
  file: m.py
  old: "return a + b"
  new: "return a - b"
  expect: add
- name: sub_untested
  file: m.py
  old: |
    def sub(a, b):
        return a - b
  new: |
    def sub(a, b):
        return a + b
EOF
co=$(python3 scripts/canary.py --tree "$t/tree" --mutants "$t/mutants.yaml" -- python3 "$t/test.py" "{tree}" 2>&1)
grep -q "add_broken: CAUGHT" <<<"$co" && grep -q "sub_untested: SURVIVED" <<<"$co" && ok "canary caught / survived (multi-line mutant)" || bad "canary: $co"
# grader on two saved runs
( cd tests/fixtures && python3 ../../evals/agent26/score.py a b > /tmp/selftest-score.txt 2>&1 ) && grep -q "TOTAL" /tmp/selftest-score.txt && ok "score.py on fixtures: $(grep TOTAL /tmp/selftest-score.txt)" || bad "score.py"
rm -f tests/fixtures/blind-a-b.json
# review.sh refuses a task without the read-only line
d=$(mktemp -d); mkdir -p "$d/b"; echo "hello" > "$d/b/TASK.md"
scripts/review.sh run "$d/b" >/dev/null 2>&1 && bad "review.sh accepted a task without the read-only rule" || ok "review.sh requires the read-only rule"
cp templates/REVIEW-TASK.md "$d/b/TASK.md"
printf '#!/bin/sh\necho thinking\necho "tokens used"\necho 1,234\necho "**SHIP.** task had $(echo "$1" | wc -l) lines"\n' > "$d/fake-reviewer"; chmod +x "$d/fake-reviewer"
REVIEWER="$d/fake-reviewer" scripts/review.sh run "$d/b" >/dev/null 2>&1 && grep -q "SHIP.* task had [0-9]" "$d/b/REVIEW.md" && ok "review.sh runs the reviewer and extracts the answer" || bad "review.sh extract: $(cat "$d/b/review-run.raw" 2>/dev/null | head -3)"
rm -rf "$d"
# the command backend end to end: a local fake OpenAI server, two targets, smoke + boundary (chunk 8), restore
export KIT=$PWD
pkill -f 'fake_server.py 18611' 2>/dev/null; sleep 0.5
r=$(python3 scripts/pairtest run --lab tests/lab-fake.yaml --target a --compare b --suite smoke,boundary --runs /tmp/selftest-runs 2>&1)
rep=$(ls -dt /tmp/selftest-runs/2*/ 2>/dev/null | head -1)
grep -q "smoke" "$rep/report.md" 2>/dev/null && grep -q "OK" "$rep/report.md" && grep -qE "a vs b.*: 19 of 19" "$rep/report.md" && ok "pairtest run (command backend, local fake server): $(grep -o 'a vs b.*' "$rep/report.md")" || bad "pairtest run: $(echo "$r" | tail -5)"
curl -s -m 3 http://127.0.0.1:18611/v1/models | grep -q fake-model && ok "live restored after the run" || bad "live not restored"
pkill -f 'fake_server.py 18611' 2>/dev/null; rm -rf /tmp/selftest-runs
# every example lab parses and plans (dry)
for f in lab.example.yaml lab.examples/*.yaml tests/lab-fake.yaml; do python3 scripts/pairtest plan --lab "$f" --dry >/dev/null 2>&1 && ok "plan --dry $f" || bad "plan --dry $f"; done
exit $fail
