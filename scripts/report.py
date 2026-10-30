#!/usr/bin/env python3
"""report.py RUN_DIR [--title T]: visual documentation of a pairtest run, for humans to validate.

Reads RUN_DIR/results.json (and meta, log) and writes into RUN_DIR:
  report.html   one self-contained page: conditions, every suite's result, charts, probes, limits (share it, or publish it)
  report.md     a markdown section for the pull request, with the charts as relative image links
  *.svg         the charts (pure SVG, no dependencies): commit RUN_DIR under docs/evidence/ in the PR branch so the
                markdown's images render on GitHub, or attach the PNG/SVG files to the PR by hand.
Nothing is uploaded. Numbers come from results.json only; the "what this does not show" section lists the suites
that did not run so the author fills the rest in by hand."""
import argparse, html, json, os, statistics, sys

ALL_SUITES = ("smoke", "boundary", "cutin", "soak", "fault", "bench")
NOT_SHOWN = {"smoke": "basic answers, greedy repeat equality and streaming", "boundary": "reply equality at chunk ends and prefix-cache cases",
             "cutin": "a short request's first-token time behind a cold long prompt", "soak": "errors, canary mismatches and resource growth over time with client aborts",
             "fault": "a clean pair exit and recovery after an injected read fault", "bench": "throughput and latency against a control"}


def esc(s): return html.escape(str(s))


def med(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return round(statistics.median(xs), 2) if xs else None


def bar_svg(rows, unit="s", width=640, title=""):
    """rows: [(label, value, emphasis)] -> horizontal bar chart SVG (one scale, labels inside the viewBox)."""
    vals = [v for _, v, _ in rows if v is not None]; vmax = max(vals) if vals else 1; vmax = vmax or 1
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
    meta = R.pop("meta", {}) if isinstance(R.get("meta"), dict) else {}
    names = meta.get("targets_order") or sorted({n for s in R.values() for n in s})
    title = a.title or f"pairtest {os.path.basename(run)}"
    cand, ctrl = (names + [None, None])[:2]
    md, H, charts = [], [], {}

    # ---- conditions
    md.append(f"### Evidence: {title}\n")
    tinfo = meta.get("targets", {})
    if tinfo:
        md.append("| target | role | image / artifact | model | settings that differ |\n|---|---|---|---|---|")
        base_env = tinfo.get(ctrl, {}).get("env", {}) if ctrl else {}
        for n in names:
            t = tinfo.get(n, {}); env = t.get("env", {})
            diff = {k: v for k, v in env.items() if base_env.get(k) != v} | {k: "(unset)" for k in base_env if k not in env}
            md.append(f"| `{n}` | {'candidate' if n == cand else 'control'} | `{t.get('image') or t.get('artifact') or '-'}` {('(' + t['artifact_id'] + ')') if t.get('artifact_id') else ''} | `{t.get('model', '-')}` | {', '.join(f'`{k}={v}`' for k, v in diff.items()) or ('baseline' if n == ctrl else '-')} |")
        md.append("")
    if meta.get("conditions"):
        md.append(f"Conditions: {meta['conditions']}\n")

    # ---- per suite
    for s in [s for s in ALL_SUITES if s in R]:
        md.append(f"#### {s}\n")
        if s == "smoke":
            md.append("| target | arithmetic | greedy repeat equal | stream matches | first token (stream) |\n|---|---|---|---|---|")
            for n in names:
                for r in R[s].get(n, []):
                    c = r.get("checks", {}); md.append(f"| `{n}` | {'✓' if c.get('arithmetic') else '✗'} | {'✓' if c.get('greedy_repeat_equal') else '✗'} | {'✓' if c.get('stream_matches') else '✗'} | {r.get('ttft_stream_s', '-')} s |")
        elif s == "boundary":
            rows = {n: R[s][n][0].get("hashes", []) for n in names if R[s].get(n)}
            if cand in rows and ctrl in rows:
                same = sum(x[2] == y[2] for x, y in zip(rows[cand], rows[ctrl]))
                md.append(f"**{same} of {len(rows[cand])}** greedy reply hashes identical, `{cand}` against `{ctrl}`.\n")
                md.append(f"| prompt | tokens | `{cand}` | `{ctrl}` | same |\n|---|---|---|---|---|")
                for x, y in zip(rows[cand], rows[ctrl]):
                    md.append(f"| {x[0]} | {x[1]} | `{x[2]}` | `{y[2]}` | {'✓' if x[2] == y[2] else '**✗**'} |")
            else:
                for n, hs in rows.items():
                    md.append(f"`{n}`: {len(hs)} prompts, " + ", ".join(f"{h[0]}={h[2]}" for h in hs[:6]) + " …")
        elif s == "cutin":
            bars = []
            for n in names:
                for r in R[s].get(n, []):
                    rd = r.get("rounds", []); sh = med([x.get("short") for x in rd]); lg = med([x.get("long") for x in rd])
                    bars += [(f"{n} · short question", sh, n == cand), (f"{n} · long prompt", lg, False)]
                    md.append(f"`{n}`: short question first token **{sh} s**, long prompt first token {lg} s (median of {len(rd)} rounds; rounds: {[(x.get('short'), x.get('long')) for x in rd]})")
            charts["cutin.svg"] = bar_svg(bars, title="Cut-in: seconds to first token, a short question 3 s behind a cold long prompt")
            md.append("\n![cut-in](cutin.svg)")
        elif s == "soak":
            bars = []
            for n in names:
                for r in R[s].get(n, []):
                    c = r.get("counts", {}); md.append(f"`{n}`: {c.get('ok', 0)} completions, {c.get('abort', 0)} client aborts, **{c.get('err', 0)} errors**, {c.get('canary', 0)} canary checks with **{c.get('canary_bad', 0)} mismatches**" + (f"; errors: {r['errors'][:3]}" if r.get("errors") else ""))
                    bars += [(f"{n} · completions", c.get("ok", 0), True), (f"{n} · aborts", c.get("abort", 0), False), (f"{n} · errors", c.get("err", 0), False), (f"{n} · canary mismatches", c.get("canary_bad", 0), False)]
                    if r.get("samples"):
                        md.append(f"  resource samples (first / last): `{json.dumps(r['samples'][0])[:160]}` → `{json.dumps(r['samples'][-1])[:160]}`")
            charts["soak.svg"] = bar_svg(bars, unit="", title="Soak: request outcomes")
            md.append("\n![soak](soak.svg)")
        elif s == "fault":
            md.append("| target | case | request failed | head exit | after (s) | other ranks | reference equal after restart |\n|---|---|---|---|---|---|---|")
            for n in names:
                for r in R[s].get(n, []):
                    if r.get("skipped"): md.append(f"| `{n}` | skipped: {r['skipped']} | | | | | |"); continue
                    for c in r.get("cases", []):
                        md.append(f"| `{n}` | {c['case']} | {'✓' if c['request_failed'] else '✗'} | {c['head']} {'✓' if c['exit_ok'] else '✗'} | {c['head_s']} | {c['others']} | {'✓' if c['reference_equal_after_restart'] else '✗'} |")
        elif s == "bench":
            for n in names:
                for r in R[s].get(n, []):
                    md.append(f"`{n}`: {'ran' if r.get('ok') else 'did not run'} `{r.get('cmd', r.get('skipped', ''))}`")
        # probes
        pr = [(n, r.get("probe")) for n in names for r in R[s].get(n, []) if r.get("probe")]
        if pr:
            md.append("\n<details><summary>machine state after the suite</summary>\n")
            for n, p in pr: md.append(f"- `{n}`: `{json.dumps(p)[:300]}`")
            md.append("\n</details>")
        md.append("")

    # ---- limits
    missing = [s for s in ALL_SUITES if s not in R]
    md.append("#### What this run does not show\n")
    for s in missing: md.append(f"- {NOT_SHOWN[s]} (`{s}` did not run)")
    md.append("- <!-- add: paths only checked by reading, faults not injected, configurations not run -->\n")
    md.append(f"_Generated by inference-agent-kit `report.py` from `{os.path.basename(run)}/results.json`; the run's log is `log.txt`._")
    for name, svg in charts.items(): open(os.path.join(run, name), "w").write(svg)
    open(os.path.join(run, "report.md"), "w").write("\n".join(md) + "\n")

    # ---- html: the markdown rendered simply (tables, headings, code, images inline as SVG)
    body = []
    for line in "\n".join(md).splitlines():
        if line.startswith("#### "): body.append(f"<h2>{esc(line[5:])}</h2>")
        elif line.startswith("### "): body.append(f"<h1>{esc(line[4:])}</h1>")
        elif line.startswith("![") and line.endswith(")"): body.append(charts.get(line[line.index("(") + 1:-1], ""))
        elif line.startswith("|"):
            cells = [c.strip() for c in line.strip("|").split("|")]
            if set("".join(cells)) <= set("-: "): continue
            tag = "th" if body and not body[-1].startswith("<tr>") and not body[-1].startswith("<table") and not body[-1].endswith("</tr>") else "td"
            if tag == "th": body.append("<table>")
            body.append("<tr>" + "".join(f"<{tag}>{md_inline(c)}</{tag}>" for c in cells) + "</tr>")
        elif line.strip() == "":
            if body and body[-1].endswith("</tr>"): body.append("</table>")
            body.append("")
        elif line.startswith("- "): body.append(f"<li>{md_inline(line[2:])}</li>")
        elif line.startswith("<"): body.append(line)
        else: body.append(f"<p>{md_inline(line)}</p>")
    if body and body[-1].endswith("</tr>"): body.append("</table>")
    page = f"""<title>{esc(title)}</title>
<style>:root{{--bg:#F1F4F6;--ink:#16202A;--muted:#5B6B7A;--line:#D6DDE3;--code:#E8EDF1;--accent:#0F766E}}
@media (prefers-color-scheme: dark){{:root:not([data-theme="light"]){{color-scheme:dark;--bg:#0F1519;--ink:#E6EBEF;--muted:#94A3B0;--line:#2A3540;--code:#121A21;--accent:#2DD4BF}}}}
:root[data-theme="dark"]{{color-scheme:dark;--bg:#0F1519;--ink:#E6EBEF;--muted:#94A3B0;--line:#2A3540;--code:#121A21;--accent:#2DD4BF}}
body{{background:var(--bg);color:var(--ink);font:15px/1.5 ui-sans-serif,system-ui,sans-serif;padding:0 20px;padding-block:28px 48px;max-width:1000px;margin:0 auto}}
h1{{font-size:26px;margin:0 0 6px}} h2{{font-size:18px;margin:28px 0 8px}} p{{margin:6px 0}} li{{margin:3px 0}}
code{{font-family:ui-monospace,Menlo,monospace;font-size:12.5px;background:var(--code);padding:1px 5px;border-radius:4px}}
table{{border-collapse:collapse;width:100%;font-size:13.5px;margin:8px 0}} td,th{{padding:5px 8px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}} th{{color:var(--muted);font-weight:600}}
svg{{max-width:100%;height:auto;border:1px solid var(--line);margin:8px 0}} details{{color:var(--muted);font-size:13px}} strong{{color:var(--accent)}}</style>
<div>{chr(10).join(body)}</div>"""
    open(os.path.join(run, "report.html"), "w").write(page)
    print(f"wrote {run}/report.md, report.html" + (", " + ", ".join(charts) if charts else ""))


def md_inline(s):
    import re
    s = esc(s)
    s = re.sub(r"`([^`]*)`", r"<code>\1</code>", s); s = re.sub(r"\*\*([^*]*)\*\*", r"<strong>\1</strong>", s); s = re.sub(r"_([^_]+)_$", r"<em>\1</em>", s)
    return s


if __name__ == "__main__":
    main()
