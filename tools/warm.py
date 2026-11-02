#!/usr/bin/env python3
"""Phase 11 exit criteria on a large project: warm start and warm-up.

    tools/external.sh && python3 tools/warm.py

Against tools/external/marten (or SOAK_ROOT) with bin/clear-ls (or
CLEAR_LS_BIN), using a temp global cache dir and the project's
.clear-ls/cache (cleared first). Reports:
- start time to the first answer: cold (no cache), then warm;
- references cold (no warm-up), warm (repeated), and first search after
  the background warm-up, with how long the warm-up took and memory (RSS; physical footprint on macOS).
Prints `EXIT ok|FAIL` lines.
"""
import os, re, shutil, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lsp_client import Client, pos, REPO

root = os.environ.get("SOAK_ROOT", os.path.join(REPO, "tools/external/marten"))
if not os.path.isdir(root):
    sys.exit(f"{root} missing: run tools/external.sh")
cache = tempfile.mkdtemp(prefix="clear-ls-warm-")
os.environ["CLEAR_LS_CACHE_DIR"] = cache
shutil.rmtree(os.path.join(root, ".clear-ls"), ignore_errors=True)
req_file = os.path.join(root, "src/marten/http/request.cr")
text = open(req_file).read()
ln, ch = pos(text, "def method", 4)
params = {**Client.at(req_file, ln, ch), "context": {"includeDeclaration": True}}
results = {}


def start(warmup):
    t = time.time()
    c = Client(root, init_options={"warmup": {"enabled": warmup}})
    c.request("workspace/symbol", {"query": "Request"}, timeout=300)
    return c, (time.time() - t) * 1000


def refs(c):
    t = time.time()
    r = c.request("textDocument/references", params, timeout=600)
    return (time.time() - t) * 1000, len(r) if isinstance(r, list) else r


c, ms = start(False)
print(f"start cold (writes cache): {ms:.0f}ms to first answer")
cold, n = refs(c)
warm, _ = refs(c)
print(f"references Request#method without warm-up: cold {cold:.0f}ms, warm {warm:.0f}ms ({n})")
c.close()

starts = []
for _ in range(3):
    c, ms = start(False)
    starts.append(ms)
    c.close()
print(f"start warm: {', '.join(f'{m:.0f}' for m in starts)}ms to first answer")
results["start"] = min(starts)

c, _ = start(True)
t = time.time()
# The warm-up runs while idle; poll its log line through memory growth
# settling: wait until memory is stable for 2 s (no hover requests: they
# would delay it).
last, stable = -1, 0
while time.time() - t < 300 and stable < 4:
    time.sleep(0.5)
    mem = c.mem_mb()
    stable = stable + 1 if mem == last else 0
    last = mem
wait_s = time.time() - t - 2
after, _ = refs(c)
again, _ = refs(c)
print(f"warm-up settled after ~{wait_s:.1f}s, {c.mem_text()}; references after warm-up {after:.0f}ms, again {again:.0f}ms")
results["after"] = after
results["warm"] = max(warm, again)
c.close()
shutil.rmtree(cache, ignore_errors=True)

print(f"EXIT {'ok' if results['start'] < 300 else 'FAIL'} warm start < 300ms ({results['start']:.0f}ms)")
ok = results["after"] <= max(2 * results["warm"], results["warm"] + 50)
print(f"EXIT {'ok' if ok else 'FAIL'} first references after warm-up ~ warm ({results['after']:.0f}ms vs {results['warm']:.0f}ms)")
