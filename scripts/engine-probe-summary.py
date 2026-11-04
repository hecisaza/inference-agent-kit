#!/usr/bin/env python3
"""engine-probe-summary.py OUT_DIR [--template tool_call|dsml]: compares engine-probe.sh's outputs, base against patch.

--template is the tool-call markup the served chat template writes (default tool_call): the streamed-versus-whole
parity that fails the check is the one a client of that template sees; the other is reported.

For the fuzz probe, per family: replies whose whole result (calls and content) is unchanged, has more or FEWER calls;
calls a streaming client receives, unchanged, more, FEWER or OTHER; streamed-versus-whole parity broken on the base,
with the patch, newly broken; inputs skipped because they crash the base. For the other probes: lines that differ.
Any panic is reported first, with the side it happened on. Exit 1 when the patch gives any client fewer or other
calls, or breaks parity anew, or panics where the base did not."""
import collections, glob, os, sys

out = sys.argv[1]; bad = False
template = sys.argv[sys.argv.index("--template") + 1] if "--template" in sys.argv else "tool_call"
for f in sorted(glob.glob(os.path.join(out, "*-base.txt"))):
    name = os.path.basename(f)[:-9]; p = os.path.join(out, name + "-patch.txt")
    base = open(f).read().splitlines(); patch = open(p).read().splitlines() if os.path.exists(p) else []
    for side, lines in (("base", base), ("patch", patch)):
        for l in lines:
            if l.startswith(("panic:", "error:")):
                print(f"{name}: {side} PANIC: {l}"); bad |= side == "patch" and not any(x.startswith("panic:") for x in base)
    if name != "fuzz":
        diff = [(x, y) for x, y in zip(base, patch) if x != y]
        print(f"{name}: {len(base)} lines, {len(diff)} differ")
        for x, y in diff[:10]: print("   base: " + x[:200] + "\n   patch: " + y[:200])
        continue
    B = [l[5:].split("\t") for l in base if l.startswith("FUZZ ")]; P = [l[5:].split("\t") for l in patch if l.startswith("FUZZ ")]
    fam = lambda c: "tag soup" if c % 2 == 0 else ("model-like" if c % 4 == 1 else "mixed")
    R = collections.defaultdict(collections.Counter)
    for x, y in zip(B, P):
        r = R[fam(int(x[0]))]; r["replies"] += 1
        if x[1] == "SKIP": r["crash the base (skipped)"] += 1; continue
        r["whole same" if (x[2], x[3]) == (y[2], y[3]) else ("whole more calls" if int(y[1]) > int(x[1]) else ("WHOLE FEWER CALLS" if int(y[1]) < int(x[1]) else "whole other text"))] += 1
        if x[7] == y[7]: r["streamed same"] += 1
        elif y[7] == y[2]: r["streamed now as whole"] += 1   # a streaming client now gets what a non-streaming one gets
        elif y[7].count(";") > x[7].count(";"): r["streamed more calls"] += 1
        elif y[7].count(";") < x[7].count(";"): r["STREAMED FEWER CALLS"] += 1
        else: r["STREAMED OTHER CALLS"] += 1
        r["parity off on base"] += x[7] != x[2]; r["parity off with patch"] += y[7] != y[2]; r["NEW PARITY BREAK"] += x[7] == x[2] and y[7] != y[2]; r["parity restored"] += x[7] != x[2] and y[7] == y[2]
        if len(y) > 8:   # a DSML template: the streamed calls a client gets when the template writes DSML calls
            r["DSML template: parity off with patch"] += y[8] != y[2]; r["DSML template: parity off on base"] += x[8] != x[2] if len(x) > 8 else 0
        r["stream takes text back, patch"] += y[5] == "RETRACTS"
    for k, r in R.items():
        print(f"fuzz {k}: " + ", ".join(f"{a} {b}" for a, b in r.items()))
        bad |= any(r[x] for x in ("WHOLE FEWER CALLS", "stream takes text back, patch"))
        if template == "dsml": bad |= bool(r["DSML template: parity off with patch"])
        else: bad |= any(r[x] for x in ("STREAMED FEWER CALLS", "STREAMED OTHER CALLS", "NEW PARITY BREAK"))
        if r["NEW PARITY BREAK"]: print(f"   note: {r['NEW PARITY BREAK']} replies where the two kinds of client agreed on the base and differ with the patch")
sys.exit(1 if bad else 0)
