#!/usr/bin/env python3
"""Responsiveness and memory under load on a large project (Phase 10
baseline and exit criteria).

    tools/external.sh && python3 tools/soak.py [--specs N] [--searches N]

Against tools/external/marten (or SOAK_ROOT), with bin/clear-ls (or
CLEAR_LS_BIN). Reports:
- index time and RSS;
- RSS after opening N spec files (one hover each);
- references cold/warm on a few methods and types;
- hover latency while a long references search runs (p50/p99), and
  whether $/cancelRequest ends that search early;
- RSS after the searches.
Prints `EXIT ok|FAIL <criterion>` lines for the Phase 10 exit criteria.
"""
import argparse, glob, os, sys, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lsp_client import Client, pos, percentile, REPO

ap = argparse.ArgumentParser()
ap.add_argument("--specs", type=int, default=100)
ap.add_argument("--searches", type=int, default=10)
args = ap.parse_args()
root = os.environ.get("SOAK_ROOT", os.path.join(REPO, "tools/external/marten"))
if not os.path.isdir(root):
    sys.exit(f"{root} missing: run tools/external.sh")

results = {}
t0 = time.time()
c = Client(root)
req_file = os.path.join(root, "src/marten/http/request.cr")
text = c.open(req_file)
c.request("textDocument/documentSymbol", {"textDocument": {"uri": "file://" + req_file}}, timeout=300)
print(f"index: {(time.time() - t0) * 1000:.0f}ms, RSS {c.rss_mb()} MB")

specs = sorted(glob.glob(os.path.join(root, "spec/marten/**/*_spec.cr"), recursive=True))
t = time.time()
for s in specs[:args.specs]:
    c.open(s)
    c.request("textDocument/hover", c.at(s, 2, 2), timeout=300)
per = (time.time() - t) * 1000 / max(1, min(args.specs, len(specs)))
print(f"opened {min(args.specs, len(specs))} specs: {per:.0f}ms each, RSS {c.rss_mb()} MB")

targets = [("def method", 4, "Request#method"), ("def headers", 4, "Request#headers"),
           ("class Request", 6, "Request (type)"), ("def host", 4, "Request#host")]
longest = None
for i in range(args.searches):
    needle, shift, label = targets[i % len(targets)]
    if needle not in text:
        continue
    ln, ch = pos(text, needle, shift)
    params = {**c.at(req_file, ln, ch), "context": {"includeDeclaration": True}}
    t = time.time()
    r = c.request("textDocument/references", params, timeout=600)
    ms = (time.time() - t) * 1000
    n = len(r) if isinstance(r, list) else r.get("message", "?")
    print(f"references {label:16} {'cold' if i < len(targets) else 'warm'}: {ms:7.0f}ms  {n}")
    if longest is None or ms > longest[0]:
        longest = (ms, params, label)
print(f"after {args.searches} searches: RSS {c.rss_mb()} MB")
results["rss"] = c.rss_mb()
c.close()

# Hover during a long search, on a fresh server (cold search, the worst
# case), then cancellation.
c = Client(root)
c.open(req_file)
c.request("textDocument/documentSymbol", {"textDocument": {"uri": "file://" + req_file}}, timeout=300)
for s in specs[:args.specs]:
    c.open(s)
_, params, label = longest
lat = []
rid = c.send_request("textDocument/references", params)
start = time.time()
done = False
while not done and time.time() - start < 60:
    t = time.time()
    hid = c.send_request("textDocument/hover", c.at(req_file, 10, 6))
    c.wait(hid, timeout=120)
    lat.append((time.time() - t) * 1000)
    with c.cond:
        done = rid in c.responses
    time.sleep(0.05)
c.wait(rid, timeout=600)
search_ms = (time.time() - start) * 1000
print(f"hover during references {label} ({search_ms:.0f}ms, {len(lat)} hovers): p50 {percentile(lat, 50):.0f}ms p99 {percentile(lat, 99):.0f}ms max {max(lat):.0f}ms")
results["hover_p99"] = percentile(lat, 99)

rid = c.send_request("textDocument/references", {**params, "position": {"line": params["position"]["line"], "character": params["position"]["character"]}})
time.sleep(0.05)
t = time.time()
c.notify("$/cancelRequest", {"id": rid})
msg, at = c.wait(rid, timeout=600)
cancel_ms = (at - t) * 1000
code = msg.get("error", {}).get("code")
print(f"cancel: answered {cancel_ms:.0f}ms after $/cancelRequest, {'RequestCancelled' if code == -32800 else 'error ' + str(code) if code else 'full result'}")
results["cancelled"] = code == -32800
c.close()

print(f"EXIT {'ok' if results['hover_p99'] < 100 else 'FAIL'} hover p99 during search < 100ms ({results['hover_p99']:.0f}ms)")
print(f"EXIT {'ok' if results['rss'] < 400 else 'FAIL'} RSS after {args.specs} specs + {args.searches} searches < 400 MB ({results['rss']} MB)")
print(f"EXIT {'ok' if results['cancelled'] else 'FAIL'} $/cancelRequest answers RequestCancelled")
