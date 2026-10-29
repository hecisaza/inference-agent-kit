"""smoke, boundary and cutin suites. Each run(ctx) returns a dict that pairtest writes to the report.

ctx: dict(api, model, out (run directory), opts (suite options from the command line), log (callable))."""
import json, os, threading, time
from common import chat, words


def smoke(ctx):
    """Three quick checks: an arithmetic answer, the same greedy request twice (must match), and streaming works."""
    api, model = ctx["api"], ctx["model"]
    a = chat(api, model, [{"role": "user", "content": "What is 17*23? Reply with the number only."}], max_tokens=16)
    q = [{"role": "user", "content": "Name three colours. One line."}]
    b1, b2 = chat(api, model, q, max_tokens=24), chat(api, model, q, max_tokens=24)
    s = chat(api, model, q, max_tokens=24, stream=True)
    checks = {"arithmetic": "391" in a.get("content", ""), "greedy_repeat_equal": b1.get("sha") == b2.get("sha") and not b1.get("error"),
              "stream_matches": s.get("content") == b1.get("content")}
    return {"ok": all(checks.values()), "checks": checks, "ttft_stream_s": s.get("ttft")}


BOUNDARY_LENGTHS = (5, 2047, 2048, 2049, 4095, 4096, 4097, 6143, 6144, 6145, 8193, 12289)


def boundary(ctx):
    """Greedy reply hashes at prompt lengths around chunk ends and prefix-cache cases. Compare two targets' results."""
    api, model = ctx["api"], ctx["model"]; rows = []
    for n in BOUNDARY_LENGTHS:
        r = chat(api, model, [{"role": "user", "content": words(max(1, n - 4), n)}], max_tokens=24)
        rows.append([f"len{n}", r.get("prompt_tokens"), r.get("sha") or r.get("error")])
    base = words(5000, 1).split()
    for name, ws in (("pfx_base", base), ("pfx_div3001", base[:3001] + words(300, 11).split()), ("pfx_div2044", base[:2044] + words(300, 12).split()),
                     ("pfx_div4092", base[:4092] + words(300, 13).split()), ("pfx_div4093", base[:4093] + words(300, 14).split()),
                     ("pfx_base_again", base), ("pfx_extend", base + words(1500, 15).split())):
        r = chat(api, model, [{"role": "user", "content": " ".join(ws)}], max_tokens=24)
        rows.append([name, r.get("prompt_tokens"), r.get("sha") or r.get("error")])
    return {"ok": not any(str(x[2]).startswith(("HTTP", "URLError", "Timeout")) for x in rows), "hashes": rows}


def cutin(ctx):
    """A cold long prompt, then a short chat 3 s later: first-token time of each (rounds from opts, default 3)."""
    api, model = ctx["api"], ctx["model"]; n_words = int(ctx["opts"].get("cutin_words", 64000)); res = []
    for k in range(int(ctx["opts"].get("rounds", 3))):
        out = {}
        def long():  # noqa: E306
            out["long"] = chat(api, model, [{"role": "user", "content": words(n_words, int(time.time()) + k)}], max_tokens=8, stream=True).get("ttft")
        t = threading.Thread(target=long); t.start(); time.sleep(3)
        out["short"] = chat(api, model, [{"role": "user", "content": "What is 17 times 23? Number only."}], max_tokens=8, stream=True).get("ttft")
        t.join(); res.append(out); ctx["log"](f"cutin round {k}: {out}")
    return {"ok": True, "rounds": res}


SUITES = {"smoke": smoke, "boundary": boundary, "cutin": cutin}
