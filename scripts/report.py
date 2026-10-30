#!/usr/bin/env python3
"""report.py RUN_DIR [--title T]: visual documentation of a pairtest run, for humans to validate.

Reads RUN_DIR/results.json and writes into RUN_DIR:
  report.md     a markdown section for the pull request, with the charts as relative image links
  report.html   one self-contained page (share it, or publish it)
  *.svg         the charts (pure SVG, no dependencies)
Only report.md, report.html and the .svg files are meant to be shared: results.json and log.txt stay with the run.
Numbers come from results.json only. Candidate and control come from its meta (written by pairtest); without meta the
order is reported as unknown, never guessed. Every repetition is compared, and an error never counts as a matching
reply. The "what this run does not show" section lists the suites that did not run or were skipped, for the author to
complete."""
import argparse, html, json, os, re, statistics

ALL_SUITES = ("smoke", "boundary", "cutin", "soak", "fault", "bench")
NOT_SHOWN = {"smoke": "basic answers, greedy repeat equality and streaming", "boundary": "reply equality at chunk ends and prefix-cache cases",
             "cutin": "a short request's first-token time behind a cold long prompt", "soak": "errors, canary mismatches and resource growth over time with client aborts",
             "fault": "a clean pair exit and recovery after an injected read fault", "bench": "throughput and latency against a control"}
HASH = re.compile(r"^[0-9a-f]{12}$")


def esc(s): return html.escape(str(s))
def cell(s): return str(s).replace("|", "\\|").replace("\n", " ")
def tick(b): return "✓" if b else "**✗**"


def med(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return round(statistics.median(xs), 2) if xs else None


def spread(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return f"{min(xs)}–{max(xs)}" if len(xs) > 1 else ""


def bar_svg(rows, unit="s", width=640, title=""):
    """rows: [(label, value, emphasis)] -> horizontal bar chart SVG (one scale, labels inside the viewBox)."""
    vals = [v for _, v, _ in rows if v is not None]; vmax = (max(vals) if vals else 1) or 1
    lh, lw, pad = 26, 230, 12; h = pad * 2 + 22 + lh * len(rows)
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {h}" width="{width}" height="{h}" font-family="ui-sans-serif,system-ui" font-size="12">',
           f'<rect width="{width}" height="{h}" fill="#ffffff"/>', f'<text x="{pad}" y="{pad + 12}" font-weight="600" fill="#16202A">{esc(title)}</text>']
    for i, (label, v, emph) in enumerate(rows):
        y = pad + 22 + i * lh; w = 0 if v is None else max(2, (width - lw - pad - 70) * v / vmax)
        out.append(f'<text x="{pad}" y="{y + 15}" fill="#5B6B7A">{esc(label)}</text>')
        out.append(f'<rect x="{lw}" y="{y + 4}" width="{width - lw - pad - 70}" height="14" fill="#E8EDF1"/>')
        out.append(f'<rect x="{lw}" y="{y + 4}" width="{w:.1f}" height="14" fill="{"#0F766E" if emph else "#8FB3AE"}"/>')
        out.append(f'<text x="{width - pad}" y="{y + 15}" text-anchor="end" fill="#16202A">{"n/a" if v is None else f"{v} {unit}"}</text>')
    out.append("</svg>"); return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(usage=__doc__); ap.add_argument("run"); ap.add_argument("--title", default="")
    a = ap.parse_args(); run = a.run.rstrip("/")
    R = json.load(open(os.path.join(run, "results.json")))
    meta = R.pop("meta", None) or {}
    names = meta.get("targets_order") or sorted({n for s in R.values() for n in s})
    cand, ctrl = meta.get("candidate"), meta.get("control")
    order_known = bool(cand)
    if not order_known and len(names) == 2:
        cand, ctrl = names  # for the hash comparison only; labelled "order unknown" below
    title = a.title or (f"{cand} vs {ctrl}" if cand and ctrl else f"pairtest {os.path.basename(run)}")
    md, charts, problems = [], {}, []

    # ---- conditions
    md.append(f"### Evidence: {cell(title)}\n")
    tinfo = meta.get("targets", {})
    if tinfo:
        md.append("| target | role | image / artifact | model | settings that differ from the control |\n|---|---|---|---|---|")
        base_env = tinfo.get(ctrl, {}).get("env", {}) if ctrl else {}
        for n in names:
            t = tinfo.get(n, {}); env = t.get("env", {})
            diff = {k: v for k, v in env.items() if base_env.get(k) != v} | {k: "(unset)" for k in base_env if k not in env}
            role = ("candidate" if n == cand else "control") if order_known else "order unknown"
            md.append(f"| `{cell(n)}` | {role} | `{cell(t.get('image') or t.get('artifact') or '-')}`{(' (' + t['artifact_id'] + ')') if t.get('artifact_id') else ''} | `{cell(t.get('model', '-'))}` | {', '.join(f'`{cell(k)}={cell(v)}`' for k, v in diff.items()) or ('baseline' if n == ctrl else '-')} |")
        md.append("")
        cond = [f"fabric {meta['fabric']}" if meta.get("fabric") else "", f"order: {meta['order']}" if meta.get("order") else "",
                f"repetitions: {meta.get('opts', {}).get('reps', 1)}", f"kit {meta['kit']}" if meta.get("kit") else "", meta.get("conditions", "")]
        md.append("Conditions: " + "; ".join(c for c in cond if c) + ".")
        md.append(f"Restore: {meta.get('restore') or 'not recorded'}.\n")
    else:
        problems.append("no run metadata (an old results.json): candidate/control order is unknown and conditions are missing")
        md.append("_No run metadata: the order of the targets is unknown and the conditions are not recorded._\n")

    # ---- per suite
    for s in [s for s in ALL_SUITES if s in R]:
        md.append(f"#### {s}\n")
        if s == "smoke":
            md.append("| target | rep | arithmetic | greedy repeat equal | stream matches | first token (stream) | errors |\n|---|---|---|---|---|---|---|")
            for n in names:
                for i, r in enumerate(R[s].get(n, [])):
                    c = r.get("checks", {}); md.append(f"| `{cell(n)}` | {i} | {tick(c.get('arithmetic'))} | {tick(c.get('greedy_repeat_equal'))} | {tick(c.get('stream_matches'))} | {r.get('ttft_stream_s', '-')} s | {cell(r.get('errors') or '-')} |")
        elif s == "boundary":
            reps = {n: R[s].get(n, []) for n in names}
            if cand in reps and ctrl in reps and reps[cand] and reps[ctrl]:
                total = same = 0; lines = []
                for i, (ra, rb) in enumerate(zip(reps[cand], reps[ctrl])):
                    ha, hb = ra.get("hashes", []), rb.get("hashes", [])
                    if [x[0] for x in ha] != [x[0] for x in hb] or len(ha) != len(hb):
                        problems.append(f"boundary rep {i}: the two targets ran different prompt sets"); continue
                    for x, y in zip(ha, hb):
                        ok = bool(HASH.match(str(x[2]))) and x[2] == y[2]; total += 1; same += ok
                        lines.append(f"| {i} | {cell(x[0])} | {x[1]} / {y[1]} | `{cell(x[2] or x[3] or '?')}` | `{cell(y[2] or y[3] or '?')}` | {tick(ok)} |")
                md.append(f"**{same} of {total}** greedy reply hashes identical, `{cell(cand)}` against `{cell(ctrl)}`, over {min(len(reps[cand]), len(reps[ctrl]))} repetition(s)."
                          + ("" if order_known else " (order of the targets unknown)") + "\n")
                md.append(f"| rep | prompt | tokens ({cell(cand)} / {cell(ctrl)}) | `{cell(cand)}` | `{cell(ctrl)}` | same |\n|---|---|---|---|---|---|")
                md += lines
            else:
                for n, rs in reps.items():
                    for i, r in enumerate(rs):
                        md.append(f"`{cell(n)}` rep {i}: {len(r.get('hashes', []))} prompts, {len(r.get('errors', []))} errors")
        elif s == "cutin":
            bars = []
            for n in names:
                for i, r in enumerate(R[s].get(n, [])):
                    rd = r.get("rounds", []); sh = med([x.get("short") for x in rd]); lg = med([x.get("long") for x in rd])
                    bars += [(f"{n} rep {i} · short question", sh, n == cand), (f"{n} rep {i} · long prompt", lg, False)]
                    md.append(f"`{cell(n)}` rep {i}: short question first token **{sh} s** (rounds {spread([x.get('short') for x in rd])}), long prompt first token {lg} s (rounds {spread([x.get('long') for x in rd])}); {len(rd)} rounds" + (f"; errors: {cell(r['errors'])}" if r.get("errors") else ""))
            charts["cutin.svg"] = bar_svg(bars, title="Cut-in: seconds to first token, a short question 3 s behind a cold long prompt")
            md.append("\n![cut-in](cutin.svg)")
        elif s == "soak":
            bars = []
            for n in names:
                for i, r in enumerate(R[s].get(n, [])):
                    c = r.get("counts", {}); md.append(f"`{cell(n)}` rep {i}: {c.get('ok', 0)} completions, {c.get('abort', 0)} client aborts, **{c.get('err', 0)} errors**, {c.get('canary', 0)} canary checks with **{c.get('canary_bad', 0)} mismatches**" + (f"; errors: {cell(r['errors'][:3])}" if r.get("errors") else ""))
                    bars += [(f"{n} rep {i} · completions", c.get("ok", 0), True), (f"{n} rep {i} · aborts", c.get("abort", 0), False), (f"{n} rep {i} · errors", c.get("err", 0), False), (f"{n} rep {i} · canary mismatches", c.get("canary_bad", 0), False)]
                    if r.get("samples"):
                        md.append(f"  machine samples, first and last: `{cell(json.dumps(r['samples'][0])[:160])}` → `{cell(json.dumps(r['samples'][-1])[:160])}`")
            charts["soak.svg"] = bar_svg(bars, unit="", title="Soak: request outcomes")
            md.append("\n![soak](soak.svg)")
        elif s == "fault":
            md.append("| target | case | request failed | head exit | seconds to exit | other ranks | reference equal after restart |\n|---|---|---|---|---|---|---|")
            for n in names:
                for r in R[s].get(n, []):
                    if r.get("skipped"):
                        md.append(f"| `{cell(n)}` | skipped: {cell(r['skipped'])} | | | | | |"); continue
                    for c in r.get("cases", []):
                        if c.get("error"):
                            md.append(f"| `{cell(n)}` | {cell(c.get('case'))} | error: {cell(c['error'])} | | | | |"); continue
                        md.append(f"| `{cell(n)}` | {cell(c['case'])} | {tick(c['request_failed'])} | {cell(c['head'])} {tick(c['exit_ok'])} | {c.get('head_exit_s', c.get('head_s'))} | {cell(c['others'])} | {tick(c['reference_equal_after_restart'])}{(' (' + cell(c['after_error']) + ')') if c.get('after_error') else ''} |")
            md.append("\nRestarts between cases were made by the test harness, not by a supervisor.")
        elif s == "bench":
            for n in names:
                for r in R[s].get(n, []):
                    md.append(f"`{cell(n)}`: {'ran' if r.get('ok') else 'did not run'} `{cell(r.get('cmd', r.get('skipped', '')))}`")
        pr = [(n, i, r.get("probe")) for n in names for i, r in enumerate(R[s].get(n, [])) if r.get("probe")]
        if pr:
            md.append("\n<details><summary>machine state after the suite</summary>\n")
            for n, i, p in pr: md.append(f"- `{cell(n)}` rep {i}: `{cell(json.dumps(p)[:300])}`")
            md.append("\n</details>")
        md.append("")

    # ---- limits
    skipped = [(s, r.get("skipped")) for s in R for n in R[s] for r in R[s][n] if r.get("skipped")]
    missing = [s for s in ALL_SUITES if s not in R]
    md.append("#### What this run does not show\n")
    for s in missing: md.append(f"- {NOT_SHOWN[s]} (`{s}` did not run)")
    for s, why in dict(skipped).items(): md.append(f"- {NOT_SHOWN[s]} (`{s}` was skipped: {cell(why)})")
    for p in problems: md.append(f"- **{cell(p)}**")
    md.append("- <!-- add: paths only checked by reading, faults not injected, configurations not run -->\n")
    md.append(f"_Generated by inference-agent-kit `report.py` from `{os.path.basename(run)}/results.json`._")
    for name, svg in charts.items(): open(os.path.join(run, name), "w").write(svg)
    open(os.path.join(run, "report.md"), "w").write("\n".join(md) + "\n")
    open(os.path.join(run, "report.html"), "w").write(render_html(title, md, charts))
    print(f"wrote {run}/report.md, report.html" + (", " + ", ".join(charts) if charts else "") + (f"; {len(problems)} problem(s) noted" if problems else ""))


def md_inline(s):
    s = esc(s)
    s = re.sub(r"`([^`]*)`", r"<code>\1</code>", s); s = re.sub(r"\*\*([^*]*)\*\*", r"<strong>\1</strong>", s); s = re.sub(r"^_([^_]+)_$", r"<em>\1</em>", s)
    return s.replace("\\|", "|")


def split_row(line):
    return [c.strip() for c in re.split(r"(?<!\\)\|", line.strip().strip("|"))]


def render_html(title, md, charts):
    body, in_table = [], False
    for line in "\n".join(md).splitlines():
        if line.startswith("|"):
            cells = split_row(line)
            if set("".join(cells)) <= set("-: "): continue
            if not in_table: body.append("<table>"); in_table = True; tag = "th"
            else: tag = "td"
            body.append("<tr>" + "".join(f"<{tag}>{md_inline(c)}</{tag}>" for c in cells) + "</tr>"); continue
        if in_table: body.append("</table>"); in_table = False
        if line.startswith("#### "): body.append(f"<h2>{esc(line[5:])}</h2>")
        elif line.startswith("### "): body.append(f"<h1>{esc(line[4:])}</h1>")
        elif line.startswith("![") and line.endswith(")"): body.append(charts.get(line[line.index("(") + 1:-1], ""))
        elif line.startswith("- "): body.append(f"<li>{md_inline(line[2:])}</li>")
        elif line.startswith("<"): body.append(line)
        elif line.strip(): body.append(f"<p>{md_inline(line)}</p>")
    if in_table: body.append("</table>")
    return f"""<title>{esc(title)}</title>
<style>:root{{--bg:#F1F4F6;--ink:#16202A;--muted:#5B6B7A;--line:#D6DDE3;--code:#E8EDF1;--accent:#0F766E}}
@media (prefers-color-scheme: dark){{:root:not([data-theme="light"]){{color-scheme:dark;--bg:#0F1519;--ink:#E6EBEF;--muted:#94A3B0;--line:#2A3540;--code:#121A21;--accent:#2DD4BF}}}}
:root[data-theme="dark"]{{color-scheme:dark;--bg:#0F1519;--ink:#E6EBEF;--muted:#94A3B0;--line:#2A3540;--code:#121A21;--accent:#2DD4BF}}
body{{background:var(--bg);color:var(--ink);font:15px/1.5 ui-sans-serif,system-ui,sans-serif;padding:0 20px;padding-block:28px 48px;max-width:1000px;margin:0 auto}}
h1{{font-size:26px;margin:0 0 6px}} h2{{font-size:18px;margin:28px 0 8px}} p{{margin:6px 0}} li{{margin:3px 0}}
code{{font-family:ui-monospace,Menlo,monospace;font-size:12.5px;background:var(--code);padding:1px 5px;border-radius:4px}}
table{{border-collapse:collapse;width:100%;font-size:13.5px;margin:8px 0}} td,th{{padding:5px 8px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}} th{{color:var(--muted);font-weight:600}}
svg{{max-width:100%;height:auto;border:1px solid var(--line);margin:8px 0}} details{{color:var(--muted);font-size:13px}} strong{{color:var(--accent)}}</style>
<div>{chr(10).join(body)}</div>"""


if __name__ == "__main__":
    main()
