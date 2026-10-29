# eval.py LABEL BASE_URL MODEL [--think]: the 26-prompt agent set (tools, code, network, maths, formats, Spanish, long
# context, summary) against an OpenAI-compatible server; writes out-LABEL.jsonl. Greedy. --think: thinking on at the
# engine's highest effort with room to reason (or set THINK=1). Grade two runs with score.py A B.
import sys, json, time, random, urllib.request, urllib.error
LABEL, BASE, MODEL = sys.argv[1], sys.argv[2].rstrip("/"), sys.argv[3]
URL = BASE + "/chat/completions"
import os; THINK = os.environ.get("THINK") == "1" or "--think" in sys.argv

def fn(name, desc, props, req):
    return {"type": "function", "function": {"name": name, "description": desc,
            "parameters": {"type": "object", "properties": props, "required": req}}}

T_WEATHER = fn("get_weather", "Current weather for a city", {"city": {"type": "string"}}, ["city"])
T_NETBOX = fn("netbox_get_devices", "List devices from NetBox, optionally filtered by site or role",
              {"site": {"type": "string"}, "role": {"type": "string"}}, [])
T_SPLUNK = fn("splunk_search", "Run a Splunk SPL search over a time range",
              {"query": {"type": "string"}, "earliest": {"type": "string", "description": "e.g. -24h"}}, ["query"])
T_EMAIL = fn("send_email", "Send an email", {"to": {"type": "string"}, "subject": {"type": "string"}, "body": {"type": "string"}}, ["to", "subject", "body"])
T_TAGS = fn("add_tags", "Add tags to a document", {"doc_id": {"type": "integer"}, "tags": {"type": "array", "items": {"type": "string"}}}, ["doc_id", "tags"])
T_CAL = fn("create_event", "Create a calendar event", {"title": {"type": "string"}, "date": {"type": "string", "description": "YYYY-MM-DD"}, "time": {"type": "string", "description": "HH:MM 24h"}}, ["title", "date", "time"])
ALL = [T_WEATHER, T_NETBOX, T_SPLUNK, T_EMAIL, T_TAGS, T_CAL]

def words(n, seed):
    r = random.Random(seed); W = "the of and to in is that for it as with was on be by at this from or an river stone light market window garden".split()
    return " ".join(r.choice(W) for _ in range(n))

def needle(nwords, seed, code, depth):
    hay = words(nwords, seed).split(); at = int(len(hay) * depth)
    hay.insert(at, f"The secret access code for the vault is {code}.")
    return " ".join(hay) + "\n\nWhat is the secret access code for the vault? Reply with the code only."

CODE_HDR = "Write only a Python code block (```python ... ```) with the function; no explanation."
CASES = [
  # --- tools
  dict(id="tool_netbox", cat="tools", tools=ALL, msgs=[{"role": "user", "content": "Which devices do we have at the site 'lab-east' with role 'leaf'? Use the tools."}]),
  dict(id="tool_splunk", cat="tools", tools=ALL, msgs=[{"role": "user", "content": "Search Splunk for failed SSH logins over the last 24 hours."}]),
  dict(id="tool_array", cat="tools", tools=ALL, msgs=[{"role": "user", "content": "Tag document 42 with urgent, finance and q3."}]),
  dict(id="tool_none", cat="tools", tools=ALL, msgs=[{"role": "user", "content": "What is the capital of Portugal? Answer in one word."}]),
  dict(id="tool_es", cat="tools", tools=ALL, msgs=[{"role": "user", "content": "Agéndame una reunión llamada 'Revisión de red' el 2026-11-03 a las 15:30."}]),
  dict(id="tool_followup", cat="tools", tools=ALL, msgs=[
      {"role": "user", "content": "What's the weather in Miami?"},
      {"role": "assistant", "content": "", "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "get_weather", "arguments": "{\"city\": \"Miami\"}"}}]},
      {"role": "tool", "tool_call_id": "c1", "content": "{\"city\": \"Miami\", \"temp_f\": 84, \"conditions\": \"thunderstorms after 3 PM\"}"}]),
  dict(id="tool_email", cat="tools", tools=ALL, msgs=[{"role": "user", "content": "Email bob@example.com with subject 'Maintenance' telling him the switch upgrade is moved to Friday 10 PM."}]),
  # --- coding (graded by running hidden tests)
  dict(id="code_intervals", cat="code", msgs=[{"role": "user", "content": "Implement merge_intervals(intervals: list[list[int]]) -> list[list[int]] that merges overlapping or touching closed intervals and returns them sorted. " + CODE_HDR}]),
  dict(id="code_ifaces", cat="code", msgs=[{"role": "user", "content": "Implement parse_up_interfaces(text: str) -> list[str]: given the output of a Cisco-style 'show ip interface brief' (header line first, columns Interface IP-Address OK? Method Status Protocol, where Status may be 'administratively down'), return the names of interfaces whose Status is 'up' and Protocol is 'up', in order. " + CODE_HDR}]),
  dict(id="code_cidr", cat="code", msgs=[{"role": "user", "content": "Implement summarize(cidrs: list[str]) -> list[str] that collapses a list of IPv4 CIDR strings into the minimal list of CIDRs covering exactly the same addresses, sorted by network address. You may use the ipaddress module. " + CODE_HDR}]),
  dict(id="code_bugfix", cat="code", msgs=[{"role": "user", "content": "This function should return the k most frequent words (ties broken alphabetically), but it is wrong. Fix it.\n```python\ndef top_k(words, k):\n    counts = {}\n    for w in words:\n        counts[w] = counts.get(w, 0) + 1\n    return sorted(counts, key=lambda w: counts[w])[:k]\n```\n" + CODE_HDR}]),
  # --- network engineering
  dict(id="net_subnet", cat="net", msgs=[{"role": "user", "content": "For 10.20.30.77/27 give the network address, broadcast address and number of usable hosts, as three lines: network=..., broadcast=..., hosts=..."}]),
  dict(id="net_srl", cat="net", msgs=[{"role": "user", "content": "Give the Nokia SR Linux CLI commands (flat 'set' style) to configure interface ethernet-1/1 subinterface 0 with IPv4 address 192.0.2.1/31 and attach it to network-instance default."}]),
  dict(id="net_bgp", cat="net", msgs=[{"role": "user", "content": "In two or three sentences: why does a BGP route with a shorter AS_PATH lose to one with a longer AS_PATH in some networks? Name the attribute evaluated before AS_PATH."}]),
  dict(id="net_netbox", cat="net", msgs=[{"role": "user", "content": "Write a curl command that lists all active devices at site slug 'lab-east' using the NetBox REST API with a token in $NB_TOKEN, against https://netbox.example.com."}]),
  # --- reasoning / maths
  dict(id="math_trains", cat="math", msgs=[{"role": "user", "content": "A train leaves at 09:40 and travels 270 km at 90 km/h, waits 25 minutes, then travels 150 km at 100 km/h. At what time does it arrive? Answer HH:MM only."}]),
  dict(id="math_mod", cat="math", msgs=[{"role": "user", "content": "What is 7^222 mod 13? Answer with the number only."}]),
  dict(id="math_logic", cat="math", msgs=[{"role": "user", "content": "Ana is older than Ben. Carla is younger than Ben. Dan is older than Ana. Who is the second youngest? Answer with the name only."}]),
  # --- strict formats
  dict(id="fmt_json", cat="format", msgs=[{"role": "user", "content": "Return ONLY a JSON object (no code fence, no prose) with keys \"hostname\" (string), \"vlans\" (array of integers) and \"enabled\" (boolean), describing a switch named core-sw1 with VLANs 10, 20 and 30 that is enabled."}]),
  dict(id="fmt_words", cat="format", msgs=[{"role": "user", "content": "Describe what a VLAN is in exactly 12 words. Output only those 12 words."}]),
  dict(id="fmt_exact", cat="format", msgs=[{"role": "user", "content": "Reply with exactly the text READY and nothing else."}]),
  # --- Spanish
  dict(id="es_explain", cat="spanish", msgs=[{"role": "user", "content": "Explícame en español, en un párrafo corto, qué es un túnel VXLAN y para qué sirve."}]),
  dict(id="es_email", cat="spanish", msgs=[{"role": "user", "content": "Escribe un correo breve y cordial en español para avisar a mi equipo que el mantenimiento de red del sábado se pospone una semana."}]),
  # --- long context
  dict(id="long_60k", cat="long", max_tokens=24, msgs=[{"role": "user", "content": needle(52000, 601, "VX-4417-QR", 0.37)}]),
  dict(id="long_200k", cat="long", max_tokens=24, msgs=[{"role": "user", "content": needle(175000, 2002, "KM-9062-ZT", 0.71)}]),
  # --- summarisation
  dict(id="sum_incident", cat="summary", msgs=[{"role": "user", "content": "Summarise this incident for a manager in 3 bullet points:\n\n02:14 BGP session to transit-A dropped on edge-1 (hold timer expired). 02:15 traffic failed over to transit-B, latency to EU rose from 38 ms to 95 ms. 02:31 NOC found transit-A had a fibre cut at their POP. 03:50 transit-A restored; session re-established 03:52; traffic shifted back 03:55. No packet loss beyond 40 s during failover. Action items: add BFD to transit sessions to cut detection from 90 s to under 1 s; review whether transit-B capacity alarms fired (they did not)."}]),
]

def call(case):
    if THINK:  # thinking on, the engines' highest effort; room for the reasoning before the answer
        body = {"model": MODEL, "messages": case["msgs"], "max_tokens": 4096 if case["cat"] == "long" else 16384, "temperature": 0,
                "reasoning_effort": "max", "chat_template_kwargs": {"thinking": True, "enable_thinking": True, "reasoning_effort": "max"}}
    else:
        body = {"model": MODEL, "messages": case["msgs"], "max_tokens": case.get("max_tokens", 1024), "temperature": 0,
                "chat_template_kwargs": {"thinking": False, "enable_thinking": False}}
    if case.get("tools"): body["tools"] = case["tools"]
    t = time.time()
    try:
        o = json.load(urllib.request.urlopen(urllib.request.Request(URL, json.dumps(body).encode(), {"Content-Type": "application/json"}), timeout=1800))
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.read()[:300].decode(errors='ignore')}", "s": round(time.time() - t, 2)}
    except Exception as e:
        return {"error": repr(e)[:300], "s": round(time.time() - t, 2)}
    ch = o["choices"][0]; m = ch["message"]; u = o.get("usage", {})
    return {"content": m.get("content") or "", "tool_calls": [{"name": c["function"]["name"], "arguments": c["function"]["arguments"]} for c in (m.get("tool_calls") or [])],
            "reasoning_chars": len(m.get("reasoning_content") or ""), "finish": ch.get("finish_reason"), "prompt_tokens": u.get("prompt_tokens"), "completion_tokens": u.get("completion_tokens"), "s": round(time.time() - t, 2)}

with open(f"out-{LABEL}.jsonl", "w") as f:
    for c in CASES:
        r = call(c); r.update(id=c["id"], cat=c["cat"], label=LABEL)
        f.write(json.dumps(r, ensure_ascii=False) + "\n"); f.flush()
        print(LABEL, c["id"], r.get("s"), "s", (r.get("error") or (r["content"][:70].replace("\n", " ") or str(r["tool_calls"])[:70])), flush=True)
print(LABEL, "EVAL DONE", flush=True)
