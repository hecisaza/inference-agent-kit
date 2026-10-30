#!/usr/bin/env bash
# selftest.sh: checks the kit itself, no hardware or network needed. Exit 0 when everything passes.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0; ok() { echo "ok   $*"; }; bad() { echo "FAIL $*"; fail=1; }
for f in scripts/*.sh tests/*.sh; do bash -n "$f" && ok "bash -n $f" || bad "bash -n $f"; done
command -v shellcheck >/dev/null && { shellcheck -S warning scripts/*.sh tests/*.sh && ok shellcheck || bad shellcheck; }
for f in scripts/pairtest scripts/canary.py suites/*.py evals/agent26/*.py; do python3 -m py_compile "$f" && ok "compile $f" || bad "compile $f"; done
if python3 -m pyflakes --version >/dev/null 2>&1; then python3 -m pyflakes scripts/pairtest scripts/*.py suites/*.py evals/agent26/*.py tests/*.py && ok "pyflakes clean" || bad "pyflakes"; else echo "note: pyflakes not installed (pip install pyflakes); skipping the undefined-name check"; fi
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
if ! docker image inspect python:3.12-slim >/dev/null 2>&1; then export AGENT26_SANDBOX=unsafe-local; echo "note: python:3.12-slim not present, grading model code locally for this self-test"; fi
( cd tests/fixtures && python3 ../../evals/agent26/score.py a b > /tmp/selftest-score.txt 2>&1 ) && grep -q "TOTAL" /tmp/selftest-score.txt && ok "score.py on fixtures: $(grep TOTAL /tmp/selftest-score.txt)" || bad "score.py"
rm -f tests/fixtures/blind-a-b.json
# review.sh refuses a task without the read-only line
d=$(mktemp -d); mkdir -p "$d/b"; echo "hello" > "$d/b/TASK.md"
scripts/review.sh run "$d/b" >/dev/null 2>&1 && bad "review.sh accepted a task without the read-only rule" || ok "review.sh requires the read-only rule"
cp templates/REVIEW-TASK.md "$d/b/TASK.md"
printf '#!/bin/sh\necho thinking\necho "tokens used"\necho 1,234\necho "**SHIP.** task had $(echo "$1" | wc -l) lines. This is a fake review answer long enough to pass the minimum length check of the extractor, with no findings at all."\n' > "$d/fake-reviewer"; chmod +x "$d/fake-reviewer"
REVIEWER="$d/fake-reviewer" scripts/review.sh run "$d/b" >/dev/null 2>&1 && grep -q "SHIP.* task had [0-9]" "$d/b/REVIEW.md" && ok "review.sh runs the reviewer and extracts the answer" || bad "review.sh extract: $(cat "$d/b/review-run.raw" 2>/dev/null | head -3)"
rm -rf "$d"
# the command backend end to end: a local fake OpenAI server, two targets on two ports, smoke + boundary (chunk 8), restore
export KIT=$PWD
for port in 18611 18612; do pgrep -f "fake_server.py $port" | xargs -r kill 2>/dev/null; done; sleep 0.5
r=$(python3 scripts/pairtest run --lab tests/lab-fake.yaml --target b --compare a --suite smoke,boundary --runs /tmp/selftest-runs 2>&1); rc=$?
rep=$(ls -dt /tmp/selftest-runs/2*/ 2>/dev/null | head -1)
[ "$rc" = 0 ] && grep -qE "\*\*19 of 19\*\*" "$rep/report.md" 2>/dev/null && ok "pairtest run (command backend, two local fake servers): exit 0, 19 of 19 hashes identical" || bad "pairtest run: rc=$rc $(echo "$r" | tail -4)"
grep -q "candidate" "$rep/report.md" && grep -q "Restore: live kept running (the last target, a, is the live configuration)" "$rep/report.md" && [ -s "$rep/report.html" ] && grep -q "does not show" "$rep/report.md" && ok "report.py: candidate/control from meta, live kept running when the control is live, limits list, html written" || bad "report.py output incomplete"
curl -s -m 3 http://127.0.0.1:18611/v1/models | grep -q fake-model && ok "live restored after the run" || bad "live not restored"
curl -s -m 2 http://127.0.0.1:18612/v1/models >/dev/null 2>&1 && bad "the tested target (port 18612) was left running" || ok "the tested target was stopped before live was restored"
# config_hash: image: and env.IMAGE are the same configuration; a different env or recipe_dir is not
python3 - <<'PY' && ok "config_hash: same config under image: or env.IMAGE; env and recipe_dir differences count" || bad "config_hash"
import importlib.machinery, types
m = importlib.machinery.SourceFileLoader("pairtest", "scripts/pairtest").load_module()
lab = types.SimpleNamespace(c={}, dry=False, sh=lambda host, cmd: "")
live = {"head": "h", "recipe_dir": "~/r", "start": "./start.sh", "env": {"PREPARE": "0", "IMAGE": "x:1"}}
ctrl = {"head": "h", "recipe_dir": "~/r", "start": "./start.sh", "image": "x:1", "env": {"PREPARE": "0"}}
assert m.config_hash(lab, live) == m.config_hash(lab, ctrl)
assert m.config_hash(lab, live) != m.config_hash(lab, {**ctrl, "env": {"PREPARE": "0", "TF_X": "1"}})
assert m.config_hash(lab, live) != m.config_hash(lab, {**ctrl, "recipe_dir": "~/pr"})
PY
# restore is a no-op while live is up (same server process afterwards), and starts live when it is down
pid=$(pgrep -f "fake_server.py 18611" | head -1)
r=$(python3 scripts/pairtest restore --lab tests/lab-fake.yaml 2>&1)
echo "$r" | grep -q "nothing to do" && [ "$(pgrep -f "fake_server.py 18611" | head -1)" = "$pid" ] && ok "restore leaves a healthy live alone (marker matches)" || bad "restore while live is up: $r"
pkill -f "fake_server.py 18611" 2>/dev/null; sleep 0.5
r=$(python3 scripts/pairtest restore --lab tests/lab-fake.yaml 2>&1)
curl -s -m 3 http://127.0.0.1:18611/v1/models | grep -q fake-model && ok "restore starts live when it is down" || bad "restore with live down: $r"
# --dry build + ship on a recipe-docker target: the plan is printed, nothing runs
r=$(python3 scripts/pairtest build --lab tests/lab-fake.yaml --target img --dry 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$r" | grep -q "would ship fake:img from here to there" && ok "build --dry (recipe-docker): build and ship plan printed" || bad "build --dry: rc=$rc $r"
# a failing suite fails the run, and live is still restored
r=$(python3 scripts/pairtest run --lab tests/lab-fake.yaml --target bad --suite smoke --runs /tmp/selftest-runs 2>&1); rc=$?
[ "$rc" = 1 ] && echo "$r" | grep -q "NOT OK: bad/smoke" && ok "a failing suite gives exit 1 and names the suite" || bad "failing suite: rc=$rc"
curl -s -m 3 http://127.0.0.1:18611/v1/models | grep -q fake-model && ok "live restored after the failing run" || bad "live not restored after the failing run"
# repro suite: the control (bad: wrong arithmetic) shows the problem, the candidate (a) does not -> ok; the other way round -> exit 1
r=$(python3 scripts/pairtest run --lab tests/lab-fake.yaml --target a --compare bad --suite repro --opt "repro_cmd=bash tests/fake-repro.sh {api} {model}" --runs /tmp/selftest-runs 2>&1); rc=$?
rep=$(ls -dt /tmp/selftest-runs/2*/ 2>/dev/null | head -1)
[ "$rc" = 0 ] && grep -q "Reproduced on the control and gone on the candidate" "$rep/report.md" 2>/dev/null && ok "repro suite: reproduced on the control, gone on the candidate (exit 0)" || bad "repro suite: rc=$rc $(echo "$r" | tail -3)"
r=$(python3 scripts/pairtest run --lab tests/lab-fake.yaml --target bad --compare a --suite repro --opt "repro_cmd=bash tests/fake-repro.sh {api} {model}" --runs /tmp/selftest-runs 2>&1); rc=$?
rep=$(ls -dt /tmp/selftest-runs/2*/ 2>/dev/null | head -1)
[ "$rc" = 1 ] && echo "$r" | grep -q "NOT OK: bad/repro" && grep -q "Not reproduced on the control" "$rep/report.md" && ok "repro suite: the inverse (candidate shows it, control does not) fails the run and says the control did not reproduce" || bad "repro suite inverse: rc=$rc"
# issue-agent.sh with a fake agent and a fake gh: a local bare "origin", the live build = the bad server (shows the problem)
nohup python3 tests/fake_server.py 18612 --wrong > /dev/null 2>&1 &
badpid=$!; sleep 0.7
ia=$(mktemp -d); mkdir -p "$ia/bin"; install -m 755 tests/fake-gh "$ia/bin/gh"
git init -q --bare "$ia/origin.git"; git clone -q "$ia/origin.git" "$ia/seed" 2>/dev/null; echo "# seed" > "$ia/seed/README.md"
git -C "$ia/seed" add README.md; git -C "$ia/seed" -c user.name=seed -c user.email=seed@example.com commit -q -m seed; git -C "$ia/seed" push -q origin HEAD:main 2>/dev/null; git -C "$ia/origin.git" symbolic-ref HEAD refs/heads/main
iarun() { FAKE_GH_LOG="$ia/gh.log" PATH="$ia/bin:$PATH" CLONE_URL="$ia/origin.git" AGENT_CMD="bash $PWD/tests/fake-agent.sh" LIVE_MODEL=fake-model GH_TOKEN=should-not-reach-the-agent bash scripts/issue-agent.sh "$@" --repo o/r --work "$ia/work" 2>&1; }
: > "$ia/gh.log"
r=$(LIVE_API=http://127.0.0.1:18612/v1 iarun https://github.com/o/r/issues/7); rc=$?
[ "$rc" = 0 ] && grep -q "RESULT: pr https://github.com/o/r/pull/99" <<<"$r" && grep -q "pr create -R o/r --head agent/issue-7 --title fix: issue 7 (fake) --body-file body.md --label test" "$ia/gh.log" && git -C "$ia/origin.git" rev-parse -q --verify agent/issue-7 >/dev/null && grep -q "Closes #7" "$ia/work/o-r-7/body.md" && ok "issue-agent: reproduced -> branch pushed, PR opened with the test label, no token for the agent" || bad "issue-agent reproduced: rc=$rc $(tail -3 <<<"$r")"
: > "$ia/gh.log"
r=$(LIVE_API=http://127.0.0.1:18611/v1 iarun https://github.com/o/r/issues/7); rc=$?
[ "$rc" = 0 ] && grep -q "RESULT: unclear (comment posted" <<<"$r" && grep -q "issue comment" "$ia/gh.log" && ! grep -q "pr create" "$ia/gh.log" && ok "issue-agent: a repro script that does not show the problem on live downgrades to unclear, no PR" || bad "issue-agent downgrade: rc=$rc $(tail -3 <<<"$r")"
: > "$ia/gh.log"
r=$(FAKE_AGENT_VERDICT=not-reproduced LIVE_API=http://127.0.0.1:18612/v1 iarun https://github.com/up/stream/issues/3); rc=$?
[ "$rc" = 0 ] && grep -q "RESULT: not-reproduced (draft comment at" <<<"$r" && ! grep -q "issue comment\|pr create" "$ia/gh.log" && [ -s "$ia/work/up-stream-3/COMMENT.md" ] && ok "issue-agent: not reproduced on an upstream issue -> draft comment only, nothing posted" || bad "issue-agent upstream: rc=$rc $(tail -3 <<<"$r")"
kill "$badpid" 2>/dev/null; rm -rf "$ia"
# --dry: no command runs and no request is sent (no server is up for a's port after this stop)
pkill -f "fake_server.py 18611" 2>/dev/null; sleep 0.5
r=$(python3 scripts/pairtest run --lab tests/lab-fake.yaml --target a --suite smoke,cutin --runs /tmp/selftest-runs --dry 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$r" | grep -q "\[dry\] would run suite cutin" && ! curl -s -m 1 http://127.0.0.1:18611/v1/models >/dev/null 2>&1 && ok "--dry runs nothing and starts nothing" || bad "--dry: rc=$rc"
for port in 18611 18612; do pgrep -f "fake_server.py $port" | xargs -r kill 2>/dev/null; done; rm -rf /tmp/selftest-runs
# canary refuses a mutant that names a symlink or an absolute path
t2=$(mktemp -d); mkdir -p "$t2/tree"; echo "x = 1" > "$t2/real.py"; ln -s "$t2/real.py" "$t2/tree/link.py"
printf -- '- {name: via_link, file: link.py, old: "x = 1", new: "x = 2"}\n- {name: abs, file: /etc/hostname, old: a, new: b}\n' > "$t2/m.yaml"
co=$(python3 scripts/canary.py --tree "$t2/tree" --mutants "$t2/m.yaml" -- true 2>&1)
grep -q "via_link: REFUSED" <<<"$co" && grep -q "abs: REFUSED" <<<"$co" && grep -q "x = 1" "$t2/real.py" && ok "canary refuses symlinks and absolute paths; the original is untouched" || bad "canary containment: $co"
rm -rf "$t2"
# every example lab parses and plans (dry)
for f in lab.example.yaml lab.examples/*.yaml tests/lab-fake.yaml; do python3 scripts/pairtest plan --lab "$f" --dry >/dev/null 2>&1 && ok "plan --dry $f" || bad "plan --dry $f"; done
exit $fail
