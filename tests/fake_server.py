#!/usr/bin/env python3
"""A tiny OpenAI-compatible server for the kit's self-test: deterministic replies, streaming, usage. Not a model.
Usage: fake_server.py PORT  (serves /v1/models and /v1/chat/completions; replies depend only on the last user text)."""
import hashlib, json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer


def reply(text):
    t = text.lower()
    if "17*23" in t.replace(" ", "") or "17 times 23" in t:
        return "391"
    if "colour" in t or "color" in t:
        return "red, green, blue"
    return "ok " + hashlib.sha256(text.encode()).hexdigest()[:8]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        body = json.dumps({"object": "list", "data": [{"id": "fake-model", "object": "model"}]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); req = json.loads(self.rfile.read(n) or b"{}")
        text = next((m["content"] for m in reversed(req.get("messages", [])) if m.get("role") == "user"), "")
        text = text if isinstance(text, str) else json.dumps(text)
        out = reply(text); ptoks = max(1, len(text.split())); usage = {"prompt_tokens": ptoks, "completion_tokens": len(out.split()), "total_tokens": ptoks + 1}
        if req.get("stream"):
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
            for w in out.split(" "):
                self.wfile.write(b"data: " + json.dumps({"choices": [{"delta": {"content": w + ("" if w == out.split(" ")[-1] else " ")}}]}).encode() + b"\n\n"); self.wfile.flush(); time.sleep(0.01)
            self.wfile.write(b"data: " + json.dumps({"choices": [], "usage": usage}).encode() + b"\n\ndata: [DONE]\n\n")
        else:
            body = json.dumps({"choices": [{"message": {"role": "assistant", "content": out}, "finish_reason": "stop"}], "usage": usage}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)


HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
