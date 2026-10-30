#!/usr/bin/env python3
"""canary.py --tree DIR --mutants FILE [--keep] -- TEST_CMD...

Stage 1 of AGENTS.md: proves each fix has a test that catches it. For every mutant in FILE (YAML list of
{name, file, old, new, expect}) it copies DIR to a scratch tree, replaces the first `old` with `new` in `file`
(multi-line strings are fine: use YAML block scalars), runs TEST_CMD with `{tree}` replaced by the scratch path (and
CANARY_TREE set), and calls the mutant CAUGHT when the command fails and, if `expect` is given, its output contains
that text (the test that should catch it). A mutant whose `old` text is missing is reported as NOT APPLIED.

The original tree is never written: `file` must be a relative path inside the scratch copy, symbolic links are not
followed (a mutant that names one is refused), and the resolved path is checked to stay inside the scratch tree.
Exit status 0 only when every mutant is caught."""
import argparse, os, shutil, subprocess, sys, tempfile
import yaml

ap = argparse.ArgumentParser(usage=__doc__)
ap.add_argument("--tree", required=True)
ap.add_argument("--mutants", required=True)
ap.add_argument("--keep", action="store_true", help="keep scratch trees")
ap.add_argument("cmd", nargs=argparse.REMAINDER)
a = ap.parse_args()
cmd = a.cmd[1:] if a.cmd[:1] == ["--"] else a.cmd
if not cmd:
    sys.exit("give the test command after --, e.g. -- ./run-tests.sh {tree}")
mutants = yaml.safe_load(open(a.mutants)) or []
results = []
for m in mutants:
    name = str(m["name"])
    if not name.replace("_", "").replace("-", "").isalnum():
        results.append((name, "REFUSED", "mutant names are letters, digits, - and _")); continue
    scratch = tempfile.mkdtemp(prefix=f"canary-{name}-")
    tree = os.path.join(scratch, "tree")
    # symlinks are copied as links and never followed when the mutation is written (ignore_dangling keeps broken ones harmless)
    shutil.copytree(a.tree, tree, symlinks=True, ignore=shutil.ignore_patterns(".git", "zig-cache", ".zig-cache", "node_modules"), ignore_dangling_symlinks=True)
    rel = str(m["file"])
    path = os.path.join(tree, rel)
    real_tree = os.path.realpath(tree) + os.sep
    if os.path.isabs(rel) or not os.path.realpath(path).startswith(real_tree) or os.path.islink(path):
        results.append((name, "REFUSED", f"{rel!r} is absolute, escapes the scratch tree, or is a symbolic link"))
        shutil.rmtree(scratch, ignore_errors=True); continue
    if not os.path.isfile(path):
        results.append((name, "NOT APPLIED", f"{rel} is not a file in the tree")); shutil.rmtree(scratch, ignore_errors=True); continue
    src = open(path).read()
    if m["old"] not in src:
        results.append((name, "NOT APPLIED", "old text not found in " + rel)); shutil.rmtree(scratch, ignore_errors=True); continue
    open(path, "w").write(src.replace(m["old"], m["new"], 1))
    run = [c.replace("{tree}", tree) for c in cmd]
    p = subprocess.run(run, capture_output=True, text=True, env={**os.environ, "CANARY_TREE": tree})
    out = p.stdout + p.stderr
    expect = m.get("expect")
    if p.returncode == 0:
        verdict, why = "SURVIVED", "tests passed with the fix switched off"
    elif expect and expect not in out:
        verdict, why = "SURVIVED?", f"tests failed, but not with {expect!r} (another failure?)"
    else:
        verdict, why = "CAUGHT", (f"failed with {expect!r}" if expect else f"exit {p.returncode}")
    results.append((name, verdict, why))
    open(os.path.join(scratch, "output.txt"), "w").write(out)
    if not a.keep:
        shutil.rmtree(scratch, ignore_errors=True)
for n, v, y in results:
    print(f"{n}: {v} ({y})", flush=True)
w = max(len(r[0]) for r in results) if results else 4
print("\n" + "\n".join(f"{n:<{w}}  {v:<11}  {y}" for n, v, y in results))
caught = sum(r[1] == "CAUGHT" for r in results)
print(f"\n{caught} of {len(results)} caught")
sys.exit(0 if caught == len(results) else 1)
