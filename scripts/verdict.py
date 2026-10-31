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
    found = [v for v in REVIEW_VERDICTS if v in text]
    return found[0] if found else "no verdict line"


def series(R, suite, target, pick):
    """Median and relative spread of a metric over every repetition of a target; (None, None) without data."""
    xs = [v for r in R.get(suite, {}).get(target, []) for v in pick(r) if isinstance(v, (int, float))]
    if not xs:
        return None, None
    m = statistics.median(xs)
    return m, ((max(xs) - min(xs)) / m if len(xs) > 1 and m else 0.0)


PERF = [("decode", "perf", lambda r: r.get("decode_tps") or [], 1), ("prefill", "perf", lambda r: r.get("prefill_tps") or [], 1),
        ("aggregate", "perf", lambda r: r.get("batch_tps") or [], 1), ("cut-in", "cutin", lambda r: [x.get("short") for x in r.get("rounds", [])], -1)]


def performance(R, cand, ctrl, floor=0.03):
    """Candidate against control per metric: + is better (throughput up, cut-in latency down). A difference counts
    only beyond the noise: the larger of `floor` and either side's relative spread over its rounds."""
    out = []
    for name, suite, pick, sign in PERF:
        c, cs = series(R, suite, cand, pick); k, ks = series(R, suite, ctrl, pick)
        if c is None or k is None or not k:
            continue
        delta = sign * (c - k) / k; noise = max(floor, cs or 0.0, ks or 0.0)
        out.append({"metric": name, "delta": delta, "noise": noise, "candidate": c, "control": k,
                    "call": "slower" if delta < -noise else ("faster" if delta > noise else "same")})
    return out


def collisions(path, pr):
    if not path or not pr or not os.path.isfile(path):
        return []
    return [l.strip() for l in open(path, errors="ignore") if l.startswith("COLLISION:") and re.search(rf"#{pr}\b", l)]


def main():
    ap = argparse.ArgumentParser(usage=__doc__)
    ap.add_argument("run"); ap.add_argument("--review"); ap.add_argument("--sync"); ap.add_argument("--pr"); ap.add_argument("--label-prefix", default="evidence:")
    a = ap.parse_args(); run = a.run.rstrip("/")
    R = json.load(open(os.path.join(run, "results.json"))); meta = R.pop("meta", {}) or {}
    cand, ctrl = meta.get("candidate"), meta.get("control")
    suites = [s for s in R if s != "meta"]
    reasons, facts = [], []

    def failed(target, skip=()):
        return [s for s in suites if s not in skip and any(not r.get("ok") and not r.get("skipped") for r in R[s].get(target, []))]

    cand_fail = failed(cand, skip=("repro",)) if cand else []
    ctrl_fail = failed(ctrl, skip=("repro",)) if ctrl else []
    marks = " · ".join(f"{s} {'✗' if s in cand_fail else '✓'}" for s in suites if s != "repro") or "(no suites)"
    facts.append(f"suites on `{cand}`: {marks}")

    same = total = 0
    if "boundary" in R and cand in R["boundary"] and ctrl in R["boundary"]:
        for ra, rb in zip(R["boundary"][cand], R["boundary"][ctrl]):
            for x, y in zip(ra.get("hashes", []), rb.get("hashes", [])):
                total += 1; same += bool(HASH.match(str(x[2]))) and x[2] == y[2]
        facts.append(f"replies: {same}/{total} identical to the control")
    identical = total == 0 or same == total

    repro = None
    if "repro" in R and cand in R["repro"]:
        c = R["repro"][cand][0]; k = (R["repro"].get(ctrl) or [None])[0]
        if c.get("skipped"):
            repro = None
        elif c.get("shows_problem"):
            repro = "still present"
        elif k is not None and not k.get("shows_problem"):
            repro = "not reproduced on the base"
        else:
            repro = "confirmed"
        facts.append(f"repro script: {repro}" if repro else "repro script: skipped")

    perf = performance(R, cand, ctrl) if cand and ctrl else []
    slow = [x for x in perf if x["call"] == "slower"]; fast = [x for x in perf if x["call"] == "faster"]
    if perf:
        facts.append("performance against the control: " + " · ".join(f"{x['metric']} {x['delta']:+.0%}" + (f" ({x['call']})" if x["call"] != "same" else "") for x in perf)
                     + f" (noise ±{max(x['noise'] for x in perf):.0%})")
    rv = review_verdict(a.review)
    facts.append(f"second opinion: {rv or 'none'}")
    col = collisions(a.sync, a.pr)
    facts.append("patch numbers: " + ("; ".join(col) if col else "no collision with another open pull request"))
    restore = meta.get("restore") or "not recorded"
    facts.append(f"restore: {restore}")

    if str(restore).startswith("RESTORE FAILED"):
        reasons.append("the restore of the live configuration failed")
    if ctrl_fail:
        reasons.append(f"the control failed {', '.join(ctrl_fail)}: the base or the lab was not healthy")
    if rv == "EVIDENCE UNRELIABLE":
        reasons.append("the second opinion finds the evidence unreliable")
    if reasons:
        cls = "RERUN"
    else:
        if cand_fail:
            reasons.append(f"{', '.join(cand_fail)} failed on the candidate")
        if repro == "still present":
            reasons.append("the reproduction script still shows the problem on the candidate")
        if col:
            reasons.append("a patch number collides with another open pull request")
        if slow:
            reasons.append("slower than the control: " + ", ".join(f"{x['metric']} {x['delta']:+.0%} (noise ±{x['noise']:.0%})" for x in slow))
        if rv == "EVIDENCE CONTRADICTS THE CLAIM":
            reasons.append("the second opinion contradicts the claim")
        if not identical and rv != "EVIDENCE SUPPORTS THE CLAIM":
            reasons.append(f"{total - same} of {total} replies differ from the control and the second opinion does not confirm that as the claim")
        if reasons:
            cls = "NOT READY"
        elif repro == "confirmed" or rv == "EVIDENCE SUPPORTS THE CLAIM" or fast:
            cls = "READY"
            reasons.append("every suite green, no slowdown" + (", the reproduction confirmed on both sides" if repro == "confirmed" else "")
                           + (", the second opinion supports the claim" if rv == "EVIDENCE SUPPORTS THE CLAIM" else "")
                           + ((", faster than the control: " + ", ".join(f"{x['metric']} {x['delta']:+.0%}" for x in fast)) if fast else ""))
        else:
            cls = "SAFE, UNVERIFIED"
            reasons.append("no regression, no slowdown; " + ("the reproduction did not show the problem on the base, so the fix is unconfirmed" if repro == "not reproduced on the base"
                           else "the changed path was not exercised by any suite" + (" (second opinion: claim not tested)" if rv and "NOT TESTED" in rv else "")))
    label = a.label_prefix + LABEL[cls]
    head = f"**Merge readiness: {cls}** — {'; '.join(reasons)}."
    md = [head, ""] + [f"- {f}" for f in facts] + ["", "_A person merges. READY: the evidence supports the claim. SAFE, UNVERIFIED: nothing broke, but the change itself was not exercised. NOT READY: something failed or is unexplained. RERUN: the measurement is not trustworthy._"]
    open(os.path.join(run, "VERDICT.md"), "w").write("\n".join(md) + "\n")
    json.dump({"class": cls, "label": label, "reasons": reasons, "facts": facts}, open(os.path.join(run, "verdict.json"), "w"), indent=1)
    print(head); print(f"label {label}")


if __name__ == "__main__":
    main()
