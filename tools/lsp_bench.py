#!/usr/bin/env python3
"""Scripted stdio session against bin/clear-ls on this repository: timings
for semantic tokens, local definition/references/rename and hover.

    python3 tools/lsp_bench.py        (after `make release`)
"""
import json, os, subprocess, time
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
p = subprocess.Popen(["./bin/clear-ls", "lsp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=root)
nid = [0]
def send(m):
    b = json.dumps(m).encode(); p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(b) + b); p.stdin.flush()
def recv():
    n = None
    while True:
        l = p.stdout.readline().strip()
        if not l: break
        k, v = l.split(b":", 1)
        if k.lower() == b"content-length": n = int(v)
    return json.loads(p.stdout.read(n))
def req(method, params):
    nid[0] += 1; t = time.time()
    send({"jsonrpc":"2.0","id":nid[0],"method":method,"params":params})
    r = recv(); return r.get("result", r.get("error")), (time.time()-t)*1000
def pos(text, needle, shift=0):
    off = text.index(needle) + shift; before = text[:off]
    return {"line": before.count("\n"), "character": off - (before.rfind("\n")+1)}
r, _ = req("initialize", {"rootUri": "file://" + root, "capabilities": {"general": {"positionEncodings": ["utf-16"]}}})
legend = r["capabilities"]["semanticTokensProvider"]["legend"]["tokenTypes"]
send({"jsonrpc":"2.0","method":"initialized","params":{}})
f = root + "/src/clear_ls/hir/lower_body.cr"; uri = "file://" + f; text = open(f).read()
send({"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":uri,"languageId":"crystal","version":1,"text":text}}})
req("textDocument/documentSymbol", {"textDocument":{"uri":uri}})  # wait for index
lines = text.count("\n")
for i in range(2):
    r, ms = req("textDocument/semanticTokens/full", {"textDocument":{"uri":uri}})
    print(f"semanticTokens/full ({lines} lines) {'cold' if i==0 else 'warm'}: {ms:.1f}ms, {len(r['data'])//5} tokens")
d = r["data"]; L = C = 0; counts = {}
for i in range(0, len(d), 5):
    L += d[i]; C = C + d[i+1] if d[i] == 0 else d[i+1]
    counts[legend[d[i+3]]] = counts.get(legend[d[i+3]], 0) + 1
print("  by type:", dict(sorted(counts.items(), key=lambda x: -x[1])))
needle = "kids << lower(c)"
r, ms = req("textDocument/definition", {"textDocument":{"uri":uri}, "position": pos(text, needle)})
print(f"definition of 'kids': {ms:.1f}ms -> line {r[0]['range']['start']['line']+1}: {text.splitlines()[r[0]['range']['start']['line']].strip()}")
r, ms = req("textDocument/references", {"textDocument":{"uri":uri}, "position": pos(text, needle), "context": {"includeDeclaration": True}})
print(f"references of 'kids': {ms:.1f}ms -> {len(r)} refs on lines {[x['range']['start']['line']+1 for x in r]}")
r, ms = req("textDocument/rename", {"textDocument":{"uri":uri}, "position": pos(text, needle), "newName": "children"})
print(f"rename kids->children: {ms:.1f}ms, {len(r['changes'][uri])} edits")
r, ms = req("textDocument/hover", {"textDocument":{"uri":uri}, "position": pos(text, "node : Syntax::Node) : ExprId", 0)})
print(f"hover param: {ms:.1f}ms -> {r['contents']['value']!r}")
r, ms = req("textDocument/definition", {"textDocument":{"uri":uri}, "position": pos(text, "Syntax::Node", 9)})
print(f"definition Syntax::Node: {ms:.1f}ms -> {r[0]['uri'][-30:]}:{r[0]['range']['start']['line']+1}")
req("shutdown", None); send({"jsonrpc":"2.0","method":"exit"}); p.stdin.close(); print("exit", p.wait())
