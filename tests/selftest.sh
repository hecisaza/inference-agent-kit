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
rep=$(ls -dt /tmp/selftest-runs/2*/ 2>/dev/null | head -1); full_run=$rep
[ "$rc" = 0 ] && grep -qE "\*\*19 of 19\*\*" "$rep/report.md" 2>/dev/null && ok "pairtest run (command backend, two local fake servers): exit 0, 19 of 19 hashes identical" || bad "pairtest run: rc=$rc $(echo "$r" | tail -4)"
awk '/stop on here: pkill -f .fake_server.py 1861\[1\]/{s=NR} /start on here: nohup python3 .*18612/{if(!t)t=NR} END{exit !(s && t && s < t)}' "$rep/log.txt" && ok "the first target stops the live configuration before it starts" || bad "live was not stopped before the first target: $(grep -nE 'stop on|start on' "$rep/log.txt" | head -4)"
grep -q "candidate" "$rep/report.md" && grep -q "Restore: live kept running (the last target, a, is the live configuration; verified up)" "$rep/report.md" && [ -s "$rep/report.html" ] && grep -q "does not show" "$rep/report.md" && ok "report.py: candidate/control from meta, live kept running when the control is live, limits list, html written" || bad "report.py output incomplete"
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
printf '**EVIDENCE SUPPORTS THE CLAIM** — the fake reviewer agrees.\nCLAIM TEST: SOUND — it asserts the behaviour and keeps a control.\n' > "$vd/REVIEW.md"
python3 scripts/verdict.py "$good" --review "$vd/REVIEW.md" > "$vd/o1" 2>&1 && grep -q "Merge readiness: READY" "$vd/o1" && grep -q '"label": "evidence:ready"' "$good/verdict.json" && ok "verdict.py: repro confirmed + the second opinion found the oracle sound -> READY" || bad "verdict READY: $(cat "$vd/o1")"
printf '**EVIDENCE SUPPORTS THE CLAIM** — the fake reviewer agrees but did not look at the script.\n' > "$vd/REVIEW-nosound.md"
python3 scripts/verdict.py "$good" --review "$vd/REVIEW-nosound.md" > "$vd/o1b" 2>&1 && grep -q "SAFE, UNVERIFIED.*oracle was not inspected" "$vd/o1b" && ok "verdict.py: repro confirmed without an inspected oracle -> SAFE, UNVERIFIED (a second opinion alone never makes READY)" || bad "verdict uninspected oracle: $(cat "$vd/o1b")"
python3 scripts/verdict.py "$inv" > "$vd/o2" 2>&1 && grep -q "Merge readiness: NOT READY.*passes on the base and fails on the candidate" "$vd/o2" && ok "verdict.py: the candidate fails where the base passes -> NOT READY (regression)" || bad "verdict NOT READY: $(cat "$vd/o2")"
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
# endurance suite against the fake servers: probes, drift and the report section; the verdict's endurance rules on fabricated drift
r=$(python3 scripts/pairtest run --lab tests/lab-fake.yaml --target a --compare b --suite endurance --opt endurance_minutes=0.12 --opt endurance_probe_minutes=0.05 --opt endurance_workers=2 --runs /tmp/selftest-runs 2>&1); rc=$?
rep=$(ls -dt /tmp/selftest-runs/*/ | head -1)
[ "$rc" = 0 ] && python3 -c "
import json, sys; R = json.load(open('$rep/results.json')); e = R['endurance']
for t in ('a', 'b'):
    r = e[t][0]; assert len(r['probes']) >= 2, r['probes']; assert r['drift']['decode_pct'] is not None, r['drift']; assert r['canary_bad'] == 0
" && grep -q "probe (minute)" "$rep/report.md" && grep -q "drift of the last probe against the first" "$rep/report.md" && grep -q "Endurance: one-stream decode" "$rep/endurance.svg" && ok "endurance suite: probes at intervals under load, drift computed, canary stable, report section and chart" || bad "endurance suite: rc=$rc $(tail -2 <<<"$r") $(python3 -c "import json; R=json.load(open('$rep/results.json'))['endurance']; print({t: (r[0]['errors'][:2], r[0]['drift']) for t, r in R.items()})" 2>&1 | cut -c1-400)"
ve=$(mktemp -d); mkdir -p "$ve/r"; python3 - "$ve/r" <<'PY'
import json, sys, os
d = sys.argv[1]
def run(worst, growth, canary): return {"ok": True, "minutes": 120, "probes": [{"minute": 0, "decode_tps": 58.0}, {"minute": 120, "decode_tps": 58.0 * (1 + worst / 100)}],
                                        "drift": {"decode_pct": worst, "prefill_pct": 0.0, "aggregate_pct": 0.0, "worst_decode_pct": worst, "worst_at_minute": 120}, "memory": {"h": {"first_mb": 3000, "last_mb": 3000 + growth, "growth_mb": growth}}, "canary_bad": canary, "load": {}, "errors": []}
R = {"meta": {"candidate": "pr", "control": "base", "targets_order": ["pr", "base"], "suites": ["smoke", "endurance"], "targets": {"pr": {"artifact_id": "x"}, "base": {"artifact_id": "y"}}, "restore": "live restored (verified: API answers, running artifact is live's)"},
     "smoke": {"pr": [{"ok": True}], "base": [{"ok": True}]}, "endurance": {"pr": [run(-25.0, 900, 0)], "base": [run(-2.0, 20, 0)]}}
json.dump(R, open(os.path.join(d, "results.json"), "w"))
PY
python3 scripts/verdict.py "$ve/r" > "$ve/o" 2>&1 && grep -q "NOT READY" "$ve/o" && grep -q "throughput drifts down over time on the candidate" "$ve/r/VERDICT.md" && grep -q "host memory grows over the run on the candidate" "$ve/r/VERDICT.md" && ok "verdict: endurance drift and memory growth beyond the control block" || bad "verdict endurance: $(cat "$ve/o")"
rm -rf "$ve"
# concurrency suite against the fake servers: stages run, batched replies match serial (the fake is deterministic), no container -> no memory samples
r=$(python3 scripts/pairtest run --lab tests/lab-fake.yaml --target a --compare b --suite concurrency --opt conc_rounds=1 --opt conc_tokens=8 --opt conc_streams=1,4 --runs /tmp/selftest-runs 2>&1); rc=$?
rep=$(ls -dt /tmp/selftest-runs/2*/ 2>/dev/null | head -1)
[ "$rc" = 0 ] && grep -q "batched replies identical to serial in 16 of 16" "$rep/report.md" && grep -q "aggregate tok/s" "$rep/report.md" && ok "concurrency suite: 1 and 4 streams, batched replies identical to serial, report section written" || bad "concurrency suite: rc=$rc $(echo "$r" | tail -3) $(grep -c serial "$rep/report.md" 2>/dev/null)"
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
python3 scripts/verdict.py "$pv/slow" > "$pv/o1" 2>&1 && grep -q "RERUN.*single repetition is timing uncertainty" "$pv/o1" && ok "verdict.py: a 10 % slowdown in a single repetition -> RERUN (counterbalanced)" || bad "verdict slow single: $(cat "$pv/o1")"
python3 - "$pv" <<'PY'
import json, os, sys
d = sys.argv[1]; R = json.load(open(f"{d}/slow/results.json")); R["meta"]["opts"]["reps"] = 2
for s_ in R:
    if s_ == "meta": continue
    for t in R[s_]: R[s_][t] = R[s_][t] * 2   # two repetitions of the same observations
os.makedirs(f"{d}/slow2", exist_ok=True); json.dump(R, open(f"{d}/slow2/results.json", "w"))
PY
python3 scripts/verdict.py "$pv/slow2" > "$pv/o1c" 2>&1 && grep -q "NOT READY.*slower than the control over counterbalanced repetitions" "$pv/o1c" && ok "verdict.py: the same slowdown over two repetitions -> NOT READY" || bad "verdict slow reps2: $(cat "$pv/o1c")"
python3 - "$pv" <<'PY'
import json, os
d = sys_d = os.environ.get("PV") or __import__("sys").argv[1]
R = json.load(open(f"{d}/fast/results.json")); cand, ctrl = R["meta"]["candidate"], R["meta"]["control"]
R["perf"] = {ctrl: [{"ok": True, "decode_tps": [100.0, 101.0, 99.0], "prefill_tps": [1000.0, 1010.0, 990.0], "batch_tps": [300.0, 303.0, 297.0], "errors": []}],
             cand: [{"ok": True, "decode_tps": [100.0, 101.0, 99.0], "prefill_tps": [1000.0, 1010.0, 990.0], "batch_tps": [300.0, 303.0, 297.0], "errors": []}]}
R["startup"] = {ctrl: [{"ok": True, "seconds_per_start": [170.0]}], cand: [{"ok": True, "seconds_per_start": [180.0]}]}   # one sample a side, 6 % slower
os.makedirs(f"{d}/startup", exist_ok=True); json.dump(R, open(f"{d}/startup/results.json", "w"))
PY
python3 scripts/verdict.py "$pv/startup" > "$pv/o5" 2>&1 && ! grep -q "NOT READY" "$pv/o5" && grep -q "startup -6%.*one sample a side: not called" "$pv/startup/VERDICT.md" && ok "verdict.py: a single-sample startup difference is reported, never called" || bad "verdict startup single sample: $(cat "$pv/o5") $(grep startup "$pv/startup/VERDICT.md")"
printf 'Faster prefill\n\nThis change raises prefill throughput.\n' > "$pv/PR-perf.md"; printf 'Docs\n\nA wording fix.\n' > "$pv/PR-docs.md"
printf '**EVIDENCE SUPPORTS THE CLAIM** — the speed-up is there.\n' > "$pv/REVIEW-supports.md"
python3 scripts/verdict.py "$pv/fast" --pr-file "$pv/PR-perf.md" --review "$pv/REVIEW-supports.md" > "$pv/o2" 2>&1 && grep -q "READY.*speed-up the pull request claims was measured" "$pv/o2" && ! grep -q "NOT READY" "$pv/o2" && ok "verdict.py: a claimed speed-up, measured and supported by the second opinion -> READY" || bad "verdict fast: $(cat "$pv/o2")"
python3 scripts/verdict.py "$pv/fast" --pr-file "$pv/PR-perf.md" > "$pv/o2b" 2>&1 && grep -q "SAFE, UNVERIFIED" "$pv/o2b" && ok "verdict.py: a claimed speed-up without a second opinion stays SAFE, UNVERIFIED" || bad "verdict fast/no-review: $(cat "$pv/o2b")"
python3 scripts/verdict.py "$pv/fast" --pr-file "$pv/PR-docs.md" > "$pv/o3" 2>&1 && grep -q "SAFE, UNVERIFIED.*noted but not counted" "$pv/o3" && ok "verdict.py: a speed-up on a PR that does not claim performance is noted, not counted" || bad "verdict fast/no-claim: $(cat "$pv/o3")"
rm -rf "$pv"
# hosttests.sh: a PR that adds a test which needs its fix -> confirmed; a test that passes without the fix -> not isolating; no tests -> no tests
ht=$(mktemp -d); mkdir -p "$ht/base/tests" "$ht/pr/tests"
printf 'import unittest, os\nclass T(unittest.TestCase):\n    def test_fix_present(self):\n        self.assertTrue(os.path.exists(os.path.join(os.path.dirname(__file__), "..", "fix.txt")))\n' > "$ht/pr/tests/test_fix.py"
echo fixed > "$ht/pr/fix.txt"
bash scripts/hosttests.sh --pr "$ht/pr" --base "$ht/base" --out "$ht/ht1.json" > "$ht/o1" 2>&1 && grep -q '"verdict": "confirmed"' "$ht/ht1.json" && grep -q "on the PR: passes" "$ht/o1" && ok "hosttests.sh: the PR's test passes on the PR and fails on the base -> confirmed" || bad "hosttests confirmed: $(cat "$ht/o1")"
printf 'import unittest\nclass T(unittest.TestCase):\n    def test_trivial(self):\n        self.assertEqual(1, 1)\n' > "$ht/pr/tests/test_fix.py"
bash scripts/hosttests.sh --pr "$ht/pr" --base "$ht/base" --out "$ht/ht2.json" > "$ht/o2" 2>&1 && grep -q '"verdict": "not isolating"' "$ht/ht2.json" && ok "hosttests.sh: a test that passes without the change -> not isolating" || bad "hosttests not isolating: $(cat "$ht/o2")"
rm "$ht/pr/tests/test_fix.py"; bash scripts/hosttests.sh --pr "$ht/pr" --base "$ht/base" --out "$ht/ht3.json" > "$ht/o3" 2>&1 && grep -q '"verdict": "no tests"' "$ht/ht3.json" && ok "hosttests.sh: no test file in the PR -> no tests" || bad "hosttests none: $(cat "$ht/o3")"
# verdict.py: a green run plus the PR's own tests confirmed -> READY; startup time appears in the performance facts
cp "$ht/ht1.json" "$full_run/hosttests.json"; python3 scripts/verdict.py "$full_run" > "$ht/o4" 2>&1 && grep -q "SAFE, UNVERIFIED.*tested by the author, oracle not independently inspected" "$ht/o4" && grep -q "startup" "$full_run/VERDICT.md" && ok "verdict.py: the PR's own tests alone -> SAFE (tested by the author); startup among the facts" || bad "verdict hosttests alone: $(cat "$ht/o4")"
printf 'NO REGRESSION SHOWN, CLAIM NOT TESTED\nAUTHOR TESTS: SOUND — they assert the fix and fail on the base for that reason.\n' > "$ht/REVIEW-at.md"
python3 scripts/verdict.py "$full_run" --review "$ht/REVIEW-at.md" > "$ht/o5" 2>&1 && grep -q "READY.*own tests fail on the base and pass on the pull request, and the second opinion inspected them" "$ht/o5" && ok "verdict.py: the PR's own tests, inspected and sound -> READY" || bad "verdict hosttests inspected: $(cat "$ht/o5")"
# manifest: a closed PR is HISTORICAL; a head-on-merge-base candidate is never current READY
printf '{"pr_state": "closed", "candidate_kind": "merged onto the current base", "head_sha": "abcdef12", "base_sha": "12345678"}\n' > "$ht/man-closed.json"
python3 scripts/verdict.py "$full_run" --review "$ht/REVIEW-at.md" --manifest "$ht/man-closed.json" > "$ht/o6" 2>&1 && grep -q "HISTORICAL — READY" "$ht/o6" && grep -q '"label": "evidence:historical"' "$full_run/verdict.json" && ok "verdict.py: a run of a closed PR is HISTORICAL, labelled so" || bad "verdict historical: $(cat "$ht/o6")"
printf '{"pr_state": "open", "candidate_kind": "head against its merge-base 12345678 (no clean merge)", "head_sha": "abcdef12", "base_sha": "12345678"}\n' > "$ht/man-fb.json"
python3 scripts/verdict.py "$full_run" --review "$ht/REVIEW-at.md" --manifest "$ht/man-fb.json" > "$ht/o7" 2>&1 && grep -q "SAFE, UNVERIFIED.*not the pull request integrated with the current base" "$ht/o7" && ok "verdict.py: verified on a merge-base candidate -> SAFE (not current readiness)" || bad "verdict fallback: $(cat "$ht/o7")"
# calibrated bands: with lab.noise.example.json a 2.5 % decode loss over two repetitions blocks; an expired file falls back to floors
python3 - "$pv" "$full_run" <<'PY'
import json, os, sys
pv, src = sys.argv[1], sys.argv[2]; R = json.load(open(os.path.join(src, "results.json"))); cand, ctrl = R["meta"]["candidate"], R["meta"]["control"]
R["meta"]["opts"]["reps"] = 2
base = {"ok": True, "decode_tps": [100.0, 100.5, 99.5], "prefill_tps": [1000.0, 1002.0, 998.0], "batch_tps": [300.0, 301.0, 299.0], "errors": []}
R["perf"] = {ctrl: [base, base], cand: [{**base, "decode_tps": [97.5, 97.6, 97.4]}, {**base, "decode_tps": [97.5, 97.6, 97.4]}]}
for s_ in ("smoke", "boundary"): R[s_] = {t: R[s_][t] * 2 for t in R[s_]}
os.makedirs(f"{pv}/cal", exist_ok=True); json.dump(R, open(f"{pv}/cal/results.json", "w"))
json.dump({"bands": {"decode": 0.02}, "provisional": True, "expires": "2000-01-01"}, open(f"{pv}/expired.json", "w"))
PY
python3 scripts/verdict.py "$pv/cal" --noise lab.noise.example.json > "$pv/o8" 2>&1 && grep -q "NOT READY.*decode -2%" "$pv/o8" && grep -q "provisional calibration" "$pv/cal/VERDICT.md" && ok "verdict.py: a 2.5 % decode loss over two repetitions blocks under the calibrated ±2 % band" || bad "verdict calibrated: $(cat "$pv/o8")"
python3 scripts/verdict.py "$pv/cal" --noise "$pv/expired.json" > "$pv/o9" 2>&1 && ! grep -q "NOT READY" "$pv/o9" && grep -q "calibration expired" "$pv/cal/VERDICT.md" && ok "verdict.py: an expired calibration falls back to the floors and says so" || bad "verdict expired calibration: $(cat "$pv/o9")"
# an "unreliable" second opinion that is really about an unsound claim test, with green regression evidence, is SAFE not RERUN
printf 'NO REGRESSION SHOWN, CLAIM NOT TESTED\nCLAIM TEST: UNSOUND — accepts any first response.\nEVIDENCE UNRELIABLE — for full-claim verification: the oracle permits rejection-only implementations.\n' > "$pv/REVIEW-unrel.md"
python3 scripts/verdict.py "$good" --review "$pv/REVIEW-unrel.md" > "$pv/o13" 2>&1 && grep -q "SAFE, UNVERIFIED.*claim verification unreliable (claim test unsound)" "$pv/o13" && ! grep -q "RERUN" "$pv/o13" && ok "verdict.py: 'unreliable' aimed at an unsound claim test with green regression evidence -> SAFE, not RERUN" || bad "verdict unreliable-claim: $(cat "$pv/o13")"
printf 'EVIDENCE UNRELIABLE — the control failed and the matrix is inconsistent.\n' > "$pv/REVIEW-unrel2.md"
python3 scripts/verdict.py "$good" --review "$pv/REVIEW-unrel2.md" > "$pv/o14" 2>&1 && grep -q "RERUN.*finds the evidence unreliable" "$pv/o14" && ok "verdict.py: 'unreliable' about the measurement -> RERUN" || bad "verdict unreliable-measurement: $(cat "$pv/o14")"
# absolute latency floor: a 17 % cut-in difference that is 0.06 s is noise at any ratio
python3 - "$pv" "$full_run" <<'PY'
import json, os, sys
pv, src = sys.argv[1], sys.argv[2]; R = json.load(open(os.path.join(src, "results.json"))); cand, ctrl = R["meta"]["candidate"], R["meta"]["control"]
R["cutin"] = {ctrl: [{"ok": True, "rounds": [{"short": 0.35, "long": 20.0, "admitted": True}] * 3, "errors": []}], cand: [{"ok": True, "rounds": [{"short": 0.41, "long": 20.1, "admitted": True}] * 3, "errors": []}]}
os.makedirs(f"{pv}/tiny", exist_ok=True); json.dump(R, open(f"{pv}/tiny/results.json", "w"))
PY
python3 scripts/verdict.py "$pv/tiny" --noise lab.noise.example.json > "$pv/o12" 2>&1 && ! grep -qE "RERUN|NOT READY" "$pv/o12" && grep -q "below the 0.2 s floor: not called" "$pv/tiny/VERDICT.md" && ok "verdict.py: a sub-0.2 s cut-in difference is not called whatever the ratio" || bad "verdict tiny latency: $(cat "$pv/o12") $(grep cut-in "$pv/tiny/VERDICT.md")"
# calibrate.py: provisional bands; same-image runs give bands; mixed images are refused
python3 scripts/calibrate.py --out "$pv/noise-prov.json" --provisional decode=0.02 prefill=0.015 --days 7 >/dev/null && grep -q '"provisional": true' "$pv/noise-prov.json" && ok "calibrate.py: provisional bands written with an expiry" || bad "calibrate provisional"
python3 - "$pv" "$full_run" <<'PY'
import json, os, sys
pv, src = sys.argv[1], sys.argv[2]; R = json.load(open(os.path.join(src, "results.json"))); cand, ctrl = R["meta"]["candidate"], R["meta"]["control"]
R["meta"]["targets"][cand]["artifact_id"] = "sameimage0001"; R["meta"]["targets"][ctrl]["artifact_id"] = "sameimage0001"
base = {"ok": True, "decode_tps": [100.0, 101.0, 99.0], "prefill_tps": [1000.0, 1010.0, 990.0], "batch_tps": [300.0, 303.0, 297.0], "errors": []}
R["perf"] = {ctrl: [base], cand: [{**base, "decode_tps": [101.0, 102.0, 100.0]}]}
os.makedirs(f"{pv}/same", exist_ok=True); json.dump(R, open(f"{pv}/same/results.json", "w"))
R["meta"]["targets"][cand]["artifact_id"] = "otherimage002"; os.makedirs(f"{pv}/mixed", exist_ok=True); json.dump(R, open(f"{pv}/mixed/results.json", "w"))
PY
python3 scripts/calibrate.py --out "$pv/noise-cal.json" "$pv/same" > "$pv/o10" 2>&1 && grep -q '"provisional": false' "$pv/noise-cal.json" && python3 -c "import json,sys; b=json.load(open(sys.argv[1]))['bands']; assert 0.01 <= b['decode'] <= 0.03, b" "$pv/noise-cal.json" && ok "calibrate.py: bands from a same-image run (decode band from a 1 % observed difference)" || bad "calibrate same-image: $(cat "$pv/o10")"
python3 scripts/calibrate.py --out "$pv/noise-bad.json" "$pv/mixed" > "$pv/o11" 2>&1; [ $? != 0 ] && grep -q "do not share an artifact id" "$pv/o11" && ok "calibrate.py: a mixed-image run is refused" || bad "calibrate mixed: $(cat "$pv/o11")"
rm -f "$full_run/hosttests.json"; rm -rf "$ht"
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
rm -f /tmp/selftest-claim.sh /tmp/selftest-claim2.sh /tmp/selftest-claim3.sh
nohup python3 tests/fake_server.py 18612 --wrong > /dev/null 2>&1 &
cbad=$!; sleep 0.7
cr=$(ls -dt /tmp/selftest-runs/2*/ 2>/dev/null | head -1)   # the run that evidence-review.sh bundled (review/pr.patch, PR.md)
r=$(AGENT_CMD="bash $PWD/tests/fake-claim-agent.sh" GH_TOKEN=should-not-reach-the-agent LIVE_API=http://127.0.0.1:18612/v1 LIVE_MODEL=fake-model bash scripts/claim-agent.sh "$cr" --pr-url https://example.invalid/pull/1 --out /tmp/selftest-claim.sh 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q "RESULT: claim /tmp/selftest-claim.sh" <<<"$r" && grep -q "CLAIM: does not hold" "$cr/claim/base-run.txt" && [ -x /tmp/selftest-claim.sh ] && ok "claim-agent: claim test written, fails on the base, accepted" || bad "claim-agent accept: rc=$rc $(tail -3 <<<"$r")"
r=$(AGENT_CMD="bash $PWD/tests/fake-claim-agent.sh" LIVE_API=http://127.0.0.1:18611/v1 LIVE_MODEL=fake-model bash scripts/claim-agent.sh "$cr" --pr-url https://example.invalid/pull/1 --out /tmp/selftest-claim2.sh 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q "RESULT: no-claim after two rounds: the claim already holds on the base" <<<"$r" && [ ! -e /tmp/selftest-claim2.sh ] && grep -q "Correction (round 2)" "$cr/claim/TASK.md" && ok "claim-agent: a claim that already holds on the base is refused after one correction round" || bad "claim-agent refuse: rc=$rc result=$(grep -c 'no-claim after two rounds' <<<"$r") out2=$([ -e /tmp/selftest-claim2.sh ] && echo exists || echo absent) correction=$(grep -c 'Correction (round 2)' "$cr/claim/TASK.md" 2>&1 | head -1)"
r=$(FAKE_CLAIM=decline AGENT_CMD="bash $PWD/tests/fake-claim-agent.sh" LIVE_API=http://127.0.0.1:18612/v1 LIVE_MODEL=fake-model bash scripts/claim-agent.sh "$cr" --pr-url https://example.invalid/pull/1 --out /tmp/selftest-claim3.sh 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q "RESULT: no-claim declined by the agent: the change is only observable in the server log" <<<"$r" && [ ! -e /tmp/selftest-claim3.sh ] && ok "claim-agent: the agent may decline with NO-CLAIM.md; nothing is accepted" || bad "claim-agent decline: rc=$rc $(tail -2 <<<"$r")"
kill "$cbad" 2>/dev/null; rm -f /tmp/selftest-claim.sh /tmp/selftest-claim2.sh /tmp/selftest-claim3.sh
# verdict.py: a missing control result is an incomplete run -> RERUN, and a blocker seen on the candidate is kept in the reasons
vi=$(mktemp -d); python3 - "$full_run" "$vi" <<'PY'
import json, os, sys
src, d = sys.argv[1], sys.argv[2]
R = json.load(open(os.path.join(src, "results.json"))); cand, ctrl = R["meta"]["candidate"], R["meta"]["control"]
R["meta"]["suites"] = ["smoke", "boundary"]; R["boundary"] = {cand: R["boundary"][cand]}   # the control never ran boundary
R["smoke"][cand][0]["ok"] = False   # and the candidate failed smoke
json.dump(R, open(os.path.join(d, "results.json"), "w"))
PY
python3 scripts/verdict.py "$vi" > "$vi/o" 2>&1 && grep -q "Merge readiness: RERUN.*incomplete run: boundary on a: 0 of 1" "$vi/o" && grep -q "also observed: smoke failed on the candidate" "$vi/o" && ok "verdict.py: an incomplete matrix -> RERUN, blockers kept" || bad "verdict incomplete: $(cat "$vi/o")"
python3 - "$full_run" "$vi" <<'PY'
import json, os, sys
src, d = sys.argv[1], sys.argv[2]
R = json.load(open(os.path.join(src, "results.json"))); cand, ctrl = R["meta"]["candidate"], R["meta"]["control"]
R["meta"]["opts"]["repro_cmd"] = "bash tests/repro-issue-1.sh {api} {model}"
R["repro"] = {cand: [{"ok": True, "role": "candidate", "exit": 0, "outcome": "passes", "shows_problem": False, "cmd": "x", "output_tail": ""}],
              ctrl: [{"ok": False, "role": "control", "exit": 127, "outcome": "error", "shows_problem": False, "cmd": "x", "output_tail": "bash: x: command not found"}]}
json.dump(R, open(os.path.join(d, "results.json"), "w"))
PY
python3 scripts/verdict.py "$vi" > "$vi/o2" 2>&1 && grep -q "RERUN.*errored on a build" "$vi/o2" && grep -q "repro script: inconclusive" "$vi/VERDICT.md" && ok "verdict.py: a repro script that errors on a build -> RERUN (it judged nothing)" || bad "verdict repro error: $(cat "$vi/o2") $(grep script "$vi/VERDICT.md")"
rm -rf "$vi"
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
# triage: lab and feature issues never reach the reproducer; a triage-only run stops after the triage; --no-post keeps the comment as a draft
: > "$ia/gh.log"
r=$(FAKE_TRIAGE_KIND=lab LIVE_API=http://127.0.0.1:18612/v1 iarun https://github.com/o/r/issues/7); rc=$?
[ "$rc" = 0 ] && grep -q "RESULT: needs-lab (comment posted" <<<"$r" && grep -q "issue comment" "$ia/gh.log" && ! grep -q "pr create" "$ia/gh.log" && [ ! -f "$ia/work/o-r-7/REPRO.md" ] && python3 -c "import json; o=json.load(open('$ia/work/o-r-7/outcome.json')); assert o['result']=='needs-lab' and o['triage']['kind']=='lab' and o['agent_verdict'] is None" && ok "issue-agent: triage lab -> needs-lab, comment posted, the reproducer never ran" || bad "issue-agent triage lab: rc=$rc $(tail -3 <<<"$r")"
: > "$ia/gh.log"
r=$(FAKE_TRIAGE_KIND=feature LIVE_API=http://127.0.0.1:18612/v1 iarun https://github.com/o/r/issues/7 --no-post); rc=$?
[ "$rc" = 0 ] && grep -q "RESULT: out-of-scope (draft comment at" <<<"$r" && ! grep -q "issue comment\|pr create" "$ia/gh.log" && grep -q "address\]" "$ia/work/o-r-7/public/log.txt" && ok "issue-agent: triage feature -> out-of-scope; --no-post leaves a draft; public copies are redacted" || bad "issue-agent triage feature: rc=$rc $(tail -3 <<<"$r")"
: > "$ia/gh.log"
r=$(LIVE_API=http://127.0.0.1:18612/v1 iarun https://github.com/o/r/issues/7 --triage-only); rc=$?
[ "$rc" = 0 ] && grep -q "RESULT: triaged (api" <<<"$r" && ! grep -q "issue comment\|pr create" "$ia/gh.log" && [ ! -f "$ia/work/o-r-7/REPRO.md" ] && ok "issue-agent: --triage-only stops after an api triage" || bad "issue-agent triage-only: rc=$rc $(tail -3 <<<"$r")"
# reproduced without a fix: confirmed on live -> reproduced (no PR); not confirmed -> unclear
: > "$ia/gh.log"
r=$(FAKE_AGENT_NOFIX=1 LIVE_API=http://127.0.0.1:18612/v1 iarun https://github.com/o/r/issues/7 --no-post); rc=$?
[ "$rc" = 0 ] && grep -q "RESULT: reproduced (draft comment at" <<<"$r" && ! grep -q "pr create" "$ia/gh.log" && python3 -c "import json; o=json.load(open('$ia/work/o-r-7/outcome.json')); assert o['result']=='reproduced' and o['live_repro_exit']==1 and o['fix_commits']==0 and o['pr_url'] is None" && ok "issue-agent: reproduced without a fix -> confirmed on live, no PR, outcome recorded" || bad "issue-agent no-fix: rc=$rc $(tail -3 <<<"$r")"
r=$(FAKE_AGENT_NOFIX=1 LIVE_API=http://127.0.0.1:18611/v1 iarun https://github.com/o/r/issues/7 --no-post); rc=$?
[ "$rc" = 0 ] && grep -q "RESULT: unclear (draft comment at" <<<"$r" && ok "issue-agent: reproduced without a fix, not confirmed on live -> unclear" || bad "issue-agent no-fix unclear: rc=$rc $(tail -3 <<<"$r")"
# the issue verdict from the outcomes
iv=$(mktemp -d)
python3 scripts/issue-verdict.py "$ia/work/o-r-7" --out "$iv/a" > "$iv/o" 2>&1 && grep -q "Issue outcome: UNCLEAR" "$iv/o" && ok "issue-verdict: unclear outcome -> UNCLEAR" || bad "issue-verdict unclear: $(cat "$iv/o")"
mkdir -p "$iv/b" "$iv/c" "$iv/d"
printf '{"issue_url":"https://github.com/o/r/issues/7","result":"pr","pr_url":"https://github.com/o/r/pull/99","branch":"agent/issue-7","fix_commits":1,"agent_verdict":"reproduced","live_repro_exit":1,"triage":{"kind":"api","why":"w","repro":"r","confidence":"high"}}' > "$iv/b/outcome.json"
printf '{"class":"READY","label":"evidence:ready","reasons":["repro script fails on the base and passes on the candidate; CLAIM TEST: SOUND"],"facts":[]}' > "$iv/b/tv.json"
python3 scripts/issue-verdict.py "$iv/b" --test-verdict "$iv/b/tv.json" > "$iv/o" 2>&1 && grep -q "Issue outcome: FIXED" "$iv/o" && grep -q '"label": "issue:fixed"' "$iv/b/verdict.json" && ok "issue-verdict: PR opened + test READY -> FIXED" || bad "issue-verdict fixed: $(cat "$iv/o")"
python3 scripts/issue-verdict.py "$iv/b" --test-class "NOT READY" --out "$iv/c" > "$iv/o" 2>&1 && grep -q "Issue outcome: FIX FAILS" "$iv/o" && ok "issue-verdict: PR opened + test NOT READY -> FIX FAILS" || bad "issue-verdict fix fails: $(cat "$iv/o")"
python3 scripts/issue-verdict.py "$iv/b" --out "$iv/d" > "$iv/o" 2>&1 && grep -q "Issue outcome: FIX PROPOSED" "$iv/o" && ok "issue-verdict: PR opened, no test verdict yet -> FIX PROPOSED" || bad "issue-verdict proposed: $(cat "$iv/o")"
printf '{"issue_url":"u","result":"needs-lab","triage":{"kind":"lab","why":"needs KV_SHARD=1","repro":"start with KV_SHARD=1","confidence":"medium"}}' > "$iv/d/outcome.json"
python3 scripts/issue-verdict.py "$iv/d" > "$iv/o" 2>&1 && grep -q "Issue outcome: NEEDS THE LAB" "$iv/o" && grep -q "KV_SHARD=1" "$iv/d/VERDICT.md" && ok "issue-verdict: triage lab -> NEEDS THE LAB with the condition" || bad "issue-verdict needs-lab: $(cat "$iv/o")"
printf '{"issue_url":"u","result":"not-reproduced","agent_verdict":"not-reproduced","triage":{"kind":"api","why":"w","repro":"r","confidence":"low"}}' > "$iv/d/outcome.json"
python3 scripts/issue-verdict.py "$iv/d" > "$iv/o" 2>&1 && grep -q "Issue outcome: NOT REPRODUCIBLE HERE" "$iv/o" && ok "issue-verdict: not reproduced -> NOT REPRODUCIBLE HERE" || bad "issue-verdict not-repro: $(cat "$iv/o")"
# the sweep: the fake fork holds evidence for #8 only; #7 would be dispatched
: > "$ia/gh.log"
r=$(FAKE_GH_LOG="$ia/gh.log" PATH="$ia/bin:$PATH" bash scripts/issue-sweep.sh o/r --fork o/f 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q "#7 .*no run" <<<"$r" && grep -q "#8 .*OUT OF SCOPE" <<<"$r" && grep -q "1 issue(s) would be dispatched" <<<"$r" && ! grep -q "workflow run" "$ia/gh.log" && ok "issue-sweep: outcomes from the evidence branches, dispatch list without --dispatch" || bad "issue-sweep: rc=$rc $r"
r=$(FAKE_GH_LOG="$ia/gh.log" PATH="$ia/bin:$PATH" bash scripts/issue-sweep.sh o/r --fork o/f --dispatch --mode triage 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q "workflow run spark-issue.yml -R o/f -f issue=https://github.com/o/r/issues/7 -f mode=triage" "$ia/gh.log" && ! grep -q "issues/8 " "$ia/gh.log" && ok "issue-sweep --dispatch: one dispatch per issue without a run" || bad "issue-sweep dispatch: rc=$rc $r"
rm -rf "$iv"
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
