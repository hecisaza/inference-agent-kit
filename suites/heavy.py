"""soak and fault suites (see suites/basic.py for the ctx contract; these also use ctx['ssh'], ctx['hosts'],
ctx['restart'] and ctx['target'])."""
import http.client, json, random, threading, time, urllib.parse
from common import chat, words


def soak(ctx):
    """N minutes (opts minutes, default 10) of W workers (opts workers, default 3): normal requests, client aborts during
    prefill, and canary prompts whose greedy reply must never change. Samples thread/fd counts of the served container
    on every host each minute when ctx['sample'] is given."""
    api, model, opts = ctx["api"], ctx["model"], ctx["opts"]
    end = time.time() + float(opts.get("minutes", 10)) * 60
    canary_q = [{"role": "user", "content": "List the planets of the solar system, comma separated."}]
    ref = chat(api, model, canary_q, max_tokens=48).get("sha")
    st = {"ok": 0, "abort": 0, "err": 0, "canary": 0, "canary_bad": 0}; errs = []; lock = threading.Lock(); samples = []

    u = urllib.parse.urlsplit(api.rstrip("/") + "/chat/completions")

    def abort_after(text, delay):
        """Opens the request, waits `delay` s while the server reads the prompt, then drops the connection."""
        body = json.dumps({"model": model, "messages": [{"role": "user", "content": text}], "max_tokens": 32, "stream": True}).encode()
        C = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
        c = C(u.hostname, u.port, timeout=30); c.request("POST", u.path, body, {"Content-Type": "application/json"})
        time.sleep(delay); c.close()

    def worker(w):
        r = random.Random(w)
        while time.time() < end:
            k = r.random()
            try:
                if k < 0.3:
                    abort_after(words(r.randint(6000, 30000), r.randint(0, 10**6)), r.uniform(1, 6)); key = "abort"
                elif k < 0.5:
                    got = chat(api, model, canary_q, max_tokens=48)
                    with lock:
                        st["canary"] += 1; st["canary_bad"] += got.get("sha") != ref
                    continue
                else:
                    got = chat(api, model, [{"role": "user", "content": words(r.randint(50, 4000), r.randint(0, 10**6))}], max_tokens=r.randint(16, 200))
                    key = "err" if got.get("error") else "ok"
                    if got.get("error"):
                        errs.append(got["error"][:120])
                with lock:
                    st[key] += 1
            except Exception as e:  # noqa: BLE001
                with lock:
                    st["err"] += 1; errs.append(repr(e)[:120])
    ts = [threading.Thread(target=worker, args=(w,)) for w in range(int(opts.get("workers", 3)))]
    [t.start() for t in ts]
    while any(t.is_alive() for t in ts):
        if ctx.get("sample"):
            samples.append(ctx["sample"]())
        ctx["log"](f"soak {json.dumps(st)}"); time.sleep(60)
    [t.join() for t in ts]
    return {"ok": st["err"] == 0 and st["canary_bad"] == 0, "counts": st, "errors": errs[:10], "samples": samples}


def fault(ctx):
    """Arms the target's test-only fault hook on each listed host and site (target fault: {container, trigger_path,
    cases: [{host, site}]}), sends a fresh prompt, and records: the request failed, the head container exited with the
    expected status within bounded time, the other ranks' state, and after ctx['restart']() whether a reference
    greedy reply is unchanged. Needs an image built with the hook; never point it at a production image."""
    api, model, f = ctx["api"], ctx["model"], ctx["target"].get("fault")
    if not f:
        return {"ok": False, "skipped": "target has no fault: section (an image with a test-only hook)"}
    c = f["container"]; trig = f.get("trigger_path", "/tmp/engram-fault"); want = int(f.get("exit_status", 75)); res = []
    ref_q = [{"role": "user", "content": words(3000, 7)}]
    for k, case in enumerate(f["cases"]):
        ctx["restart"](); b0 = chat(api, model, ref_q, max_tokens=32); base = b0.get("sha")
        if b0.get("error"):
            res.append({"case": case, "error": "reference request failed before the fault: " + b0["error"]}); continue
        ctx["ssh"](case["host"], f"docker exec {c} sh -c 'echo {case.get('site', '')} > {trig}'")
        t0 = time.time(); r = chat(api, model, [{"role": "user", "content": words(9000, 1000 + k)}], max_tokens=16, timeout=300)
        head = ctx["head"]; status = ""; t1 = time.time()
        while time.time() - t1 < 300:  # the exit is watched for up to 300 s after the request returned, whatever it took
            status = ctx["ssh"](head, f"docker inspect -f '{{{{.State.Status}}}} {{{{.State.ExitCode}}}}' {c} 2>/dev/null || echo gone").strip()
            if status.startswith("exited") or status == "gone":
                break
            time.sleep(2)
        others = {h: ctx["ssh"](h, f"docker inspect -f '{{{{.State.Status}}}} {{{{.State.ExitCode}}}}' {c} 2>/dev/null || echo gone").strip() for h in ctx["hosts"] if h != head}
        exited_s = round(time.time() - t0, 1)
        ctx["restart"](); a0 = chat(api, model, ref_q, max_tokens=32); after = a0.get("sha")
        row = {"case": case, "request_failed": bool(r.get("error")), "head": status, "head_exit_s": exited_s, "others": others,
               "reference_equal_after_restart": bool(after) and after == base, "after_error": a0.get("error"), "exit_ok": status == f"exited {want}"}
        res.append(row); ctx["log"](f"fault {row}")
    return {"ok": bool(res) and all(x.get("request_failed") and x.get("exit_ok") and x.get("reference_equal_after_restart") for x in res), "cases": res}


def _mem_mb(text):
    """'12.3GiB / 128GiB' -> 12595.2 (MB); None when unreadable."""
    import re
    m = re.match(r"\s*([0-9.]+)\s*([KMGT]i?B)", text or "")
    if not m:
        return None
    v, u = float(m.group(1)), m.group(2)[0]
    return round(v * {"K": 1 / 1024, "M": 1, "G": 1024, "T": 1024 * 1024}[u], 1)


def concurrency(ctx):
    """Sustained concurrency and resource growth. Fixed prompts at 1, 4, 8 and 16 concurrent streams (opts conc_streams,
    default "1,4,8,16"; opts conc_tokens, default 128 tokens per reply; opts conc_rounds, default 2 rounds of all
    stages). Records per stage: aggregate tokens/s, first-token latency median and p95, errors. Serial-vs-batched
    determinism: every batched reply's hash is compared with the serial reply to the same prompt. When the target names
    its container, the served container's host memory and open descriptors are sampled on every host before, after
    each round and after a 30 s drain: growth after the drain, per 1000 requests, is the leak proxy. A warm-up pass
    over every stage (not recorded) precedes the baseline sample, so a fresh process's first-use allocations per
    batch size are not counted as growth."""
    api, model, opts = ctx["api"], ctx["model"], ctx["opts"]
    stages = [int(x) for x in str(opts.get("conc_streams", "1,4,8,16")).split(",") if x]
    tokens, rounds = int(opts.get("conc_tokens", 128)), int(opts.get("conc_rounds", 2))
    rep = int(ctx.get("rep", 0))
    prompts = [[{"role": "user", "content": f"Topic {i}. " + words(300, 5000 + 100 * rep + i) + " Write four sentences about it."}] for i in range(16)]   # cold on every repetition
    container = ctx.get("target", {}).get("container"); hosts = ctx.get("hosts", []) if container else []

    def sample(label):
        out = {}
        for h in hosts:
            mem = _mem_mb(ctx["ssh"](h, f"docker stats --no-stream --format '{{{{.MemUsage}}}}' {container} 2>/dev/null"))
            fds = ctx["ssh"](h, f"docker exec {container} sh -c 'for p in /proc/[0-9]*; do ls $p/fd 2>/dev/null; done | wc -l' 2>/dev/null").strip()
            out[h] = {"mem_mb": mem, "fds": int(fds) if fds.isdigit() else None}
        ctx["log"](f"concurrency sample {label}: " + json.dumps(out)); return out

    serial, results, errs, total = {}, [], [], 0
    # a fresh process allocates on the first use of EACH batch size (graphs, buffers; +300 MB over a first pass of 1-16
    # streams on the ring, +2 MB on a warm process): a warm-up pass over every stage (opts conc_warmup, default 1 pass;
    # 0 skips it), not recorded, comes before the memory baseline so growth measures the steady state
    for _ in range(int(opts.get("conc_warmup", 1))):
        got = 0
        for n in stages:
            outs = [None] * 16
            def warm(i):  # noqa: E306
                outs[i] = chat(api, model, prompts[i], max_tokens=tokens, stream=True)
            for start in range(0, 16, n):
                ts = [threading.Thread(target=warm, args=(i,)) for i in range(start, min(16, start + n))]
                [t.start() for t in ts]; [t.join() for t in ts]
            got += sum(1 for r in outs if r and not r.get("error"))
        ctx["log"](f"concurrency warm-up over {len(stages)} stages: {got}/{16 * len(stages)} replies")
    before = sample("before") if hosts else {}
    for rnd in range(rounds):
        for n in stages:
            lat, toks, outs = [], 0, [None] * 16
            def one(i, n=n):  # noqa: E306
                outs[i] = chat(api, model, prompts[i], max_tokens=tokens, stream=True)
            t0 = time.time()
            for start in range(0, 16, n):   # 16 requests per stage, n at a time
                ts = [threading.Thread(target=one, args=(i,)) for i in range(start, min(16, start + n))]
                [t.start() for t in ts]; [t.join() for t in ts]
            el = time.time() - t0
            for i, r in enumerate(outs):
                if r is None or r.get("error"):
                    errs.append(f"round {rnd} streams {n} prompt {i}: {(r or {}).get('error', 'no reply')}"); continue
                toks += r.get("completion_tokens") or 0; total += 1
                if r.get("ttft") is not None: lat.append(r["ttft"])
                if n == 1 and rnd == 0: serial[i] = r.get("sha")
            lat.sort()
            results.append({"round": rnd, "streams": n, "aggregate_tps": round(toks / max(el, 1e-3), 1), "ttft_p50": lat[len(lat) // 2] if lat else None,
                            "ttft_p95": lat[min(len(lat) - 1, int(len(lat) * 0.95))] if lat else None, "requests": sum(1 for r in outs if r and not r.get("error")),
                            "batched_vs_serial": None if n == 1 else {"compared": sum(1 for i, r in enumerate(outs) if r and r.get("sha") and i in serial),
                                                                       "mismatch": sum(1 for i, r in enumerate(outs) if r and r.get("sha") and i in serial and r["sha"] != serial[i])}})
            ctx["log"](f"concurrency round {rnd} streams {n}: {results[-1]}")
        if hosts: sample(f"after round {rnd}")
    after = {}
    if hosts:
        time.sleep(30); after = sample("after drain")
    memory = {}
    for h in hosts:
        b, a = before.get(h, {}), after.get(h, {})
        if b.get("mem_mb") is not None and a.get("mem_mb") is not None:
            memory[h] = {"before_mb": b["mem_mb"], "after_drain_mb": a["mem_mb"], "growth_mb": round(a["mem_mb"] - b["mem_mb"], 1),
                         "growth_mb_per_1000_requests": round((a["mem_mb"] - b["mem_mb"]) / max(total, 1) * 1000, 1), "fds_before": b.get("fds"), "fds_after": a.get("fds")}
    mism = sum((r["batched_vs_serial"] or {}).get("mismatch", 0) for r in results)
    return {"ok": not errs and mism == 0, "stages": results, "determinism": {"compared": sum((r["batched_vs_serial"] or {}).get("compared", 0) for r in results), "mismatch": mism},
            "memory": memory, "requests": total, "errors": errs[:10]}


def endurance(ctx):
    """One process under mixed load for a long time (opts endurance_minutes, default 120), probed every
    opts endurance_probe_minutes (default 10): the load pauses and drains, a fixed probe measures one-stream decode
    tokens/s, cold prefill tokens/s and 4-stream aggregate tokens/s, checks a canary reply, and samples the served
    container's memory and descriptors on every host (target `container`); then the load resumes. The load
    (opts endurance_workers, default 4): short chats, long prompts, repeats of earlier long prompts (prefix-cache
    hits), client aborts during prefill, idle gaps. Returns the probes as a time series and the drift: the last probe
    and the worst probe against the first, memory growth per host over the whole run."""
    api, model, opts = ctx["api"], ctx["model"], ctx["opts"]
    minutes = float(opts.get("endurance_minutes", 120)); every = float(opts.get("endurance_probe_minutes", 10))
    nworkers = int(opts.get("endurance_workers", 4)); rep = int(ctx.get("rep", 0))
    container = ctx.get("target", {}).get("container"); hosts = ctx.get("hosts", []) if container else []
    canary_q = [{"role": "user", "content": "List the planets of the solar system, comma separated."}]

    def sample():
        out = {}
        for h in hosts:
            mem = _mem_mb(ctx["ssh"](h, f"docker stats --no-stream --format '{{{{.MemUsage}}}}' {container} 2>/dev/null"))
            fds = ctx["ssh"](h, f"docker exec {container} sh -c 'for p in /proc/[0-9]*; do ls $p/fd 2>/dev/null; done | wc -l' 2>/dev/null").strip()
            out[h] = {"mem_mb": mem, "fds": int(fds) if fds.isdigit() else None}
        return out

    u = urllib.parse.urlsplit(api.rstrip("/") + "/chat/completions")

    def abort_after(text, delay):
        body = json.dumps({"model": model, "messages": [{"role": "user", "content": text}], "max_tokens": 32, "stream": True}).encode()
        C = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
        c = C(u.hostname, u.port, timeout=30); c.request("POST", u.path, body, {"Content-Type": "application/json"})
        time.sleep(delay); c.close()

    st = {"ok": 0, "abort": 0, "err": 0, "repeat": 0, "idle": 0}; errs = []; lock = threading.Lock()
    stop = threading.Event(); pause = threading.Event(); active = [0]; longs = []

    def worker(w):
        r = random.Random(1000 * rep + w)
        while not stop.is_set():
            if pause.is_set():
                time.sleep(0.2); continue
            k = r.random()
            with lock: active[0] += 1
            try:
                if k < 0.35:
                    got = chat(api, model, [{"role": "user", "content": words(r.randint(50, 400), r.randint(0, 10**6))}], max_tokens=r.randint(16, 200)); key = "ok"
                elif k < 0.60:
                    q = words(r.randint(3000, 8000), r.randint(0, 10**6))
                    got = chat(api, model, [{"role": "user", "content": q}], max_tokens=64); key = "ok"
                    with lock:
                        longs.append(q); del longs[:-32]
                elif k < 0.75 and longs:
                    with lock: q = r.choice(longs)
                    got = chat(api, model, [{"role": "user", "content": q + " Now summarize it in one sentence."}], max_tokens=48); key = "repeat"
                elif k < 0.85:
                    abort_after(words(r.randint(6000, 20000), r.randint(0, 10**6)), r.uniform(1, 6)); got = {}; key = "abort"
                else:
                    time.sleep(r.uniform(5, 20)); got = {}; key = "idle"
                if got.get("error"):
                    key = "err"; errs.append(got["error"][:120])
                with lock: st[key] += 1
            except Exception as e:  # noqa: BLE001
                with lock:
                    st["err"] += 1; errs.append(repr(e)[:120])
            finally:
                with lock: active[0] -= 1

    def drain(limit=600):
        pause.set(); t = time.time()
        while active[0] > 0 and time.time() - t < limit:
            time.sleep(0.5)
        return active[0] == 0

    def probe(k, t0):
        pr = {"minute": round((time.time() - t0) / 60, 1), "drained": drain(), "errors": []}
        d = chat(api, model, [{"role": "user", "content": "Describe a river valley through the four seasons in plain prose. Endurance probe."}], max_tokens=256, stream=True)
        if d.get("error"): pr["errors"].append("decode: " + d["error"])
        elif d.get("completion_tokens") and d.get("ttft") is not None: pr["decode_tps"] = round(d["completion_tokens"] / max(d["total"] - d["ttft"], 1e-3), 1)
        p = chat(api, model, [{"role": "user", "content": words(12000, 9500 + 100 * rep + k)}], max_tokens=1, stream=True)   # cold every probe
        if p.get("error"): pr["errors"].append("prefill: " + p["error"])
        elif p.get("prompt_tokens") and p.get("ttft"): pr["prefill_tps"] = round(p["prompt_tokens"] / p["ttft"], 1)
        outs = [None] * 4
        def one(i):  # noqa: E306
            outs[i] = chat(api, model, [{"role": "user", "content": f"List twenty animals with one fact each. Endurance {i}."}], max_tokens=128, stream=True)
        ts = [threading.Thread(target=one, args=(i,)) for i in range(4)]; ta = time.time()
        [t.start() for t in ts]; [t.join() for t in ts]
        el = time.time() - ta
        if any(o is None or o.get("error") for o in outs): pr["errors"].append("aggregate: " + next((o.get("error") for o in outs if o and o.get("error")), "no reply"))
        else: pr["aggregate_tps"] = round(sum(o.get("completion_tokens") or 0 for o in outs) / max(el, 1e-3), 1)
        c = chat(api, model, canary_q, max_tokens=48); pr["canary_sha"] = c.get("sha")
        if hosts: pr["memory"] = sample()
        pause.clear(); return pr

    t0 = time.time(); probes = [probe(0, t0)]
    ts = [threading.Thread(target=worker, args=(w,), daemon=True) for w in range(nworkers)]
    [t.start() for t in ts]
    k = 0
    while time.time() - t0 < minutes * 60:
        time.sleep(1)
        if time.time() - t0 >= (k + 1) * every * 60 or time.time() - t0 >= minutes * 60:
            k += 1; probes.append(probe(k, t0))
            ctx["log"](f"endurance probe {k} at {probes[-1]['minute']} min: decode {probes[-1].get('decode_tps')} prefill {probes[-1].get('prefill_tps')} aggregate {probes[-1].get('aggregate_tps')} tok/s; load so far {json.dumps(st)}")
    stop.set(); [t.join(timeout=120) for t in ts]
    first = probes[0]; last = probes[-1]
    def pct(key, a, b):  # noqa: E306
        return round((b[key] - a[key]) / a[key] * 100, 1) if a.get(key) and b.get(key) else None
    worst = min((p for p in probes if p.get("decode_tps")), key=lambda p: p["decode_tps"], default=None)
    memory = {}
    for h in hosts:
        a, b = (first.get("memory") or {}).get(h, {}), (last.get("memory") or {}).get(h, {})
        if a.get("mem_mb") is not None and b.get("mem_mb") is not None:
            memory[h] = {"first_mb": a["mem_mb"], "last_mb": b["mem_mb"], "growth_mb": round(b["mem_mb"] - a["mem_mb"], 1), "fds_first": a.get("fds"), "fds_last": b.get("fds")}
    canary_bad = sum(1 for p in probes if p.get("canary_sha") and first.get("canary_sha") and p["canary_sha"] != first["canary_sha"])
    probe_errs = [e for p in probes for e in p.get("errors", [])]
    return {"ok": not probe_errs and canary_bad == 0 and st["err"] == 0, "minutes": round((time.time() - t0) / 60, 1), "probes": probes,
            "drift": {"decode_pct": pct("decode_tps", first, last), "prefill_pct": pct("prefill_tps", first, last), "aggregate_pct": pct("aggregate_tps", first, last),
                      "worst_decode_pct": pct("decode_tps", first, worst) if worst else None, "worst_at_minute": worst["minute"] if worst else None},
            "memory": memory, "canary_bad": canary_bad, "load": st, "errors": (probe_errs + errs)[:10]}


SUITES = {"soak": soak, "fault": fault, "concurrency": concurrency, "endurance": endurance}
