#!/usr/bin/env python3
"""evidence-page.py --repo OWNER/FORK --out page.html [--title TEXT] [--intro TEXT]

The evidence page, generated from the evidence branches so every number on it is the number on the linked run. For
every `evidence/<owner>-<repo>-pr-<n>` branch of the fork it reads each run's verdict.json, VERDICT.md and
run-manifest.json, asks GitHub for the pull request's state now, and writes one HTML page: counts computed from the
runs, one row per PR with its latest run (state at execution, candidate kind, switches, verdict, performance line,
what verified it), and a link to every run folder pinned to the branch commit that holds it. Needs an authenticated gh.
Nothing is posted anywhere; the page is a file."""
import argparse, datetime, html, json, re, subprocess


def gh(args):
    return subprocess.run(["gh"] + args, capture_output=True, text=True, check=True).stdout


def api(path, raw=False):
    return gh(["api", "-H", "Accept: application/vnd.github.raw" if raw else "Accept: application/vnd.github+json", path])


def esc(s): return html.escape(str(s))


CSS = """:root{--bg:#F3F5F4;--panel:#FFFFFF;--ink:#172126;--muted:#5A6A6F;--line:#D5DDDA;--code:#E9EEEC;--accent:#0E6E62;
--ready-bg:#DDF3E8;--ready-ink:#0B5D3B;--safe-bg:#FBF0CF;--safe-ink:#7A5200;--block-bg:#FADCDC;--block-ink:#8A1C1C;--info-bg:#E2EAF4;--info-ink:#28466B;--hist-bg:#E8E8E8;--hist-ink:#444}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){color-scheme:dark;--bg:#0F1517;--panel:#161E21;--ink:#E6ECEA;--muted:#97A6A9;--line:#2A3639;--code:#1E282B;--accent:#2EC4B0;
--ready-bg:#143A2B;--ready-ink:#9BE3C0;--safe-bg:#3E3112;--safe-ink:#F2D27A;--block-bg:#45201F;--block-ink:#F3A9A6;--info-bg:#1F2E42;--info-ink:#A9C4E8;--hist-bg:#2A2F33;--hist-ink:#B8BEC2}}
:root[data-theme="dark"]{color-scheme:dark;--bg:#0F1517;--panel:#161E21;--ink:#E6ECEA;--muted:#97A6A9;--line:#2A3639;--code:#1E282B;--accent:#2EC4B0;
--ready-bg:#143A2B;--ready-ink:#9BE3C0;--safe-bg:#3E3112;--safe-ink:#F2D27A;--block-bg:#45201F;--block-ink:#F3A9A6;--info-bg:#1F2E42;--info-ink:#A9C4E8;--hist-bg:#2A2F33;--hist-ink:#B8BEC2}
body{background:var(--bg);color:var(--ink);font:15px/1.55 ui-sans-serif,system-ui,sans-serif;margin:0;padding:0 20px;padding-block:28px 56px}
.wrap{max-width:1220px;margin:0 auto} h1{font-size:28px;line-height:1.15;margin:0 0 6px;text-wrap:balance} h2{font-size:19px;margin:30px 0 10px} p{margin:6px 0;max-width:80ch}
.sub{color:var(--muted)} .facts{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin:20px 0 6px}
.fact{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:12px 14px} .fact b{display:block;font-size:26px;line-height:1.1;font-variant-numeric:tabular-nums} .fact span{color:var(--muted);font-size:13px}
code{font-family:ui-monospace,Menlo,monospace;font-size:12.5px;background:var(--code);padding:1px 5px;border-radius:4px}
.scroll{overflow-x:auto;border:1px solid var(--line);border-radius:10px;background:var(--panel)} table{border-collapse:collapse;width:100%;min-width:1000px;font-size:13.5px}
th,td{padding:9px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top} th{color:var(--muted);font-weight:500;font-size:12px;letter-spacing:.04em;text-transform:uppercase;background:var(--code)}
tr:last-child td{border-bottom:none} td.num{font-variant-numeric:tabular-nums} td.pr{white-space:nowrap;font-family:ui-monospace,Menlo,monospace;font-size:12.5px}
.badge{display:inline-block;padding:3px 9px;border-radius:999px;font-size:12px;font-weight:600;white-space:nowrap}
.ready{background:var(--ready-bg);color:var(--ready-ink)} .safe{background:var(--safe-bg);color:var(--safe-ink)} .block{background:var(--block-bg);color:var(--block-ink)} .info{background:var(--info-bg);color:var(--info-ink)} .hist{background:var(--hist-bg);color:var(--hist-ink)}
a{color:var(--accent);text-decoration:none} a:hover{text-decoration:underline} .small{font-size:13px;color:var(--muted)} .foot{color:var(--muted);font-size:13px;margin-top:36px;border-top:1px solid var(--line);padding-top:12px}"""


def current_rule(vj, facts, cls):
    """The class a run's recorded facts give under the current verdict rule (audited oracles), when the run was judged
    under an earlier rule: READY survives only with an inspected oracle or a supported, claimed speed-up."""
    if "verified" in vj:
        return cls, ""
    if cls != "READY":
        return cls, ""
    f = " ".join(facts)
    if "claim script: confirmed" in f or "repro script: confirmed" in f:
        return "SAFE, UNVERIFIED", "claim script fails on the base and passes on the PR, oracle not yet inspected by the second opinion"
    if "the PR's own tests: confirmed" in f:
        return "SAFE, UNVERIFIED", "tested by the author (its tests fail on the base, pass on the PR); oracle not independently inspected"
    return "SAFE, UNVERIFIED", "READY under the earlier rule rested on a supporting second opinion or a measured speed-up without an audited test"


_REPO_CACHE = {}


def resolve_repo(slug):
    """An evidence branch names the repository as owner-repo; owners and repositories both carry dashes, so try each
    split from the left and keep the first one GitHub knows (cached)."""
    if slug in _REPO_CACHE:
        return _REPO_CACHE[slug]
    parts = slug.split("-")
    for i in range(1, len(parts)):
        cand = "-".join(parts[:i]) + "/" + "-".join(parts[i:])
        try:
            gh(["repo", "view", cand, "--json", "name"]); _REPO_CACHE[slug] = cand; return cand
        except subprocess.CalledProcessError:
            continue
    _REPO_CACHE[slug] = slug.replace("-", "/", 1); return _REPO_CACHE[slug]


def badge(cls, historical):
    key = {"READY": "ready", "SAFE, UNVERIFIED": "safe", "NOT READY": "block", "RERUN": "info"}.get(cls, "info")
    b = f'<span class="badge {key}">{esc(cls)}</span>'
    return ('<span class="badge hist">HISTORICAL</span> ' + b) if historical else b


def main():
    ap = argparse.ArgumentParser(usage=__doc__)
    ap.add_argument("--repo", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--title", default="Pull requests tested on hardware"); ap.add_argument("--intro", default="")
    a = ap.parse_args()
    branches = [b["name"] for b in json.loads(api(f"repos/{a.repo}/branches?per_page=100")) if b["name"].startswith("evidence/")]
    rows, runs_total, pr_states = [], 0, {}
    for br in sorted(branches):
        m = re.match(r"evidence/(.+)-pr-(\d+)$", br)
        if not m:
            continue
        slug, pr = m.group(1), int(m.group(2))
        owner_repo = resolve_repo(slug)   # owner-repo with dashes in both parts: the first split GitHub knows
        tip = json.loads(api(f"repos/{a.repo}/branches/{br}"))["commit"]["sha"]
        try:
            runs = sorted(x["name"] for x in json.loads(api(f"repos/{a.repo}/contents/docs/evidence?ref={br}")) if x["type"] == "dir")
        except subprocess.CalledProcessError:
            continue
        runs_total += len(runs)
        latest = runs[-1]
        def read(run, f):
            try:
                return api(f"repos/{a.repo}/contents/docs/evidence/{run}/{f}?ref={br}", raw=True)
            except subprocess.CalledProcessError:
                return ""
        vj = {}
        try:
            vj = json.loads(read(latest, "verdict.json") or "{}")
        except ValueError:
            pass
        man = {}
        try:
            man = json.loads(read(latest, "run-manifest.json") or "{}")
        except ValueError:
            pass
        vmd = read(latest, "VERDICT.md")
        facts = vj.get("facts") or [l[2:] for l in vmd.splitlines() if l.startswith("- ")]
        cls = vj.get("class") or (re.search(r"Merge readiness: (?:HISTORICAL — )?([A-Z, ]+?)\*\*", vmd).group(1).strip() if re.search(r"Merge readiness", vmd) else "?")
        perf = next((f for f in facts if f.startswith("performance against the control")), "")
        verified = "; ".join(vj.get("verified") or []) or next((f for f in facts if f.startswith("the PR's own tests") or f.startswith("claim script") or f.startswith("repro script")), "")
        replies = next((f for f in facts if f.startswith("replies")), "")
        state_now, title, url = "?", "", f"https://github.com/{owner_repo}/pull/{pr}"
        try:
            j = json.loads(gh(["pr", "view", str(pr), "-R", owner_repo, "--json", "state,title,url,mergedAt,closedAt"]))
            state_now = j["state"].lower() + (f" {j.get('mergedAt') or j.get('closedAt') or ''}"[:11] if j["state"] != "OPEN" else ""); title = j["title"]; url = j["url"]
        except subprocess.CalledProcessError:
            pass
        pr_states[state_now.split()[0]] = pr_states.get(state_now.split()[0], 0) + 1
        hist = bool(vj.get("historical")) or ((man.get("pr_state") or "open") in ("closed", "merged")) or state_now.startswith(("closed", "merged"))
        cur, cur_why = current_rule(vj, facts, cls)
        links = " · ".join(f'<a href="https://github.com/{a.repo}/tree/{tip}/docs/evidence/{r}">{esc(r)}</a>' for r in runs)
        rows.append({"pr": pr, "url": url, "title": title, "state_now": state_now, "cls": cls, "cur": cur, "cur_why": cur_why, "hist": hist, "perf": perf, "verified": verified, "replies": replies,
                     "exec_state": man.get("pr_state") or "unknown", "kind": man.get("candidate_kind") or "unknown", "switches": man.get("switches") or "unknown",
                     "head": str(man.get("head_sha", ""))[:8], "base": str(man.get("base_sha", ""))[:8], "latest": latest, "links": links, "n": len(runs)})
    order = {"NOT READY": 0, "READY": 1, "SAFE, UNVERIFIED": 2, "RERUN": 3}
    rows.sort(key=lambda r: (r["hist"], order.get(r["cur"], 9), -r["pr"]))
    counts = {}
    for r in rows:
        k = ("historical" if r["hist"] else r["cur"]); counts[k] = counts.get(k, 0) + 1
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    out = [f"<title>{esc(a.title)}</title>", f"<style>{CSS}</style>", '<div class="wrap">', f"<h1>{esc(a.title)}</h1>",
           f'<p class="sub">{esc(a.intro)} Generated {now} from the evidence branches of <a href="https://github.com/{a.repo}">{esc(a.repo)}</a>: every number below is read from the linked run, and every link is pinned to the commit that holds it.</p>',
           '<div class="facts">', f'<div class="fact"><b>{len(rows)}</b><span>pull requests with evidence</span></div>', f'<div class="fact"><b>{runs_total}</b><span>runs on the ring</span></div>']
    for k in ("READY", "SAFE, UNVERIFIED", "NOT READY", "RERUN", "historical"):
        if counts.get(k):
            out.append('<div class="fact"><b>' + str(counts[k]) + '</b><span>' + esc(k) + (" (current)" if k != "historical" else " (PR closed or merged)") + '</span></div>')
    out.append("</div>")
    out.append('<h2>Results</h2><div class="scroll"><table><thead><tr><th>PR</th><th>Title · state now</th><th>Latest run</th><th>Replies</th><th>Performance vs base</th><th>What the run showed</th><th>Verdict under the current rule</th><th>Runs</th></tr></thead><tbody>')
    for r in rows:
        out.append(f'<tr><td class="pr"><a href="{esc(r["url"])}">#{r["pr"]}</a></td><td>{esc(r["title"])}<div class="small">{esc(r["state_now"])}</div></td>'
                   f'<td class="small">{esc(r["latest"])}<br>PR {esc(r["exec_state"])} at execution; {esc(r["kind"])}; switches: {esc(r["switches"])}<br>head {esc(r["head"])} · base {esc(r["base"])}</td>'
                   f'<td class="num small">{esc(r["replies"].replace("replies: ", ""))}</td><td class="num small">{esc(r["perf"].split(": ", 1)[-1])}</td><td class="small">{esc(r["verified"]) or "—"}</td>'
                   f'<td>{badge(r["cur"], r["hist"])}' + (f'<div class="small">at the time: {esc(r["cls"])} — {esc(r["cur_why"])}</div>' if r["cur"] != r["cls"] else "") + f'</td><td class="small">{r["links"]}</td></tr>')
    out.append("</tbody></table></div>")
    out.append('<p class="small">Runs judged before the current rule (Nov 1, 2026) show the class the same facts give under it, with the class recorded at the time underneath. A run of a pull request that was closed or merged at execution, or is closed now, is marked HISTORICAL.</p>')
    out.append('<h2>How to read the verdicts</h2><p><span class="badge ready">READY</span> every regression check passed, no slowdown beyond the calibrated band, and audited evidence verifies the claim (a claim or reproduction script, or the PR\'s own tests, that fail on the base and pass on the PR and that the second opinion inspected and found sound; or a claimed speed-up measured beyond the band that it supports). <span class="badge safe">SAFE, UNVERIFIED</span> nothing regressed, nothing slowed down, the claim is not verified to that standard. <span class="badge block">NOT READY</span> a failed suite, unexplained reply differences, a slowdown confirmed over repetitions, a failing claim test, a patch-number collision, or a contradicting second opinion. <span class="badge info">RERUN</span> the measurement is not trustworthy (incomplete matrix, control failure, a script error, a single-repetition slowdown). <span class="badge hist">HISTORICAL</span> the PR was closed or merged when the run executed: a record, not current readiness.</p>')
    out.append('<div class="foot">Method and tooling: <a href="https://github.com/hecisaza/inference-agent-kit">inference-agent-kit</a>. A run folder holds the report, the raw results.json, the executed script, the PR\'s own tests\' raw output, the second opinion, the verdict and the run manifest. Nothing on this page was posted to the upstream repository.</div></div>')
    open(a.out, "w").write("\n".join(out) + "\n")
    print(f"wrote {a.out}: {len(rows)} PRs, {runs_total} runs, counts {counts}")


if __name__ == "__main__":
    main()
