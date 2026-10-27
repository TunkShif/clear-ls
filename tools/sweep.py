#!/usr/bin/env python3
"""Random-position request sweep: internal errors, timeouts, slow answers.

    tools/external.sh && python3 tools/sweep.py [--seconds S] [--per-file N]

Opens files of tools/external/marten/src (or SWEEP_ROOT) in a random but
seeded order and sends hover, definition, completion, signature help,
highlights, prepareRename, implementation and prepareCallHierarchy at N
random identifier positions per file, until S seconds have passed.
Internal errors (-32603) and timeouts are listed with a location;
answers over 300 ms are counted per method. Exit status 1 on any
internal error or timeout.
"""
import argparse, glob, os, random, re, sys, time
from collections import Counter
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lsp_client import Client, percentile, REPO

ap = argparse.ArgumentParser()
ap.add_argument("--seconds", type=int, default=150)
ap.add_argument("--per-file", type=int, default=15)
ap.add_argument("--seed", type=int, default=7)
args = ap.parse_args()
root = os.environ.get("SWEEP_ROOT", os.path.join(REPO, "tools/external/marten"))
if not os.path.isdir(root):
    sys.exit(f"{root} missing: run tools/external.sh")

METHODS = ["hover", "definition", "completion", "signatureHelp", "documentHighlight",
           "prepareRename", "implementation", "prepareCallHierarchy"]
BUDGET_MS = 300
random.seed(args.seed)
c = Client(root)
files = sorted(glob.glob(os.path.join(root, "src/**/*.cr"), recursive=True))
random.shuffle(files)
errors, timeouts, slow = [], [], []
lat = {m: [] for m in METHODS}
n = 0
nfiles = 0
deadline = time.time() + args.seconds
for f in files:
    if time.time() > deadline:
        break
    nfiles += 1
    text = c.open(f)
    lines = text.split("\n")
    words = [(i, m.start()) for i, l in enumerate(lines) for m in re.finditer(r"[A-Za-z_@]\w*", l)]
    for ln, ch in random.sample(words, min(args.per_file, len(words))):
        for m in METHODS:
            n += 1
            where = f"{m} {os.path.relpath(f, root)}:{ln + 1}:{ch}"
            t = time.time()
            try:
                r = c.request("textDocument/" + m, c.at(f, ln, ch), timeout=30)
            except TimeoutError:
                timeouts.append(where)
                c.close()
                c = Client(root)
                c.open(f)
                continue
            ms = (time.time() - t) * 1000
            lat[m].append(ms)
            if isinstance(r, dict) and r.get("code") == -32603:
                errors.append(f"{where}: {r.get('message', '')[:100]}")
            if ms > BUDGET_MS:
                slow.append((ms, where))
c.close()

print(f"{n} requests over {nfiles} files")
for m in METHODS:
    print(f"  {m:22} p50 {percentile(lat[m], 50):6.1f}ms  p99 {percentile(lat[m], 99):7.1f}ms  max {max(lat[m] or [0]):7.0f}ms")
print(f"internal errors: {len(errors)}")
for e in errors[:20]:
    print("  " + e)
print(f"timeouts: {len(timeouts)}")
for e in timeouts[:20]:
    print("  " + e)
print(f"over {BUDGET_MS}ms: {len(slow)} {dict(Counter(w.split()[0] for _, w in slow))}")
for ms, w in sorted(slow, reverse=True)[:8]:
    print(f"  {ms:6.0f}ms {w}")
sys.exit(1 if errors or timeouts else 0)
