#!/usr/bin/env python3
"""issue-verdict.py WORKDIR [--test-verdict verdict.json] [--test-class CLASS] [--out DIR]

The outcome of an issue run, in one class, from the files issue-agent.sh leaves in WORKDIR (outcome.json, triage.json,
REPRO.md) and, when the agent opened a pull request, the merge-readiness verdict of that PR's test run:

  FIXED                  a PR was opened and its test run is READY: the reproduction fails on the base, passes on the
                         fix, and the second opinion found the oracle sound
  FIX PROPOSED           a PR was opened; its test run is SAFE, UNVERIFIED or RERUN, or has not run: the fix is there,
                         the verification is not complete
  FIX FAILS              a PR was opened and its test run is NOT READY
  REPRODUCED             the problem shows on the live build (the agent's script confirmed it), no fix was produced
  NOT REPRODUCIBLE HERE  the agent tried on the live build and the problem did not show
  UNCLEAR                the agent reported a reproduction its own script does not confirm, or left nothing usable
  NEEDS THE LAB          triage: showing it needs a configuration, a restart, a crash, hardware or a load the live
                         build does not take; a person schedules the lab for it
  OUT OF SCOPE           triage: a feature request, a question, a data point, or another recipe or hardware
  TRIAGED                a triage-only run: how the issue can be worked, nothing reproduced yet

Writes VERDICT.md and verdict.json ({class, label, reasons, facts, issue, pr, test_class, triage}) to --out (default
WORKDIR) and prints the headline. Exit 0 always: the class is the result."""
import argparse, json, os

LABEL = {"FIXED": "fixed", "FIX PROPOSED": "fix-proposed", "FIX FAILS": "fix-fails", "REPRODUCED": "reproduced",
         "NOT REPRODUCIBLE HERE": "not-reproducible", "UNCLEAR": "unclear", "NEEDS THE LAB": "needs-lab",
         "OUT OF SCOPE": "out-of-scope", "TRIAGED": "triaged"}


def main():
    ap = argparse.ArgumentParser(usage=__doc__)
    ap.add_argument("work"); ap.add_argument("--test-verdict"); ap.add_argument("--test-class"); ap.add_argument("--out"); ap.add_argument("--label-prefix", default="issue:")
    a = ap.parse_args(); w = a.work.rstrip("/"); out = a.out or w
    o = json.load(open(os.path.join(w, "outcome.json")))
    tri = o.get("triage") or {}
    res = o.get("result", "failed")
    reasons, facts = [], []
    tv = {}
    if a.test_verdict and os.path.isfile(a.test_verdict):
        try:
            tv = json.load(open(a.test_verdict))
        except ValueError:
            tv = {}
    tcls = tv.get("class") or (a.test_class or "").strip() or None
    if tri:
        facts.append(f"triage: {tri.get('kind', '?')} ({tri.get('confidence', '?')} confidence)" + ("" if res in ("needs-lab", "out-of-scope", "triaged") else f": {tri.get('why', '')}".rstrip(": ")))
        if tri.get("repro"):
            facts.append(f"triage, what shows it: {tri['repro']}")
        if tri.get("patches"):
            facts.append("patches named: " + ", ".join(str(p) for p in tri["patches"]))
    if o.get("agent_verdict"):
        facts.append(f"the agent's verdict on the live build: {o['agent_verdict']}")
    if o.get("live_repro_exit") is not None:
        e = o["live_repro_exit"]
        facts.append("the agent's reproduction script on the live build: " + ("exit 1, the problem shows" if e == 1 else "exit 0, the problem does not show" if e == 0 else f"exit {e}, it judged nothing"))
    if o.get("fix_commits"):
        facts.append(f"fix: {o['fix_commits']} commit(s) on {o.get('branch', '?')}")
    if o.get("pr_url"):
        facts.append(f"pull request: {o['pr_url']}")
    if tcls:
        facts.append(f"the pull request's test run: {tcls}" + (" (historical)" if tv.get("historical") else ""))
        for r in (tv.get("reasons") or [])[:4]:
            facts.append(f"  test run: {r}")
    if res == "pr":
        if tcls == "READY":
            cls = "FIXED"; reasons.append("the fix passed its test run as READY: reproduction fails on the base and passes on the fix, with the oracle audited")
        elif tcls == "NOT READY":
            cls = "FIX FAILS"; reasons.append("the fix's test run is NOT READY: " + "; ".join((tv.get("reasons") or ["see the run"])[:2]))
        else:
            cls = "FIX PROPOSED"; reasons.append("a pull request with the fix is open; its test run is " + (tcls or "not available") + ", so the fix is not verified to the READY standard")
    elif res == "reproduced":
        cls = "REPRODUCED"; reasons.append("the problem shows on the live build with the agent's script; no fix was produced")
    elif res == "not-reproduced":
        cls = "NOT REPRODUCIBLE HERE"; reasons.append("the agent tried on the live build, with its current configuration, and the problem did not show")
    elif res == "needs-lab":
        cls = "NEEDS THE LAB"; reasons.append("triage: " + (tri.get("repro") or tri.get("why") or "a configuration, restart, crash, hardware or load condition the live build does not take"))
    elif res == "out-of-scope":
        cls = "OUT OF SCOPE"; reasons.append("triage: " + (tri.get("kind", "") + ": " + tri.get("why", "")).strip(": "))
    elif res == "triaged":
        cls = "TRIAGED"; reasons.append("triage only: " + (tri.get("kind", "?") + ": " + tri.get("why", "")).strip(": "))
    else:
        cls = "UNCLEAR"; reasons.append({"unclear": "the agent reported a reproduction that its own script does not confirm on the live build",
                                        "failed": "the agent left nothing usable: " + (o.get("detail") or "")}.get(res, f"result {res}"))
    label = a.label_prefix + LABEL[cls]
    md = [f"**Issue outcome: {cls}** (label `{label}`)", ""]
    md += [f"- {r}" for r in reasons]
    if facts:
        md += ["", "Facts:", ""] + [f"- {f}" for f in facts]
    md.append("")
    md.append("_FIXED means the fix is verified on hardware, not merged. NEEDS THE LAB and REPRODUCED are for a person to pick up._")
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, "VERDICT.md"), "w").write("\n".join(md) + "\n")
    json.dump({"class": cls, "label": label, "reasons": reasons, "facts": facts, "issue": o.get("issue_url"), "pr": o.get("pr_url") or None,
               "test_class": tcls, "triage": tri or None, "result": res}, open(os.path.join(out, "verdict.json"), "w"), indent=1)
    print(f"Issue outcome: {cls} ({label}): {reasons[0] if reasons else ''}")


if __name__ == "__main__":
    main()
