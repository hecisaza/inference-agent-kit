"""Shared helpers for pairtest suites: an OpenAI-compatible client with streaming timings, and prompt builders.

A result is a dict. It has "error" when the request did not produce a complete, valid reply (HTTP error, transport
error, invalid JSON, a stream that ended without [DONE], a missing choice); suites treat any result with "error" as a
failure and never compare its "sha" (there is none)."""
import hashlib, json, random, time, urllib.request, urllib.error

WORDS = "the of and to in is that for it as with was on be by at this from or an river stone light market window garden".split()


def words(n, seed):
    r = random.Random(seed)
    return " ".join(r.choice(WORDS) for _ in range(n))


def sha(text):
    return hashlib.sha256((text or "").encode()).hexdigest()[:12]


def chat(api, model, messages, max_tokens=64, temperature=0, thinking=False, stream=False, timeout=1800, extra=None):
    """One request. Returns dict(content, reasoning_chars, prompt_tokens, cached, completion_tokens, ttft, total, sha)
    or dict(error, total, …) when the reply is not complete and valid."""
    body = {"model": model, "messages": messages, "max_tokens": max_tokens, "temperature": temperature,
            "chat_template_kwargs": {"thinking": thinking, "enable_thinking": thinking}}
    if stream:
        body.update(stream=True, stream_options={"include_usage": True})
    body.update(extra or {})
    req = urllib.request.Request(api.rstrip("/") + "/chat/completions", json.dumps(body).encode(), {"Content-Type": "application/json"})
    t0 = time.time(); out = {"content": "", "reasoning_chars": 0, "ttft": None}
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            if not stream:
                o = json.load(r); ch = o.get("choices") or []
                if not ch or "message" not in ch[0]:
                    return {**out, "error": "no choices in the reply", "total": round(time.time() - t0, 2)}
                m = ch[0]["message"]; u = o.get("usage") or {}
                out.update(content=m.get("content") or "", reasoning_chars=len(m.get("reasoning_content") or ""), finish=ch[0].get("finish_reason"))
            else:
                u = {}; done = False
                for line in r:
                    if not line.startswith(b"data: "):
                        continue
                    if line.strip() == b"data: [DONE]":
                        done = True; break
                    o = json.loads(line[6:])
                    u = o.get("usage") or u
                    for c in o.get("choices", []):
                        d = c.get("delta", {})
                        if d.get("content"):
                            out["ttft"] = out["ttft"] or round(time.time() - t0, 3)
                            out["content"] += d["content"]
                        if d.get("reasoning_content"):
                            out["reasoning_chars"] += len(d["reasoning_content"])
                if not done:
                    return {**out, "error": "stream ended without [DONE]", "total": round(time.time() - t0, 2)}
    except urllib.error.HTTPError as e:
        return {**out, "error": f"HTTP {e.code}: {e.read()[:200].decode(errors='ignore')}", "total": round(time.time() - t0, 2)}
    except (urllib.error.URLError, json.JSONDecodeError, TimeoutError, OSError, ValueError) as e:
        return {**out, "error": f"{type(e).__name__}: {e}"[:200], "total": round(time.time() - t0, 2)}
    out.update(prompt_tokens=u.get("prompt_tokens"), completion_tokens=u.get("completion_tokens"),
               cached=(u.get("prompt_tokens_details") or {}).get("cached_tokens"), total=round(time.time() - t0, 2), sha=sha(out["content"]))
    return out


def ready(api, limit=1800):
    t0 = time.time()
    while time.time() - t0 < limit:
        try:
            urllib.request.urlopen(api.rstrip("/") + "/models", timeout=5)
            return round(time.time() - t0)
        except (urllib.error.URLError, OSError, ValueError):
            time.sleep(5)
    raise RuntimeError(f"{api} not ready after {limit} s")
