"""Minimal stdio LSP client for tool scripts (threaded reader, notifications
kept, requests with timeouts). Used by soak.py and sweep.py."""
import json, os, queue, subprocess, threading, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.environ.get("CLEAR_LS_BIN", os.path.join(REPO, "bin", "clear-ls"))


class Client:
    def __init__(self, root, compiler=False, init_options=None, folders=None):
        # CLEAR_LS_ARGS: extra server flags, e.g. "--no-cache".
        args = [BIN, "lsp"] + os.environ.get("CLEAR_LS_ARGS", "").split()
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, cwd=root)
        self.root = root
        self.nid = 0
        self.responses = {}
        self.cond = threading.Condition()
        self.notes = []
        self.versions = {}
        threading.Thread(target=self._reader, daemon=True).start()
        opts = dict(init_options or {})
        if not compiler:
            opts.setdefault("compiler", {"enabled": False})
        # Phase 10 measurements are of a cold server; warm.py turns it on.
        opts.setdefault("warmup", {"enabled": False})
        init = {"rootUri": "file://" + root, "initializationOptions": opts,
                "capabilities": {"general": {"positionEncodings": ["utf-16"]}}}
        # folders: extra workspace folders after *root* (multi-root).
        if folders:
            init["workspaceFolders"] = [{"uri": "file://" + f, "name": os.path.basename(f)} for f in [root] + folders]
        self.request("initialize", init)
        self.notify("initialized", {})

    def _reader(self):
        out = self.p.stdout
        while True:
            n = None
            while True:
                line = out.readline()
                if not line:
                    return
                line = line.strip()
                if not line:
                    break
                k, v = line.split(b":", 1)
                if k.lower() == b"content-length":
                    n = int(v)
            msg = json.loads(out.read(n))
            if "id" in msg and "method" not in msg:
                with self.cond:
                    self.responses[msg["id"]] = (msg, time.time())
                    self.cond.notify_all()
            else:
                self.notes.append(msg)

    def _send(self, msg):
        body = json.dumps(msg).encode()
        self.p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.p.stdin.flush()

    def notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def send_request(self, method, params):
        """Sends without waiting; returns the id."""
        self.nid += 1
        self._send({"jsonrpc": "2.0", "id": self.nid, "method": method, "params": params})
        return self.nid

    def wait(self, rid, timeout=120):
        """(message, arrival time) of response *rid*."""
        deadline = time.time() + timeout
        with self.cond:
            while rid not in self.responses:
                left = deadline - time.time()
                if left <= 0:
                    raise TimeoutError(f"request {rid}")
                self.cond.wait(left)
            return self.responses.pop(rid)

    def request(self, method, params, timeout=120):
        """Result, or the error object (has "code")."""
        msg, _ = self.wait(self.send_request(method, params), timeout)
        return msg["result"] if "result" in msg else msg["error"]

    def open(self, path, text=None):
        text = open(path).read() if text is None else text
        uri = "file://" + path
        self.versions[uri] = 1
        self.notify("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": "crystal", "version": 1, "text": text}})
        return text

    def change(self, path, text):
        uri = "file://" + path
        self.versions[uri] = self.versions.get(uri, 1) + 1
        self.notify("textDocument/didChange", {"textDocument": {"uri": uri, "version": self.versions[uri]},
                                               "contentChanges": [{"text": text}]})

    @staticmethod
    def at(path, line, character):
        return {"textDocument": {"uri": "file://" + path}, "position": {"line": line, "character": character}}

    def rss_mb(self):
        with open(f"/proc/{self.p.pid}/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) // 1024
        return -1

    def close(self):
        try:
            self.request("shutdown", None, timeout=10)
            self.notify("exit", None)
            self.p.wait(timeout=10)
        except Exception:
            self.p.kill()


def pos(text, needle, shift=0):
    off = text.index(needle) + shift
    before = text[:off]
    return before.count("\n"), off - (before.rfind("\n") + 1)


def percentile(values, p):
    if not values:
        return 0.0
    v = sorted(values)
    return v[min(len(v) - 1, int(round(p / 100.0 * (len(v) - 1))))]
