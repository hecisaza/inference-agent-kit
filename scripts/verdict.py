#!/usr/bin/env python3
"""verdict.py RUN_DIR [--review FILE] [--sync FILE --pr N] [--pr-file FILE] [--noise FILE] [--manifest FILE]

Merge readiness of a pairtest run, computed from results.json, the second opinion (REVIEW.md), stage 0's sync output,
the run manifest and the lab's calibrated noise, in four classes:

  READY             every regression check passes, no slowdown beyond the calibrated band, no blocker, the candidate is
                    the pull request integrated with its current base, and the claim is verified by AUDITED evidence:
                    a claim or reproduction script that fails on the base and passes on the candidate AND that the
                    second opinion inspected and found sound (CLAIM TEST: SOUND); or the pull request's own tests that
                    fail on the base and pass on the PR AND that the second opinion inspected and found sound
                    (AUTHOR TESTS: SOUND); or a speed-up the pull request itself claims, measured beyond the band,
                    that the second opinion supports. A second opinion alone never makes READY.
  SAFE, UNVERIFIED  valid regression evidence shows no failure, but the claim is not verified to that standard: the
                    changed path was not exercised, the oracle was not inspected, or the candidate is not integrated
                    with the current base (head on its merge-base).
  NOT READY         a suite failed on the candidate, a reproduction still shows the problem, a script passes on the
                    base and fails on the candidate, the PR's own tests fail on the PR, unexplained reply differences,
                    a slowdown confirmed over two or more repetitions, a current patch-number collision, or a second
                    opinion that contradicts the claim.
  RERUN             the measurement is not trustworthy: restore failed, the control failed a suite, an incomplete
                    matrix, a script that errored, a single-repetition slowdown (rerun counterbalanced), a second
                    opinion of EVIDENCE UNRELIABLE.

A run of a pull request that was closed or merged at execution is a HISTORICAL verdict: it is reported as such and
never presented as current readiness. Writes RUN_DIR/VERDICT.md and RUN_DIR/verdict.json ({class, label, reasons,
facts, historical}) and prints the headline. Exit 0 always: the class is the result. A person merges."""
import argparse, datetime, json, os, re, statistics

HASH = re.compile(r"^[0-9a-f]{12}$")
LABEL = {"READY": "ready", "SAFE, UNVERIFIED": "unverified", "NOT READY": "blocked", "RERUN": "rerun"}
REVIEW_VERDICTS = ["EVIDENCE UNRELIABLE", "EVIDENCE CONTRADICTS THE CLAIM", "EVIDENCE SUPPORTS THE CLAIM", "NO REGRESSION SHOWN, CLAIM NOT TESTED"]
FLOOR = {"decode": 0.03, "prefill": 0.03, "aggregate": 0.05, "cut-in": 0.03, "startup": 0.10, "aggregate@16": 0.05}   # used only without a calibration
ABS_FLOOR = {"cut-in": 0.2, "startup": 10.0}   # seconds: a latency difference smaller than this is never called, whatever the ratio
# the perf suite's metrics pair round by round (the same prompts for both targets within a repetition); each value has a
# key (its round and a hash of its prompt) in these fields from 2026-11-04 on, and is paired by position before that
PAIR_KEYS = {"decode": "decode_keys", "prefill": "prefill_keys", "aggregate": "batch_keys"}
PERF = [("decode", "perf", lambda r: r.get("decode_tps") or [], 1), ("prefill", "perf", lambda r: r.get("prefill_tps") or [], 1),
        ("aggregate", "perf", lambda r: r.get("batch_tps") or [], 1), ("cut-in", "cutin", lambda r: [x.get("short") for x in r.get("rounds", [])], -1),
        ("startup", "startup", lambda r: r.get("seconds_per_start") or [], -1),
        ("aggregate@16", "concurrency", lambda r: [st["aggregate_tps"] for st in r.get("stages", []) if st.get("streams") == 16], 1)]


def last_mention(text, options):
    """The option mentioned last in the text wins: a reviewer quotes the alternatives before concluding."""
    pos = {v: text.rfind(v) for v in options if v in text}
    return max(pos, key=pos.get) if pos else None


def read_review(path):
    """The second opinion's structured lines: the evidence verdict, the claim-test audit, the author-tests audit."""
    if not path or not os.path.isfile(path):
        return None, None, None
    text = open(path, errors="ignore").read().upper()
    rv = last_mention(text, REVIEW_VERDICTS) or "no verdict line"
    ct = last_mention(text, ["CLAIM TEST: SOUND", "CLAIM TEST: UNSOUND", "CLAIM TEST: NONE"])
    at = last_mention(text, ["AUTHOR TESTS: SOUND", "AUTHOR TESTS: UNSOUND", "AUTHOR TESTS: NOT INSPECTED", "AUTHOR TESTS: NONE"])
    return rv, (ct.split(": ")[1] if ct else None), (at.split(": ")[1] if at else None)


def load_noise(path):
    """Calibrated bands per metric ({metric: fraction}) from an unexpired calibration file; None without one."""
    if not path or not os.path.isfile(path):
        return None, "no calibration file: floors apply"
    try:
        n = json.load(open(path))
    except ValueError:
        return None, "calibration file unreadable: floors apply"
    exp = n.get("expires")
    if exp and exp < datetime.date.today().isoformat():
        return None, f"calibration expired on {exp}: floors apply"
    bands = {k: float(v) for k, v in (n.get("bands") or {}).items()}
    return bands, ("provisional calibration" if n.get("provisional") else f"calibration of {n.get('measured', '?')}")


def series(R, suite, target, pick):
    xs = [v for r in R.get(suite, {}).get(target, []) for v in pick(r) if isinstance(v, (int, float))]
    if not xs:
        return None, 0
    return statistics.median(xs), len(xs)


def paired(R, name, suite, cand, ctrl, pick, sign):
    """The candidate against the control round by round, for the perf suite's metrics: within a repetition both targets
    get the same prompts in the same order, so each round of one is compared with the same round of the other, and the
    median of those ratios is the difference. A speed that depends on the prompt (speculative decoding's acceptance
    does) then cancels out, where a median over each side's pooled rounds can move by a percent or two with one round.
    Rounds pair by their recorded key (round and prompt hash) when both sides have one, else by position (results from
    before keys were recorded). Returns (difference, pairs, how, unpaired) or None for a metric that does not pair."""
    keyf = PAIR_KEYS.get(name)
    rc, rk = R.get(suite, {}).get(cand, []), R.get(suite, {}).get(ctrl, [])
    if not keyf or not rc or len(rc) != len(rk):
        return None
    diffs, unpaired, how = [], 0, "by prompt"
    for i, (a, b) in enumerate(zip(rc, rk)):
        xs, ys = pick(a), pick(b)
        ka, kb = a.get(keyf), b.get(keyf)
        if ka is not None and kb is not None and len(ka) == len(xs) and len(kb) == len(ys):
            va, vb = dict(zip(ka, xs)), dict(zip(kb, ys))
            both = [k for k in va if k in vb]
            unpaired += len(va) + len(vb) - 2 * len(both)
            pairs = [(va[k], vb[k]) for k in both]
        else:
            how = "by position"
            if len(xs) != len(ys):
                return None
            pairs = list(zip(xs, ys))
        diffs += [sign * (x - y) / y for x, y in pairs if isinstance(x, (int, float)) and isinstance(y, (int, float)) and x > 0 and y > 0]
    return (statistics.median(diffs), len(diffs), how, unpaired) if diffs else None


def performance(R, cand, ctrl, bands):
    """Candidate against control per metric: + is better (throughput up, latency and startup down). The difference is
    the median of the round-by-round ratios when the rounds pair (``paired``), else the ratio of each side's median. It
    counts only beyond the metric's calibrated band (or its floor without a calibration). Neither side's own scatter
    widens the band. A metric with a single sample on either side is reported, never called."""
    out = []
    for name, suite, pick, sign in PERF:
        c, nc = series(R, suite, cand, pick); k, nk = series(R, suite, ctrl, pick)
        if c is None or k is None or not k:
            continue
        band = (bands or {}).get(name, FLOOR[name])
        pr = paired(R, name, suite, cand, ctrl, pick, sign)
        delta = pr[0] if pr and pr[1] >= 2 else sign * (c - k) / k
        call = "slower" if delta < -band else ("faster" if delta > band else "same"); single = min(nc, nk) < 2
        tiny = abs(c - k) < ABS_FLOOR.get(name, 0.0)   # a latency difference below the absolute floor is noise at any ratio
        out.append({"metric": name, "delta": delta, "band": band, "candidate": c, "control": k, "call": "same" if (single or tiny) else call, "single": single, "tiny": tiny,
                    "paired": bool(pr and pr[1] >= 2), "how": (f"paired {pr[2]}, {pr[1]} rounds" + (f", {pr[3]} unpaired" if pr[3] else "")) if pr and pr[1] >= 2 else "medians",
                    "pooled": sign * (c - k) / k})
    return out


def admission(R, cand, ctrl):
    """The cut-in suite's admission flag per target: whether the short request's first token came before the long
    prompt's first token in every round (None without the flag, which older results lack)."""
    def flag(t):
        rounds = [x for r in R.get("cutin", {}).get(t, []) for x in r.get("rounds", [])]
        if not rounds or any("admitted" not in x for x in rounds):
            return None
        return all(x.get("admitted") for x in rounds)
    return flag(cand), flag(ctrl)


def collisions(path, pr):
    if not path or not pr or not os.path.isfile(path):
        return []
    return [l.strip() for l in open(path, errors="ignore") if l.startswith("COLLISION:") and re.search(rf"#{pr}\b", l)]


def main():
    ap = argparse.ArgumentParser(usage=__doc__)
    ap.add_argument("run"); ap.add_argument("--review"); ap.add_argument("--sync"); ap.add_argument("--pr"); ap.add_argument("--label-prefix", default="evidence:")
    ap.add_argument("--pr-file", help="the PR's title and description: a measured speed-up counts only when the PR claims performance")
    ap.add_argument("--noise", help="lab.noise.json: calibrated bands per metric (scripts/calibrate.py)")
    ap.add_argument("--manifest", help="run-manifest.json: the PR's state at execution, the candidate kind, the shas")
    a = ap.parse_args(); run = a.run.rstrip("/")
    R = json.load(open(os.path.join(run, "results.json"))); meta = R.pop("meta", {}) or {}
    cand, ctrl = meta.get("candidate"), meta.get("control")
    suites = [s for s in R if s != "meta"]
    man = {}
    for mp in ([a.manifest] if a.manifest else []) + [os.path.join(run, "run-manifest.json")]:
        if mp and os.path.isfile(mp):
            try:
                man = json.load(open(mp)); break
            except ValueError:
                pass
    facts, blockers, rerun = [], [], []

    def failed(target, skip=()):
        return [s for s in suites if s not in skip and any(not r.get("ok") and not r.get("skipped") for r in R[s].get(target, []))]

    cand_fail = failed(cand, skip=("repro",)) if cand else []
    ctrl_fail = failed(ctrl, skip=("repro",)) if ctrl else []
    reps_n = int(meta.get("opts", {}).get("reps", 1) or 1)
    incomplete = []
    for s_ in meta.get("suites", []) or suites:
        for t_ in [x for x in (cand, ctrl) if x]:
            n = len(R.get(s_, {}).get(t_, []))
            if n < reps_n:
                incomplete.append(f"{s_} on {t_}: {n} of {reps_n} repetition(s)")
    marks = " · ".join(f"{s} {'✗' if s in cand_fail else '✓'}" for s in suites if s != "repro") or "(no suites)"
    facts.append(f"suites on `{cand}`: {marks}")

    # ---- replies
    same = total = 0; prompt_sets_differ = False
    if "boundary" in R and cand in R["boundary"] and ctrl in R["boundary"]:
        for ra, rb in zip(R["boundary"][cand], R["boundary"][ctrl]):
            ha, hb = ra.get("hashes", []), rb.get("hashes", [])
            if [x[0] for x in ha] != [x[0] for x in hb]:
                prompt_sets_differ = True; continue
            for x, y in zip(ha, hb):
                total += 1; same += bool(HASH.match(str(x[2]))) and x[2] == y[2]
        facts.append(f"replies: {same}/{total} identical to the control" + (" (a repetition compared different prompt sets and was discarded)" if prompt_sets_differ else ""))
        if total == 0 and not prompt_sets_differ:
            incomplete.append("boundary: no reply comparison was made")
    identical = total == 0 or same == total

    # ---- claim / repro script, typed outcomes over every repetition
    repro = None; repro_error = False
    kind = "claim" if "claim.sh" in str(meta.get("opts", {}).get("repro_cmd", "")) else "repro"
    if "repro" in R and cand in R["repro"]:
        def outcome(r): return r.get("outcome") or ("fails" if r.get("shows_problem") else "passes")  # noqa: E306
        cs = [r for r in R["repro"][cand] if not r.get("skipped")]; ks = [r for r in R["repro"].get(ctrl, []) if not r.get("skipped")]
        co, ko = [outcome(r) for r in cs], [outcome(r) for r in ks]
        if not cs:
            repro = None
        elif "error" in co or "error" in ko:
            repro = "inconclusive"; repro_error = True
        elif all(o == "passes" for o in co):
            repro = "confirmed" if (not ks or all(o == "fails" for o in ko)) else "not reproduced on the base"
        elif any(o == "passes" for o in ko):
            repro = "regression"
        elif kind == "claim":
            repro = "inconclusive"
        else:
            repro = "still present"
        facts.append(f"{kind} script: {repro}" + (f" ({len(cs)} repetition(s))" if repro else "") if repro else f"{kind} script: skipped")

    # ---- performance against the calibrated bands
    bands, band_note = load_noise(a.noise)
    perf = performance(R, cand, ctrl, bands) if cand and ctrl else []
    slow = [x for x in perf if x["call"] == "slower"]; fast = [x for x in perf if x["call"] == "faster"]
    if perf:
        def perf_note(x):
            n = f"{x['metric']} {x['delta']:+.1%} (±{x['band']:.0%}, {x['how']}"
            if x["call"] != "same": n += f", {x['call']}"
            if x.get("single"): n += ", one sample a side: not called"
            elif x.get("tiny") and abs(x["delta"]) > x["band"]: n += f", {abs(x['candidate'] - x['control']):.2f} s apart, below the {ABS_FLOOR[x['metric']]:g} s floor: not called"
            return n + ")"
        facts.append(f"performance against the control ({band_note}): " + " · ".join(perf_note(x) for x in perf))
    # endurance: a candidate whose throughput drifts down over hours beyond the control's drift, or whose memory grows past the
    # control's by more than 512 MB over the run, is blocked; a canary reply that changes mid-run is a failure of its own
    if "endurance" in R and cand in R["endurance"] and ctrl in R["endurance"]:
        def drift(t, key): return min([(r.get("drift") or {}).get(key) for r in R["endurance"].get(t, []) if (r.get("drift") or {}).get(key) is not None] or [0.0])  # noqa: E306
        def growth(t): return max([m.get("growth_mb", 0) for r in R["endurance"].get(t, []) for m in (r.get("memory") or {}).values()] or [0])  # noqa: E306
        def slope(t): return max([m.get("late_slope_mb_per_hour", 0) for r in R["endurance"].get(t, []) for m in (r.get("memory") or {}).values()] or [0])  # noqa: E306
        def canary(t): return sum(r.get("canary_bad", 0) for r in R["endurance"].get(t, []))  # noqa: E306
        wc, wk, gc, gk = drift(cand, "worst_decode_pct"), drift(ctrl, "worst_decode_pct"), growth(cand), growth(ctrl)
        mins = max([r.get("minutes", 0) for r in R["endurance"].get(cand, [])] or [0])
        facts.append(f"endurance ({mins} min under load): worst decode probe against the first, candidate {wc:+}% / control {wk:+}%; memory growth over the run candidate {gc:+} MB / control {gk:+} MB, second-half slope candidate {slope(cand):+} / control {slope(ctrl):+} MB per hour; canary mismatches candidate {canary(cand)}, control {canary(ctrl)}")
        if wc < wk - 10:
            blockers.append(f"throughput drifts down over time on the candidate (worst decode probe {wc:+}% against the first, control {wk:+}%)")
        if gc > gk + 512:
            blockers.append(f"host memory grows over the run on the candidate ({gc:+} MB) beyond the control ({gk:+} MB)")
        if canary(cand) and not canary(ctrl):
            blockers.append(f"a canary reply changed mid-run on the candidate ({canary(cand)} probes)")
    # sustained concurrency: batched replies must match serial ones; host memory after a drain must not grow more than on the control
    conc_block = []
    if "concurrency" in R and cand in R["concurrency"]:
        def det(t): return sum((r.get("determinism") or {}).get("mismatch", 0) for r in R["concurrency"].get(t, []))  # noqa: E306
        def growth(t): return max([m.get("growth_mb", 0) for r in R["concurrency"].get(t, []) for m in (r.get("memory") or {}).values()] or [0])  # noqa: E306
        mc, mk = det(cand), det(ctrl) if ctrl else 0
        gc, gk = growth(cand), growth(ctrl) if ctrl else 0
        facts.append(f"concurrency: batched-vs-serial mismatches candidate {mc}, control {mk}; largest host memory growth after a drain candidate {gc:+} MB, control {gk:+} MB")
        if mc and not mk:
            conc_block.append(f"batched replies differ from serial replies on the candidate ({mc}) and not on the control")
        if gc - gk > 512:
            conc_block.append(f"host memory grows on the candidate after a drain ({gc:+} MB) beyond the control ({gk:+} MB)")
    adm_c, adm_k = admission(R, cand, ctrl)
    if adm_c is not None:
        facts.append("cut-in admission (short request answered before the long prompt's first token): " + f"candidate {'yes' if adm_c else 'no'}, control {'yes' if adm_k else 'no'}")
    perf_claim = bool(a.pr_file and os.path.isfile(a.pr_file) and re.search(r"faster|slower|throughput|latenc|tok/s|tokens/s|speed|perf|load time|startup|start time", open(a.pr_file, errors="ignore").read(), re.I))

    # ---- the pull request's own tests
    ht = None
    hp = os.path.join(run, "hosttests.json")
    if os.path.isfile(hp):
        try:
            ht = json.load(open(hp))
        except ValueError:
            ht = None
    if ht:
        c_, k_ = ht.get("candidate") or {}, ht.get("control") or {}
        facts.append(f"the PR's own tests: {ht.get('verdict')}" + (f" ({len(ht.get('files', []))} file(s): on the PR {c_.get('outcome')}, on the base with the PR's tests {k_.get('outcome')})" if ht.get("files") else ""))

    # ---- the second opinion, the collisions, the restore, the manifest
    rv, claim_audit, author_audit = read_review(a.review)
    facts.append(f"second opinion: {rv or 'none'}" + (f"; claim test: {claim_audit}" if claim_audit else "") + (f"; author tests: {author_audit}" if author_audit else ""))
    col = collisions(a.sync, a.pr)
    facts.append("patch numbers: " + ("; ".join(col) if col else "no collision with another open pull request"))
    restore = meta.get("restore") or "not recorded"
    facts.append(f"restore: {restore}")
    pr_state = (man.get("pr_state") or "unknown").lower()
    cand_kind = man.get("candidate_kind") or "unknown"
    integrated = cand_kind.startswith("merged onto") or cand_kind == "unknown"
    historical = pr_state in ("closed", "merged")
    if man:
        facts.append(f"run manifest: PR {pr_state} at execution; candidate {cand_kind}; head {str(man.get('head_sha', ''))[:8]}, base {str(man.get('base_sha', ''))[:8]}" + (f"; engine switches: {man['switches']}" if man.get("switches") else ""))

    # ---- blockers
    if cand_fail:
        blockers.append(f"{', '.join(cand_fail)} failed on the candidate")
    if repro == "still present":
        blockers.append("the reproduction script still shows the problem on the candidate")
    if repro == "regression":
        blockers.append(f"the {kind} script passes on the base and fails on the candidate")
    if ht and ht.get("verdict") == "fails on the PR":
        blockers.append("the pull request's own tests fail on the pull request")
    if col:
        blockers.append("a patch number collides with another open pull request")
    if slow and reps_n >= 2:
        blockers.append("slower than the control over counterbalanced repetitions: " + ", ".join(f"{x['metric']} {x['delta']:+.0%} (band ±{x['band']:.0%})" for x in slow))
    if adm_c is not None and adm_k and not adm_c:
        blockers.append("cut-in admission regressed: the control admits the short request during the long prefill, the candidate does not")
    blockers.extend(conc_block)
    if rv == "EVIDENCE CONTRADICTS THE CLAIM":
        blockers.append("the second opinion contradicts the claim")
    if not identical and rv != "EVIDENCE SUPPORTS THE CLAIM":
        blockers.append(f"{total - same} of {total} replies differ from the control and the second opinion does not confirm that as the claim")
    # ---- rerun conditions
    if str(restore).startswith("RESTORE FAILED"):
        rerun.append("the restore of the live configuration failed")
    if ctrl_fail:
        rerun.append(f"the control failed {', '.join(ctrl_fail)}: the base or the lab was not healthy")
    if incomplete:
        rerun.append("incomplete run: " + "; ".join(incomplete))
    if prompt_sets_differ and total == 0:
        rerun.append("the boundary suite compared different prompt sets on the two targets")
    if repro_error:
        rerun.append(f"the {kind} script errored on a build (exit other than 0 or 1): it judged nothing")
    if slow and reps_n < 2:
        rerun.append("a slowdown in a single repetition is timing uncertainty, not a defect: rerun counterbalanced (reps=2): " + ", ".join(f"{x['metric']} {x['delta']:+.0%} (band ±{x['band']:.0%})" for x in slow))
    measurement_green = not cand_fail and not ctrl_fail and not incomplete and not str(restore).startswith("RESTORE FAILED") and not prompt_sets_differ
    if rv == "EVIDENCE UNRELIABLE" and not (measurement_green and claim_audit == "UNSOUND"):
        rerun.append("the second opinion finds the evidence unreliable")
    elif rv == "EVIDENCE UNRELIABLE":
        not_verified_extra = "the second opinion finds the claim verification unreliable (claim test unsound) while the regression evidence is complete and green"

    # ---- the class
    try:
        not_verified_extra
    except NameError:
        not_verified_extra = ""
    verified = []
    if repro == "confirmed" and claim_audit == "SOUND":
        verified.append(f"the {kind} script fails on the base and passes on the candidate, and the second opinion found its oracle sound")
    if ht and ht.get("verdict") == "confirmed" and author_audit == "SOUND":
        verified.append("the pull request's own tests fail on the base and pass on the pull request, and the second opinion inspected them and found them sound")
    if fast and perf_claim and rv == "EVIDENCE SUPPORTS THE CLAIM":
        verified.append("the speed-up the pull request claims was measured beyond the band and the second opinion supports it: " + ", ".join(f"{x['metric']} {x['delta']:+.0%}" for x in fast))
    not_verified = []
    if repro == "confirmed" and claim_audit != "SOUND":
        not_verified.append(f"the {kind} script fails on the base and passes on the candidate, but its oracle was not inspected (second opinion: {claim_audit or 'no CLAIM TEST line'})")
    if ht and ht.get("verdict") == "confirmed" and author_audit != "SOUND":
        not_verified.append(f"the pull request's own tests pass on the PR and fail on the base: tested by the author, oracle not independently inspected (second opinion: {author_audit or 'no AUTHOR TESTS line'})")
    if rv == "EVIDENCE SUPPORTS THE CLAIM" and not verified:
        not_verified.append("the second opinion supports the claim, which audits the evidence but does not replace a test")
    if fast and not perf_claim:
        not_verified.append("faster than the control (" + ", ".join(f"{x['metric']} {x['delta']:+.0%}" for x in fast) + "), noted but not counted: the PR does not claim performance")
    if repro == "inconclusive" and not repro_error:
        not_verified.append("the claim test fails on both builds: it observes nothing (not evidence against the pull request)")
    if repro == "not reproduced on the base":
        not_verified.append(f"the {kind} script passes on the base too, so it does not isolate the change")
    if not_verified_extra:
        not_verified.append(not_verified_extra)
    if not integrated and cand_kind != "unknown":
        not_verified.append("the pull request does not merge cleanly onto its current base: tested as the head on its merge-base; a rebase is needed before current readiness can be judged")

    timing_only = bool(rerun) and all(r.startswith("a slowdown in a single repetition") for r in rerun)
    if rerun and not (blockers and timing_only):
        cls = "RERUN"; reasons = rerun + (["also observed: " + "; ".join(blockers)] if blockers else [])
    elif blockers:   # a definite failure stands even when a single-repetition slowdown asks for a rerun
        cls = "NOT READY"; reasons = blockers + (["also: " + "; ".join(rerun)] if rerun else [])
    elif verified and integrated:
        cls = "READY"; reasons = ["every suite green, no slowdown beyond the band; " + "; ".join(verified)]
    else:
        cls = "SAFE, UNVERIFIED"
        why = not_verified or ["the changed path was not exercised by any suite" + (" (second opinion: claim not tested)" if rv and "NOT TESTED" in rv else "")]
        if verified and not integrated:
            why = ["the claim is verified (" + "; ".join(verified) + "), but the candidate is the head on its merge-base, not the pull request integrated with the current base: not current readiness"]
        reasons = ["no regression, no slowdown beyond the band; " + "; ".join(why)]
    label = a.label_prefix + ("historical" if historical else LABEL[cls])
    head = f"**Merge readiness: {'HISTORICAL — ' if historical else ''}{cls}** — {'; '.join(reasons)}." + (f" (The pull request was {pr_state} when this ran; this is a record, not current readiness.)" if historical else "")
    md = [head, ""] + [f"- {f}" for f in facts] + ["", "_A person merges. READY: audited evidence verifies the claim. SAFE, UNVERIFIED: nothing broke, the claim is not verified to that standard. NOT READY: something failed or is unexplained. RERUN: the measurement is not trustworthy._"]
    open(os.path.join(run, "VERDICT.md"), "w").write("\n".join(md) + "\n")
    json.dump({"class": cls, "label": label, "historical": historical, "reasons": reasons, "facts": facts, "verified": verified, "not_verified": not_verified}, open(os.path.join(run, "verdict.json"), "w"), indent=1)
    print(head); print(f"label {label}")


if __name__ == "__main__":
    main()
