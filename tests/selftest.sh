#!/usr/bin/env bash
# selftest.sh: checks the kit itself, no hardware or network needed. Exit 0 when everything passes.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0; ok() { echo "ok   $*"; }; bad() { echo "FAIL $*"; fail=1; }
for f in scripts/*.sh tests/*.sh; do bash -n "$f" && ok "bash -n $f" || bad "bash -n $f"; done
command -v shellcheck >/dev/null && { shellcheck -S warning scripts/*.sh tests/*.sh && ok shellcheck || bad shellcheck; }
for f in scripts/pairtest scripts/*.py suites/*.py evals/agent26/*.py; do python3 -m py_compile "$f" && ok "compile $f" || bad "compile $f"; done
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
python3 scripts/verdict.py "$rep" > /tmp/selftest-verdict.txt 2>&1 && grep -q "Merge readiness: SAFE, UNVERIFIED" /tmp/selftest-verdict.txt && ok "verdict.py: green run without a claim test or a second opinion -> SAFE, UNVERIFIED" || bad "verdict unverified: $(cat /tmp/selftest-verdict.txt)"
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
# verdict.py: the repro run (control shows, candidate does not) + a supporting second opinion -> READY; the inverse run -> NOT READY;
# no repro and no review -> SAFE, UNVERIFIED; a collision line naming the PR -> NOT READY; a failed restore -> RERUN
vd=$(mktemp -d); good=$(ls -dt /tmp/selftest-runs/2*/ | sed -n 2p); inv=$(ls -dt /tmp/selftest-runs/2*/ | sed -n 1p)
echo "**EVIDENCE SUPPORTS THE CLAIM** — the fake reviewer agrees." > "$vd/REVIEW.md"
python3 scripts/verdict.py "$good" --review "$vd/REVIEW.md" > "$vd/o1" 2>&1 && grep -q "Merge readiness: READY" "$vd/o1" && grep -q '"label": "evidence:ready"' "$good/verdict.json" && ok "verdict.py: repro confirmed + supporting second opinion -> READY" || bad "verdict READY: $(cat "$vd/o1")"
python3 scripts/verdict.py "$inv" > "$vd/o2" 2>&1 && grep -q "Merge readiness: NOT READY" "$vd/o2" && ok "verdict.py: the candidate that still shows the problem -> NOT READY" || bad "verdict NOT READY: $(cat "$vd/o2")"
printf 'COLLISION: patch 0040 is added by #7 #9\n' > "$vd/sync.txt"
python3 scripts/verdict.py "$good" --review "$vd/REVIEW.md" --sync "$vd/sync.txt" --pr 7 > "$vd/o3" 2>&1 && grep -q "NOT READY.*collides" "$vd/o3" && ok "verdict.py: a patch-number collision naming the PR -> NOT READY" || bad "verdict collision: $(cat "$vd/o3")"
python3 - "$good" "$vd" <<'PY'
import json, sys, shutil, os
src, d = sys.argv[1], sys.argv[2]; os.makedirs(d + "/rerun", exist_ok=True)
R = json.load(open(os.path.join(src, "results.json"))); R["meta"]["restore"] = "RESTORE FAILED: boom"; json.dump(R, open(d + "/rerun/results.json", "w"))
PY
python3 scripts/verdict.py "$vd/rerun" > "$vd/o4" 2>&1 && grep -q "Merge readiness: RERUN" "$vd/o4" && ok "verdict.py: a failed restore -> RERUN" || bad "verdict RERUN: $(cat "$vd/o4")"
rm -rf "$vd"
# perf suite against the fake servers: numbers come out, no errors, the report has the table
r=$(python3 scripts/pairtest run --lab tests/lab-fake.yaml --target a --compare b --suite perf --opt perf_rounds=1 --opt perf_words=40 --opt perf_streams=2 --runs /tmp/selftest-runs 2>&1); rc=$?
rep=$(ls -dt /tmp/selftest-runs/2*/ 2>/dev/null | head -1)
[ "$rc" = 0 ] && grep -q "decode tok/s" "$rep/report.md" && [ -s "$rep/perf-decode.svg" ] && ok "perf suite: decode, prefill and aggregate measured on both targets, charts written" || bad "perf suite: rc=$rc $(echo "$r" | tail -3)"
# verdict.py on performance: a candidate 10 % slower -> NOT READY (slower); 10 % faster with everything green -> READY (faster)
pv=$(mktemp -d); python3 - "$rep" "$pv" <<'PY'
import json, os, sys
src, d = sys.argv[1], sys.argv[2]
R = json.load(open(os.path.join(src, "results.json"))); cand, ctrl = R["meta"]["candidate"], R["meta"]["control"]
base = {"ok": True, "decode_tps": [100.0, 101.0, 99.0], "prefill_tps": [1000.0, 1010.0, 990.0], "batch_tps": [300.0, 303.0, 297.0], "errors": []}
for name, f in (("slow", 0.9), ("fast", 1.1)):
    os.makedirs(f"{d}/{name}", exist_ok=True); X = json.loads(json.dumps(R))
    X["perf"] = {ctrl: [base], cand: [{**base, "decode_tps": [v * f for v in base["decode_tps"]], "prefill_tps": [v * f for v in base["prefill_tps"]], "batch_tps": [v * f for v in base["batch_tps"]]}]}
    json.dump(X, open(f"{d}/{name}/results.json", "w"))
PY
python3 scripts/verdict.py "$pv/slow" > "$pv/o1" 2>&1 && grep -q "NOT READY.*slower than the control" "$pv/o1" && ok "verdict.py: a 10 % slowdown beyond the noise -> NOT READY" || bad "verdict slow: $(cat "$pv/o1")"
python3 scripts/verdict.py "$pv/fast" > "$pv/o2" 2>&1 && grep -q "READY.*faster than the control" "$pv/o2" && ! grep -q "NOT READY" "$pv/o2" && ok "verdict.py: a 10 % speed-up with everything green -> READY" || bad "verdict fast: $(cat "$pv/o2")"
rm -rf "$pv"
# evidence-review.sh: bundle (diff, report, results, suites, run facts) + a fake reviewer -> REVIEW.md next to the run
er=$(mktemp -d); git init -q "$er/co"; echo a > "$er/co/f"; git -C "$er/co" add f; git -C "$er/co" -c user.name=t -c user.email=t@example.com commit -q -m base
echo b > "$er/co/f"; git -C "$er/co" -c user.name=t -c user.email=t@example.com commit -q -am head
printf '#!/bin/sh\necho "tokens used"\necho 1\necho "**NO REGRESSION SHOWN, CLAIM NOT TESTED.** The fake reviewer read the bundle: the report matches results.json, the diff touches f only, no suite exercises it, one repetition in a fixed order."\n' > "$er/rev"; chmod +x "$er/rev"
rep=$(ls -dt /tmp/selftest-runs/2*/ 2>/dev/null | head -1)
REVIEWER="$er/rev" bash scripts/evidence-review.sh "$rep" --checkout "$er/co" --base HEAD~1 --head HEAD --pr-url https://example.invalid/pull/1 > "$er/out.txt" 2>&1
[ -s "$rep/REVIEW.md" ] && grep -q "CLAIM NOT TESTED" "$rep/REVIEW.md" && [ -s "$rep/review/pr.patch" ] && grep -q "^candidate" "$rep/review/run.txt" && grep -qi "read-only" "$rep/review/TASK.md" && [ -f "$rep/review/suites/basic.py" ] && ok "evidence-review.sh: bundle built (diff, report, results, suites, run facts), second opinion extracted" || bad "evidence-review.sh: $(cat "$er/out.txt" | tail -2) $(cat "$rep/review-missing.txt" 2>/dev/null)"
REVIEWER=/bin/false bash scripts/evidence-review.sh "$rep" --checkout "$er/co" --base HEAD~1 --head HEAD > /dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ -s "$rep/review-missing.txt" ] && ok "evidence-review.sh: a reviewer that fails leaves review-missing.txt and exit 0" || bad "evidence-review.sh failure path: rc=$rc"
rm -rf "$er"
# claim-agent.sh with a fake agent: against a base that answers wrongly the claim test is accepted; against a base where
# the claim already holds it is refused after the correction round (does not isolate the change)
nohup python3 tests/fake_server.py 18612 --wrong > /dev/null 2>&1 &
cbad=$!; sleep 0.7
cr=$(ls -dt /tmp/selftest-runs/2*/ 2>/dev/null | head -1)   # the run that evidence-review.sh bundled (review/pr.patch, PR.md)
r=$(AGENT_CMD="bash $PWD/tests/fake-claim-agent.sh" GH_TOKEN=should-not-reach-the-agent LIVE_API=http://127.0.0.1:18612/v1 LIVE_MODEL=fake-model bash scripts/claim-agent.sh "$cr" --pr-url https://example.invalid/pull/1 --out /tmp/selftest-claim.sh 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q "RESULT: claim /tmp/selftest-claim.sh" <<<"$r" && grep -q "CLAIM: does not hold" "$cr/claim/base-run.txt" && [ -x /tmp/selftest-claim.sh ] && ok "claim-agent: claim test written, fails on the base, accepted" || bad "claim-agent accept: rc=$rc $(tail -3 <<<"$r")"
r=$(AGENT_CMD="bash $PWD/tests/fake-claim-agent.sh" LIVE_API=http://127.0.0.1:18611/v1 LIVE_MODEL=fake-model bash scripts/claim-agent.sh "$cr" --pr-url https://example.invalid/pull/1 --out /tmp/selftest-claim2.sh 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q "RESULT: no-claim after two rounds: the claim already holds on the base" <<<"$r" && [ ! -e /tmp/selftest-claim2.sh ] && grep -q "Correction (round 2)" "$cr/claim/TASK.md" && ok "claim-agent: a claim that already holds on the base is refused after one correction round" || bad "claim-agent refuse: rc=$rc $(tail -3 <<<"$r")"
r=$(FAKE_CLAIM=decline AGENT_CMD="bash $PWD/tests/fake-claim-agent.sh" LIVE_API=http://127.0.0.1:18612/v1 LIVE_MODEL=fake-model bash scripts/claim-agent.sh "$cr" --pr-url https://example.invalid/pull/1 --out /tmp/selftest-claim3.sh 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q "RESULT: no-claim declined by the agent: the change is only observable in the server log" <<<"$r" && [ ! -e /tmp/selftest-claim3.sh ] && ok "claim-agent: the agent may decline with NO-CLAIM.md; nothing is accepted" || bad "claim-agent decline: rc=$rc $(tail -2 <<<"$r")"
kill "$cbad" 2>/dev/null; rm -f /tmp/selftest-claim.sh
# verdict.py: a claim test (claims/) that fails on both builds is inconclusive -> SAFE, UNVERIFIED, not NOT READY
vc=$(mktemp -d); python3 - "$cr" "$vc" <<'PY'
import json, os, sys
src, d = sys.argv[1], sys.argv[2]
R = json.load(open(os.path.join(src, "results.json"))); cand, ctrl = R["meta"]["candidate"], R["meta"]["control"]
R["meta"]["opts"]["repro_cmd"] = "bash claim.sh {api} {model}"
R["repro"] = {cand: [{"ok": False, "role": "candidate", "exit": 1, "shows_problem": True, "cmd": "bash claim.sh", "output_tail": "CLAIM: does not hold"}],
              ctrl: [{"ok": True, "role": "control", "exit": 1, "shows_problem": True, "cmd": "bash claim.sh", "output_tail": "CLAIM: does not hold"}]}
json.dump(R, open(os.path.join(d, "results.json"), "w"))
PY
python3 scripts/verdict.py "$vc" > "$vc/o" 2>&1 && grep -q "SAFE, UNVERIFIED.*fails on both builds" "$vc/o" && ok "verdict.py: a claim test failing on both builds is inconclusive (SAFE, UNVERIFIED), not NOT READY" || bad "verdict inconclusive claim: $(cat "$vc/o")"
rm -rf "$vc"
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
