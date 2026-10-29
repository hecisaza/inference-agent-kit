# score.py A B: automatic grading of out-A.jsonl and out-B.jsonl, plus blind-A-B.json, a shuffled side-by-side of the
# open-ended answers to judge before looking at the key. Read every failed item before reporting a score: graders are strict.
import sys, json, re, subprocess, tempfile, os, random
A, B = sys.argv[1], sys.argv[2]
def load(l): return {r["id"]: r for r in map(json.loads, open(f"out-{l}.jsonl"))}
RA, RB = load(A), load(B)

def args(r, name):
    for c in r.get("tool_calls") or []:
        if c["name"] == name:
            try: return json.loads(c["arguments"])
            except Exception: return {}
    return None
def text(r): return (r.get("content") or "").strip()
def code(r):
    m = re.findall(r"```(?:python)?\n(.*?)```", text(r), re.S)
    return max(m, key=len) if m else text(r)
def runpy(src, tests):
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "t.py"); open(p, "w").write(src + "\n\n" + tests + "\nprint('ALLOK')\n")
        try: o = subprocess.run(["python3", "-I", p], capture_output=True, text=True, timeout=20, cwd=d)
        except subprocess.TimeoutExpired: return False
        return "ALLOK" in o.stdout
IFACES = """Interface              IP-Address      OK? Method Status                Protocol
GigabitEthernet0/0     10.0.0.1        YES manual up                    up
GigabitEthernet0/1     unassigned      YES unset  administratively down down
GigabitEthernet0/2     10.0.2.1        YES manual up                    down
Loopback0              1.1.1.1         YES manual up                    up
Vlan10                 10.10.0.1       YES manual down                  down"""
TESTS = {
 "code_intervals": "assert merge_intervals([[1,3],[2,6],[8,10],[15,18]])==[[1,6],[8,10],[15,18]]\nassert merge_intervals([[1,4],[4,5]])==[[1,5]]\nassert merge_intervals([])==[]\nassert merge_intervals([[5,6],[1,2]])==[[1,2],[5,6]]\nassert merge_intervals([[1,10],[2,3]])==[[1,10]]",
 "code_ifaces": f"T={IFACES!r}\nassert parse_up_interfaces(T)==['GigabitEthernet0/0','Loopback0'], parse_up_interfaces(T)",
 "code_cidr": "assert summarize(['10.0.0.0/24','10.0.1.0/24'])==['10.0.0.0/23']\nassert summarize(['192.168.1.0/25','192.168.1.128/25','192.168.1.0/26'])==['192.168.1.0/24']\nassert summarize(['10.0.2.0/24','10.0.0.0/24'])==['10.0.0.0/24','10.0.2.0/24']",
 "code_bugfix": "assert top_k(['b','a','b','c','a','b'],2)==['b','a']\nassert top_k(['x','y','z'],2)==['x','y']\nassert top_k(['a','b','b','a','c'],2)==['a','b']",
}
def g(id, r):
    t = text(r); low = t.lower()
    if r.get("error"): return 0, "error: " + r["error"][:80]
    if id == "tool_netbox":
        a = args(r, "netbox_get_devices"); return (1, "ok") if a and a.get("site") == "lab-east" and a.get("role") == "leaf" else (0, f"args {a}")
    if id == "tool_splunk":
        a = args(r, "splunk_search"); q = (a or {}).get("query", "").lower()
        # an SSH auth-failure search: sshd / ssh named, or the Linux auth log sourcetype that carries them
        ok = a is not None and re.search(r"ssh|linux_secure|auth", q) and re.search(r"fail", q) and "24h" in str((a or {}).get("earliest", "")) + q
        return (1, "ok") if ok else (0, f"args {a}")
    if id == "tool_array":
        a = args(r, "add_tags"); return (1, "ok") if a and a.get("doc_id") == 42 and set(a.get("tags", [])) == {"urgent", "finance", "q3"} else (0, f"args {a}")
    if id == "tool_none": return (1, "ok") if not r.get("tool_calls") and "lisbon" in low else (0, "called a tool or wrong")
    if id == "tool_es":
        a = args(r, "create_event"); return (1, "ok") if a and a.get("date") == "2026-11-03" and a.get("time") == "15:30" and "revisi" in a.get("title", "").lower() else (0, f"args {a}")
    if id == "tool_followup": return (1, "ok") if not r.get("tool_calls") and "84" in t and "thunder" in low else (0, "missed the tool result")
    if id == "tool_email":
        a = args(r, "send_email") or {}; b = a.get("body", "").lower()
        return (1, "ok") if a.get("to") == "bob@example.com" and "maint" in a.get("subject", "").lower() and "friday" in b and "10" in b else (0, f"args {str(a)[:80]}")
    if id in TESTS: return (1, "tests pass") if runpy(code(r), TESTS[id]) else (0, "tests fail")
    if id == "net_subnet": return (1, "ok") if all(s in t.replace(" ", "") for s in ("network=10.20.30.64", "broadcast=10.20.30.95", "hosts=30")) else (0, t[:60])
    if id == "net_srl":
        ok = re.search(r"interface ethernet-1/1 subinterface 0 ipv4 (admin-state enable )?address 192\.0\.2\.1/31", t) and re.search(r"network-instance default interface ethernet-1/1\.0", t)
        return (1, "ok") if ok else (0, "missing the address or the network-instance binding")
    if id == "net_bgp": return (1, "names local preference") if re.search(r"local[ _-]?pref", low) else (0, "no LOCAL_PREF")
    if id == "net_netbox":
        ok = "/api/dcim/devices/" in t and "site=lab-east" in t and "status=active" in t and re.search(r"Authorization: Token \$\{?NB_TOKEN", t)
        return (1, "ok") if ok else (0, "missing path/filter/status/token")
    if id == "math_trains": return (1, "ok") if "14:35" in t else (0, t[:40])
    if id == "math_mod": return (1, "ok") if re.fullmatch(r"\**12\**\.?", t) else (0, t[:40])
    if id == "math_logic":  # the answer is Ben; an explanation after it is a format slip, noted, not a wrong answer
        first = re.sub(r"[*_.]", "", t.split()[0]) if t else ""
        return (1, "ok" if re.fullmatch(r"\**Ben\**\.?", t) else "ok (added an explanation)") if first == "Ben" else (0, t[:40])
    if id == "fmt_json":
        try: return (1, "ok") if json.loads(t) == {"hostname": "core-sw1", "vlans": [10, 20, 30], "enabled": True} else (0, "wrong values")
        except Exception: return 0, "not bare JSON"
    if id == "fmt_words": n = len(re.findall(r"[\w'’-]+", t)); return (1, "12 words") if n == 12 else (0, f"{n} words")
    if id == "fmt_exact": return (1, "ok") if t == "READY" else (0, repr(t[:20]))
    if id == "long_60k": return (1, "found") if "VX-4417-QR" in t else (0, t[:30])
    if id == "long_200k": return (1, "found") if "KM-9062-ZT" in t else (0, t[:30])
    if id == "sum_incident": n = len([l for l in t.splitlines() if re.match(r"[-*•] ", l)]); return (1, "3 bullets") if n == 3 else (0, f"{n} bullets")
    if id in ("es_explain", "es_email"):
        es = sum(w in low for w in (" el ", " la ", " que ", " para ", " de ", " es ")); return (1, "in Spanish") if es >= 3 else (0, "not Spanish")
    return None, "judge"

rows = []; tot = {A: [0, 0], B: [0, 0]}; cats = {}
for id in RA:
    ga, na = g(id, RA[id]); gb, nb = g(id, RB.get(id, {"error": "missing"}))
    cat = RA[id]["cat"]
    for L, s in ((A, ga), (B, gb)):
        if s is not None:
            tot[L][0] += s; tot[L][1] += 1; cats.setdefault(cat, {A: [0, 0], B: [0, 0]})[L][0] += s; cats[cat][L][1] += 1
    rows.append((id, cat, ga, na, RA[id].get("s"), gb, nb, RB.get(id, {}).get("s")))
print(f"{'id':16} {'cat':8} {A:>5} {'':28} {'s':>6} | {B:>5} {'':28} {'s':>6}")
for id, cat, ga, na, sa, gb, nb, sb in rows: print(f"{id:16} {cat:8} {str(ga):>5} {na[:28]:28} {sa!s:>6} | {str(gb):>5} {nb[:28]:28} {sb!s:>6}")
print("\nby category:", {c: {L: f"{v[0]}/{v[1]}" for L, v in d.items()} for c, d in cats.items()})
print("TOTAL", {L: f"{v[0]}/{v[1]}" for L, v in tot.items()})
for L, R in ((A, RA), (B, RB)):
    s = [R[i]["s"] for i in R if R[i].get("s") and not i.startswith("long")]; print(L, "median latency (short prompts) %.2f s, long: %s" % (sorted(s)[len(s)//2], [R[i].get("s") for i in R if i.startswith("long")]))
# blind side-by-side for the open-ended items
random.seed(7); out = []
for id in ("net_bgp", "net_srl", "es_explain", "es_email", "sum_incident", "tool_followup", "code_bugfix"):
    pair = [(A, RA[id]), (B, RB.get(id, {}))]; random.shuffle(pair)
    out.append({"id": id, "X": text(pair[0][1]), "Y": text(pair[1][1]), "key": {"X": pair[0][0], "Y": pair[1][0]}})
json.dump(out, open(f"blind-{A}-{B}.json", "w"), ensure_ascii=False, indent=1)
