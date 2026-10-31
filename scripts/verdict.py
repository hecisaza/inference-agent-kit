#!/usr/bin/env python3
"""verdict.py RUN_DIR [--review FILE] [--sync FILE --pr N] [--label-prefix evidence:]

Merge readiness of a pairtest run, computed from results.json, the second opinion (REVIEW.md) and stage 0's sync
output, in four classes:

  READY             every suite green on the candidate; replies identical to the control, or different exactly as the
                    claim says (the second opinion must support the claim for that); no slowdown; the claim exercised
                    and confirmed (the repro suite, a second opinion of EVIDENCE SUPPORTS THE CLAIM, or a measured
                    speed-up beyond the noise); no patch-number collision
  SAFE, UNVERIFIED  no regression shown, but the changed path was not exercised: merging is a code-review decision,
                    not an evidence decision; a claim or repro script from the author would settle it
  NOT READY         a suite failed on the candidate, unexplained reply differences, a slowdown against the control
                    beyond the run's noise, a repro that still shows the problem, a patch number that collides with
                    another open PR, or a second opinion that contradicts
  RERUN             the evidence itself is unreliable: the restore failed, the control failed a suite, or the second
                    opinion says EVIDENCE UNRELIABLE

Writes RUN_DIR/VERDICT.md (for the pull request comment) and RUN_DIR/verdict.json ({class, label, reasons}) and
prints the headline. Exit 0 always: the class is the result, not the exit status. A person merges."""
import argparse, json, os, re, statistics

HASH = re.compile(r"^[0-9a-f]{12}$")
LABEL = {"READY": "ready", "SAFE, UNVERIFIED": "unverified", "NOT READY": "blocked", "RERUN": "rerun"}
REVIEW_VERDICTS = ["EVIDENCE UNRELIABLE", "EVIDENCE CONTRADICTS THE CLAIM", "EVIDENCE SUPPORTS THE CLAIM", "NO REGRESSION SHOWN, CLAIM NOT TESTED"]


def review_verdict(path):
    if not path or not os.path.isfile(path):
        return None
    text = open(path, errors="ignore").read().upper()
    pos = {v: text.rfind(v) for v in REVIEW_VERDICTS if v in text}
    return max(pos, key=pos.get) if pos else "no verdict line"


def series(R, suite, target, pick):
    """Median, relative spread and sample count of a metric over every repetition of a target; (None, None, 0) without data."""
    xs = [v for r in R.get(suite, {}).get(target, []) for v in pick(r) if isinstance(v, (int, float))]
    if not xs:
        return None, None, 0
    m = statistics.median(xs)
    return m, ((max(xs) - min(xs)) / m if len(xs) > 1 and m else 0.0), len(xs)


PERF = [("decode", "perf", lambda r: r.get("decode_tps") or [], 1), ("prefill", "perf", lambda r: r.get("prefill_tps") or [], 1),
        ("aggregate", "perf", lambda r: r.get("batch_tps") or [], 1), ("cut-in", "cutin", lambda r: [x.get("short") for x in r.get("rounds", [])], -1),
        ("startup", "startup", lambda r: r.get("seconds_per_start") or [], -1)]
FLOOR = {"startup": 0.10}   # a model load varies by seconds between starts; the default floor is 3 %


def performance(R, cand, ctrl, floor=0.03):
    """Candidate against control per metric: + is better (throughput up, latency and startup down). A difference counts
    only beyond the noise: the larger of the metric's floor and either side's relative spread over its rounds. A
    metric with a single sample on either side has no measured spread and is reported, never called."""
    out = []
    for name, suite, pick, sign in PERF:
        c, cs, nc = series(R, suite, cand, pick); k, ks, nk = series(R, suite, ctrl, pick)
        if c is None or k is None or not k:
            continue
        f = FLOOR.get(name, floor)
        delta = sign * (c - k) / k; noise = max(f, cs or 0.0, ks or 0.0)
        call = "slower" if delta < -noise else ("faster" if delta > noise else "same")
        if min(nc, nk) < 2:
            call = "same"; single = True
        else:
            single = False
        out.append({"metric": name, "delta": delta, "noise": noise, "candidate": c, "control": k, "call": call, "single": single})
    return out


def collisions(path, pr):
    if not path or not pr or not os.path.isfile(path):
        return []
    return [l.strip() for l in open(path, errors="ignore") if l.startswith("COLLISION:") and re.search(rf"#{pr}\b", l)]


def main():
    ap = argparse.ArgumentParser(usage=__doc__)
    ap.add_argument("run"); ap.add_argument("--review"); ap.add_argument("--sync"); ap.add_argument("--pr"); ap.add_argument("--label-prefix", default="evidence:")
    ap.add_argument("--pr-file", help="the PR's title and description; a measured speed-up counts as the claim only when the PR claims performance")
    a = ap.parse_args(); run = a.run.rstrip("/")
    R = json.load(open(os.path.join(run, "results.json"))); meta = R.pop("meta", {}) or {}
    cand, ctrl = meta.get("candidate"), meta.get("control")
    suites = [s for s in R if s != "meta"]
    reasons, facts = [], []

    def failed(target, skip=()):
        return [s for s in suites if s not in skip and any(not r.get("ok") and not r.get("skipped") for r in R[s].get(target, []))]

    cand_fail = failed(cand, skip=("repro",)) if cand else []
    ctrl_fail = failed(ctrl, skip=("repro",)) if ctrl else []
    # the matrix must be complete: every requested suite, on every target, for every repetition; an absent result is not a pass
    reps_n = int(meta.get("opts", {}).get("reps", 1) or 1)
    incomplete = []
    for s_ in meta.get("suites", []) or suites:
        for t_ in [x for x in (cand, ctrl) if x]:
            n = len(R.get(s_, {}).get(t_, []))
            if n < reps_n:
                incomplete.append(f"{s_} on {t_}: {n} of {reps_n} repetition(s)")
    marks = " · ".join(f"{s} {'✗' if s in cand_fail else '✓'}" for s in suites if s != "repro") or "(no suites)"
    facts.append(f"suites on `{cand}`: {marks}")

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

    repro = None
    kind = "claim" if "claim.sh" in str(meta.get("opts", {}).get("repro_cmd", "")) else "repro"
    if "repro" in R and cand in R["repro"]:
        def outcome(r): return r.get("outcome") or ("fails" if r.get("shows_problem") else "passes")  # noqa: E306  (older results carry no outcome)
        cs = [r for r in R["repro"][cand] if not r.get("skipped")]; ks = [r for r in R["repro"].get(ctrl, []) if not r.get("skipped")]
        co, ko = [outcome(r) for r in cs], [outcome(r) for r in ks]
        if not cs:
            repro = None
        elif "error" in co or "error" in ko:
            repro = "inconclusive"   # the script could not judge on some repetition: not a reproduction, not a pass
        elif all(o == "passes" for o in co):
            repro = "confirmed" if (not ks or all(o == "fails" for o in ko)) else "not reproduced on the base"
        elif any(o == "passes" for o in ko):
            repro = "regression"   # the candidate fails where the base passes
        elif kind == "claim":
            repro = "inconclusive"   # a claim test that fails on both builds observes nothing
        else:
            repro = "still present"
        facts.append(f"{kind} script: {repro}" + (f" ({len(cs)} repetition(s))" if repro else "") if repro else f"{kind} script: skipped")

    perf = performance(R, cand, ctrl) if cand and ctrl else []
    slow = [x for x in perf if x["call"] == "slower"]; fast = [x for x in perf if x["call"] == "faster"]
    if perf:
        facts.append("performance against the control (each with its own noise band): " + " · ".join(f"{x['metric']} {x['delta']:+.0%} (±{x['noise']:.0%}{', ' + x['call'] if x['call'] != 'same' else ''}{', one sample a side: not called' if x.get('single') else ''})" for x in perf))
    perf_claim = bool(a.pr_file and os.path.isfile(a.pr_file) and re.search(r"faster|slower|throughput|latenc|tok/s|tokens/s|speed|perf|load time|startup|start time", open(a.pr_file, errors="ignore").read(), re.I))
    # the pull request's own tests (scripts/hosttests.sh): run on the PR tree and on the base with the PR's test files
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
    rv = review_verdict(a.review)
    facts.append(f"second opinion: {rv or 'none'}")
    col = collisions(a.sync, a.pr)
    facts.append("patch numbers: " + ("; ".join(col) if col else "no collision with another open pull request"))
    restore = meta.get("restore") or "not recorded"
    facts.append(f"restore: {restore}")

    blockers = []
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
    if slow:
        blockers.append("slower than the control: " + ", ".join(f"{x['metric']} {x['delta']:+.0%} (noise ±{x['noise']:.0%})" for x in slow))
    if rv == "EVIDENCE CONTRADICTS THE CLAIM":
        blockers.append("the second opinion contradicts the claim")
    if not identical and rv != "EVIDENCE SUPPORTS THE CLAIM":
        blockers.append(f"{total - same} of {total} replies differ from the control and the second opinion does not confirm that as the claim")
    if str(restore).startswith("RESTORE FAILED"):
        reasons.append("the restore of the live configuration failed")
    if ctrl_fail:
        reasons.append(f"the control failed {', '.join(ctrl_fail)}: the base or the lab was not healthy")
    if incomplete:
        reasons.append("incomplete run: " + "; ".join(incomplete))
    if prompt_sets_differ and total == 0:
        reasons.append("the boundary suite compared different prompt sets on the two targets")
    if rv == "EVIDENCE UNRELIABLE":
        reasons.append("the second opinion finds the evidence unreliable")
    if reasons:
        cls = "RERUN"
        if blockers:
            reasons.append("also observed: " + "; ".join(blockers))
    else:
        reasons = blockers
        if reasons:
            cls = "NOT READY"
        elif repro == "confirmed" or rv == "EVIDENCE SUPPORTS THE CLAIM" or (fast and perf_claim) or (ht and ht.get("verdict") == "confirmed"):
            cls = "READY"
            reasons.append("every suite green, no slowdown" + (", the claim or reproduction script fails on the base and passes on the candidate" if repro == "confirmed" else "")
                           + (", the pull request's own tests fail on the base and pass on the pull request" if ht and ht.get("verdict") == "confirmed" else "")
                           + (", the second opinion supports the claim" if rv == "EVIDENCE SUPPORTS THE CLAIM" else "")
                           + ((", faster than the control as the PR claims: " + ", ".join(f"{x['metric']} {x['delta']:+.0%}" for x in fast)) if fast and perf_claim else ""))
        else:
            cls = "SAFE, UNVERIFIED"
            reasons.append("no regression, no slowdown; " + ((f"the {kind} script errored on a build: inconclusive" if ("error" in (co + ko) if "repro" in R and cand in R["repro"] else False) else "the claim test fails on both builds: it does not observe the change (not evidence against the pull request)") if repro == "inconclusive"
                           else "the claim or reproduction script passes on the base too, so it does not isolate the change" if repro == "not reproduced on the base"
                           else "the changed path was not exercised by any suite" + (" (second opinion: claim not tested)" if rv and "NOT TESTED" in rv else ""))
                           + ((" — faster than the control (" + ", ".join(f"{x['metric']} {x['delta']:+.0%}" for x in fast) + "), noted but not counted: the PR does not claim performance") if fast and not perf_claim else ""))
    label = a.label_prefix + LABEL[cls]
    head = f"**Merge readiness: {cls}** — {'; '.join(reasons)}."
    md = [head, ""] + [f"- {f}" for f in facts] + ["", "_A person merges. READY: the evidence supports the claim. SAFE, UNVERIFIED: nothing broke, but the change itself was not exercised. NOT READY: something failed or is unexplained. RERUN: the measurement is not trustworthy._"]
    open(os.path.join(run, "VERDICT.md"), "w").write("\n".join(md) + "\n")
    json.dump({"class": cls, "label": label, "reasons": reasons, "facts": facts}, open(os.path.join(run, "verdict.json"), "w"), indent=1)
    print(head); print(f"label {label}")


if __name__ == "__main__":
    main()
