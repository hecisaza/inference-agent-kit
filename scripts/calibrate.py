#!/usr/bin/env python3
"""calibrate.py --out lab.noise.json RUN_DIR [RUN_DIR ...] [--factor 1.5] [--days 30]
   calibrate.py --out lab.noise.json --provisional decode=0.02 prefill=0.015 aggregate=0.055 cut-in=0.03 startup=0.10 [--days 14] [--note TEXT]

Writes the lab's calibrated noise bands for verdict.py. A calibration run is a pairtest run whose two targets have
the SAME artifact id (the same image on both sides): every difference it measures is noise. From one or more such runs
the band of each metric is the largest |delta| seen, times --factor, never below 1 %. Mixed-image runs are refused.
--provisional writes bands given on the command line (for example from same-patch runs with different image ids)
and marks the file provisional; it expires sooner. The file carries its source and an expiry date: after a hardware,
driver, engine or workload change, calibrate again."""
import argparse, datetime, importlib.util, json, os, statistics, sys

_spec = importlib.util.spec_from_file_location("verdict", os.path.join(os.path.dirname(os.path.abspath(__file__)), "verdict.py"))
verdict = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(verdict)

PERF = [("decode", "perf", lambda r: r.get("decode_tps") or [], 1), ("prefill", "perf", lambda r: r.get("prefill_tps") or [], 1),
        ("aggregate", "perf", lambda r: r.get("batch_tps") or [], 1), ("cut-in", "cutin", lambda r: [x.get("short") for x in r.get("rounds", [])], -1),
        ("startup", "startup", lambda r: r.get("seconds_per_start") or [], -1),
        ("aggregate@16", "concurrency", lambda r: [st["aggregate_tps"] for st in r.get("stages", []) if st.get("streams") == 16], 1)]


def med(R, suite, t, pick):
    xs = [v for r in R.get(suite, {}).get(t, []) for v in pick(r) if isinstance(v, (int, float))]
    return (statistics.median(xs), len(xs)) if xs else (None, 0)


def main():
    ap = argparse.ArgumentParser(usage=__doc__)
    ap.add_argument("runs", nargs="*"); ap.add_argument("--out", required=True); ap.add_argument("--factor", type=float, default=1.5)
    ap.add_argument("--days", type=int, default=None); ap.add_argument("--provisional", nargs="*"); ap.add_argument("--note", default="")
    ap.add_argument("--ceiling", type=float, default=0.25, help="largest same-image delta accepted as noise (default 25 %%)")
    ap.add_argument("--no-narrower-than", help="an earlier calibration file: no band is set narrower than it was (few runs cannot justify tightening)")
    a = ap.parse_args()
    today = datetime.date.today()
    if a.provisional is not None:
        bands = {}
        for kv in a.provisional:
            k, v = kv.split("=", 1); bands[k] = float(v)
        out = {"bands": bands, "provisional": True, "source": a.note or "provisional values given on the command line", "measured": today.isoformat(),
               "expires": (today + datetime.timedelta(days=a.days or 14)).isoformat()}
        json.dump(out, open(a.out, "w"), indent=1); print("provisional bands:", bands, "expires", out["expires"]); return
    if not a.runs:
        sys.exit("give calibration run directories, or --provisional")
    worst = {}; images = set(); used = []
    for run in a.runs:
        R = json.load(open(os.path.join(run.rstrip("/"), "results.json"))); meta = R.get("meta", {})
        cand, ctrl = meta.get("candidate"), meta.get("control")
        t = meta.get("targets", {})
        ic, ik = t.get(cand, {}).get("artifact_id"), t.get(ctrl, {}).get("artifact_id")
        if not ic or ic != ik:
            sys.exit(f"{run}: the two targets do not share an artifact id ({ic} vs {ik}); a calibration run must serve the same image on both sides")
        images.add(ic); used.append(os.path.basename(run.rstrip("/")))
        for name, suite, pick, sign in PERF:
            c, nc = med(R, suite, cand, pick); k, nk = med(R, suite, ctrl, pick)
            if c is None or k is None or not k or min(nc, nk) < 2:
                continue
            pr = verdict.paired(R, name, suite, cand, ctrl, pick, sign)   # the same estimator the verdict uses
            d = abs(pr[0]) if pr and pr[1] >= 2 else abs(sign * (c - k) / k)
            if d > a.ceiling:
                sys.exit(f"{run}: {name} differs by {d:.1%} between two copies of the same image (ceiling {a.ceiling:.0%}); that is a "
                         "measurement fault (a warm cache, a kept process, a throttled host), not noise: fix the run, do not write bands from it")
            worst[name] = max(worst.get(name, 0.0), d)
    if not worst:
        sys.exit("no comparable metrics with at least two samples a side")
    bands = {k: round(max(0.01, v * a.factor), 4) for k, v in worst.items()}
    if a.no_narrower_than:
        prev = json.load(open(a.no_narrower_than)).get("bands", {})
        bands = {k: max(v, prev.get(k, 0.0)) for k, v in bands.items()}
        bands.update({k: v for k, v in prev.items() if k not in bands})
    few = len(used) < 5   # a handful of same-image runs bounds nothing statistically: provisional, to be validated prospectively
    out = {"bands": bands, "provisional": few, "source": f"same-image runs {', '.join(used)} (image {', '.join(sorted(images))}), factor {a.factor}"
           + ("; perf metrics compared round by round" ) + (f"; no band narrower than {os.path.basename(a.no_narrower_than)}" if a.no_narrower_than else ""),
           "observed": {k: round(v, 4) for k, v in worst.items()}, "measured": today.isoformat(), "expires": (today + datetime.timedelta(days=a.days or (14 if few else 30))).isoformat()}
    json.dump(out, open(a.out, "w"), indent=1)
    print("bands:", bands, "from observed", out["observed"], "expires", out["expires"])


if __name__ == "__main__":
    main()
