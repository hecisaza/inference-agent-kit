"""smoke, boundary, cutin and repro suites. Each run(ctx) returns a dict that pairtest writes to the report.

ctx: dict(api, model, out (run directory), opts (suite options from the command line), log (callable))."""
import json, subprocess, threading, time
from common import chat, words


def smoke(ctx):
    """Four quick checks: an arithmetic answer, the same greedy request twice (must match), streaming works, and JSON mode gives a JSON object."""
    api, model = ctx["api"], ctx["model"]
    a = chat(api, model, [{"role": "user", "content": "What is 17*23? Reply with the number only."}], max_tokens=16)
    q = [{"role": "user", "content": "Name three colours. One line."}]
    b1, b2 = chat(api, model, q, max_tokens=24), chat(api, model, q, max_tokens=24)
    s = chat(api, model, q, max_tokens=24, stream=True)
    # JSON mode: the reply to a response_format json_object request parses as a JSON object. A server that rejects
    # response_format (HTTP 4xx) is recorded as "unsupported", not as a failure: not every backend has it.
    j = chat(api, model, [{"role": "user", "content": "Give the weather for one city as a JSON object with keys city and temp_c. JSON only."}],
             max_tokens=60, extra={"response_format": {"type": "json_object"}})
    json_mode = "unsupported" if j.get("error", "").startswith("HTTP 4") else _is_json_object(j.get("content", ""))
    errs = [r["error"] for r in (a, b1, b2, s) if r.get("error")] + ([j["error"]] if j.get("error") and json_mode != "unsupported" else [])
    checks = {"arithmetic": "391" in a.get("content", ""), "greedy_repeat_equal": not errs and b1.get("sha") == b2.get("sha"),
              "stream_matches": not errs and s.get("content") == b1.get("content"), "json_mode": json_mode}
    return {"ok": all(v is True or v == "unsupported" for v in checks.values()) and not errs, "checks": checks, "ttft_stream_s": s.get("ttft"), "errors": errs}


def _is_json_object(text):
    t = text.strip()
    if t.startswith("```"):
        t = t.strip("`").split("\n", 1)[-1].rsplit("```", 1)[0].strip()
    try:
        return isinstance(json.loads(t), dict)
    except ValueError:
        return False


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
            r = chat(api, model, [{"role": "user", "content": words(n_words, 7000 + k)}], max_tokens=8, stream=True)  # same prompt per round on both targets; distinct rounds
            out["long"] = r.get("ttft"); r.get("error") and errs.append(f"round {k} long: {r['error']}")
        t = threading.Thread(target=long); t.start(); time.sleep(3)
        r = chat(api, model, [{"role": "user", "content": "What is 17 times 23? Number only."}], max_tokens=8, stream=True)
        out["short"] = r.get("ttft"); r.get("error") and errs.append(f"round {k} short: {r['error']}")
        t.join(); res.append(out); ctx["log"](f"cutin round {k}: {out}")
    return {"ok": not errs and all(x.get("short") is not None and x.get("long") is not None for x in res), "rounds": res, "errors": errs}


def repro(ctx):
    """Runs an issue's reproduction command against the target (opts repro_cmd; {api} {model} {out} {role} are filled
    in). Exit 0 means the problem does not show, anything else means it does. The suite is ok when the result is what
    the target's role predicts: the control (the base) shows the problem, the candidate (the fix) does not."""
    cmd = ctx["opts"].get("repro_cmd")
    if not cmd:
        return {"ok": False, "skipped": "no repro_cmd (pass --opt repro_cmd='bash tests/repro-issue-N.sh {api} {model}')"}
    role = ctx.get("role", "candidate")
    full = cmd
    for k, v in (("{api}", ctx["api"]), ("{model}", ctx["model"]), ("{out}", ctx["out"]), ("{role}", role)):
        full = full.replace(k, str(v))
    try:
        p = subprocess.run(full, shell=True, capture_output=True, text=True, timeout=float(ctx["opts"].get("repro_timeout_s", 1800)))
        rc, out = p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired as e:
        rc, out = -1, f"timeout after {e.timeout} s\n" + ((e.stdout or b"").decode(errors="ignore") if isinstance(e.stdout, bytes) else (e.stdout or ""))
    shows = rc != 0
    return {"ok": shows == (role == "control"), "role": role, "exit": rc, "shows_problem": shows, "cmd": cmd, "output_tail": out[-2000:]}


SUITES = {"smoke": smoke, "boundary": boundary, "cutin": cutin, "repro": repro}
