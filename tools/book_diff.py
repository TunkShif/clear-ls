#!/usr/bin/env python3
"""Compiler vs clear-ls types of `__t(expr)` markers in tools/fixtures/book.

    tools/book_diff.py [FILE...]     (default: every fixture except h.cr)

Needs `make bin/probes/type_marks`. Prints only disagreements, then a
per-file match count. The compiler may print several types for one line
(one per instantiation, or loop fixed-point steps); they are joined
with ` / `.

A marker line may carry `# cls: TYPE  reason` for an accepted deviation
(docs/book-gaps.md): clear-ls printing TYPE then counts as accepted, not
as a mismatch.
"""
import collections, os, re, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = os.path.join(ROOT, "tools", "fixtures", "book")
PROBE = os.path.join(ROOT, "bin", "probes", "type_marks")


def parse(text):
    d = collections.OrderedDict()
    for line in text.splitlines():
        m = re.match(r"@(\d+) (.*)", line.strip())
        if m:
            d.setdefault(int(m[1]), []).append(m[2])
    return d


files = sys.argv[1:] or sorted(
    os.path.join(FIX, "src", f) for f in os.listdir(os.path.join(FIX, "src")) if f.endswith(".cr") and f != "h.cr"
)
for path in files:
    path = os.path.abspath(path)
    comp = subprocess.run(["crystal", "build", "--no-codegen", path], cwd=FIX, capture_output=True, text=True)
    if comp.returncode != 0:
        print(f"### {os.path.basename(path)}: compile error\n{comp.stdout}{comp.stderr}")
        continue
    # The fixtures reuse class names across files and are compiled one at
    # a time: index each file alone (with the marker helpers).
    with tempfile.TemporaryDirectory() as tmp:
        os.mkdir(os.path.join(tmp, "src"))
        shutil.copy(os.path.join(FIX, "src", "h.cr"), os.path.join(tmp, "src", "h.cr"))
        alone = os.path.join(tmp, "src", os.path.basename(path))
        shutil.copy(path, alone)
        cls = subprocess.run([PROBE, tmp, alone], capture_output=True, text=True)
    c, s = parse(comp.stdout), parse(cls.stdout)
    src = open(path).read().split("\n")
    ok = bad = accepted = 0
    print(f"### {os.path.basename(path)}")
    for ln in sorted(set(c) | set(s)):
        cv = " / ".join(dict.fromkeys(c.get(ln, ["<not instantiated>"])))
        sv = " / ".join(s.get(ln, ["<none>"]))
        want = re.search(r"#\s*cls:\s*(.+?)(?:\s{2,}|$)", src[ln - 1])
        if cv == sv:
            ok += 1
        elif want and want[1].strip() == sv:
            accepted += 1
        else:
            bad += 1
            print(f"{ln:4} {src[ln - 1].strip()[:50]:50} | compiler: {cv} | clear-ls: {sv}")
    total = ok + bad + accepted
    print(f"-- {ok}/{total} match, {accepted} accepted deviations\n")
