"""smoke, boundary and cutin suites. Each run(ctx) returns a dict that pairtest writes to the report.

ctx: dict(api, model, out (run directory), opts (suite options from the command line), log (callable))."""
import threading, time
from common import chat, words


def smoke(ctx):
    """Three quick checks: an arithmetic answer, the same greedy request twice (must match), and streaming works."""
    api, model = ctx["api"], ctx["model"]
    a = chat(api, model, [{"role": "user", "content": "What is 17*23? Reply with the number only."}], max_tokens=16)
    q = [{"role": "user", "content": "Name three colours. One line."}]
    b1, b2 = chat(api, model, q, max_tokens=24), chat(api, model, q, max_tokens=24)
    s = chat(api, model, q, max_tokens=24, stream=True)
    errs = [r["error"] for r in (a, b1, b2, s) if r.get("error")]
    checks = {"arithmetic": "391" in a.get("content", ""), "greedy_repeat_equal": not errs and b1.get("sha") == b2.get("sha"),
              "stream_matches": not errs and s.get("content") == b1.get("content")}
    return {"ok": all(checks.values()) and not errs, "checks": checks, "ttft_stream_s": s.get("ttft"), "errors": errs}


def boundary_lengths(chunk):
    """Prompt lengths around the engine's chunk ends: 5, then c-1, c, c+1 for the first three chunks, then 4c+1 and 6c+1."""
    c = int(chunk)
    return (5,) + tuple(k * c + d for k in (1, 2, 3) for d in (-1, 0, 1)) + (4 * c + 1, 6 * c + 1)


def boundary(ctx):
    """Greedy reply hashes at prompt lengths around chunk ends (opts.chunk, from the target's `chunk`, default 2048) and
    prefix-cache cases (repeat, diverge at and off a chunk end, extend). Compare two targets' results."""
    api, model = ctx["api"], ctx["model"]; rows = []; c = int(ctx["opts"].get("chunk", 2048))
    for n in boundary_lengths(c):
        r = chat(api, model, [{"role": "user", "content": words(max(1, n - 4), n)}], max_tokens=24)
        rows.append([f"len{n}", r.get("prompt_tokens"), r.get("sha"), r.get("error")])
    base = words(int(2.5 * c), 1).split()
    for name, ws in (("pfx_base", base), (f"pfx_div{int(1.5 * c)}", base[:int(1.5 * c)] + words(300, 11).split()), (f"pfx_div{c - 4}", base[:c - 4] + words(300, 12).split()),
                     (f"pfx_div{2 * c - 4}", base[:2 * c - 4] + words(300, 13).split()), (f"pfx_div{2 * c - 3}", base[:2 * c - 3] + words(300, 14).split()),
                     ("pfx_base_again", base), ("pfx_extend", base + words(int(0.75 * c), 15).split())):
        r = chat(api, model, [{"role": "user", "content": " ".join(ws)}], max_tokens=24)
        rows.append([name, r.get("prompt_tokens"), r.get("sha"), r.get("error")])
    # rows: [label, tokens the server counted, reply hash or None, error or None]; token counts are what the server
    # reported for the prompt (the word-based lengths only aim at the chunk ends: the report shows the real counts)
    errs = [x for x in rows if x[3]]
    return {"ok": not errs, "hashes": rows, "errors": [f"{x[0]}: {x[3]}" for x in errs]}


def cutin(ctx):
    """A cold long prompt, then a short chat 3 s later: first-token time of each (rounds from opts, default 3)."""
    api, model = ctx["api"], ctx["model"]; n_words = int(ctx["opts"].get("cutin_words", 64000)); res = []; errs = []
    for k in range(int(ctx["opts"].get("rounds", 3))):
        out = {}
        def long():  # noqa: E306
            r = chat(api, model, [{"role": "user", "content": words(n_words, int(time.time()) + k)}], max_tokens=8, stream=True)
            out["long"] = r.get("ttft"); r.get("error") and errs.append(f"round {k} long: {r['error']}")
        t = threading.Thread(target=long); t.start(); time.sleep(3)
        r = chat(api, model, [{"role": "user", "content": "What is 17 times 23? Number only."}], max_tokens=8, stream=True)
        out["short"] = r.get("ttft"); r.get("error") and errs.append(f"round {k} short: {r['error']}")
        t.join(); res.append(out); ctx["log"](f"cutin round {k}: {out}")
    return {"ok": not errs and all(x.get("short") is not None and x.get("long") is not None for x in res), "rounds": res, "errors": errs}


SUITES = {"smoke": smoke, "boundary": boundary, "cutin": cutin}
