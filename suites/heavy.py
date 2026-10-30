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


SUITES = {"soak": soak, "fault": fault}
