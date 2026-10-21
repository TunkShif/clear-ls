#!/usr/bin/env python3
"""Compares two `bin/probes/types_dump` outputs (before, after).

    python3 tools/types_diff.py before.txt after.txt [N]

Prints counts of locals that became unknown (regressions), became known
(improvements), or changed type, and the first N regressions (default 30).
Lines are `file:line name type`; `?` is unknown.
"""
import sys

def load(path):
    d = {}
    for l in open(path):
        if "INFO" in l:
            continue
        parts = l.rstrip("\n").split(" ", 2)
        if len(parts) < 3:
            continue
        d[(parts[0], parts[1])] = parts[2]
    return d

a, b = load(sys.argv[1]), load(sys.argv[2])
limit = int(sys.argv[3]) if len(sys.argv) > 3 else 30
common = [k for k in a if k in b]
reg = [(k, a[k], b[k]) for k in common if a[k] != "?" and b[k] == "?"]
imp = [(k, a[k], b[k]) for k in common if a[k] == "?" and b[k] != "?"]
chg = [(k, a[k], b[k]) for k in common if a[k] != "?" and b[k] != "?" and a[k] != b[k]]
print(f"unknown {sum(v == '?' for v in b.values())}/{len(b)}  regressed {len(reg)}  improved {len(imp)}  changed {len(chg)}")
for r in reg[:limit]:
    print("  REG", r)
for c in chg[:limit]:
    print("  CHG", c)
