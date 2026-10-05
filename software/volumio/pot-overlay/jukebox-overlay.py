#!/usr/bin/env python3
"""jukebox-overlay - serve the browser overlay that mirrors balance/tone pots.

A tiny, dependency-free HTTP server for the kiosk (and any browser on the LAN):

  GET /overlay.js    -> the client script (injected into the Volumio UI)
  GET /overlay.css   -> its stylesheet
  GET /events        -> Server-Sent Events stream of pot changes
  GET /state         -> latest value (JSON), for debugging
  POST /update       -> {"type":"balance","pan":0.4,...} fed by jukebox-pots

The jukebox-pots daemon POSTs every balance/bass/treble change to /update and
the server fans it out to every connected browser.  No third-party modules.
"""

from __future__ import annotations

import json
import os
import queue
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("JK_OVERLAY_HOST", "0.0.0.0")
PORT = int(os.environ.get("JK_OVERLAY_PORT", "3210"))
ROOT = os.environ.get("JK_OVERLAY_ROOT", "/usr/local/jukebox-overlay")

_lock = threading.Lock()
_clients: "set[queue.Queue]" = set()
_last: dict = {}
_last_ts: float = 0.0


def log(msg: str) -> None:
    print("%s %s" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg), flush=True)


def broadcast(payload: dict) -> None:
    global _last, _last_ts
    data = json.dumps(payload)
    with _lock:
        _last = payload
        _last_ts = time.time()
        clients = list(_clients)
    for q in clients:
        try:
            q.put_nowait(data)
        except queue.Full:
            pass


def read_asset(name: str) -> bytes | None:
    path = os.path.join(ROOT, name)
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError:
        return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args) -> None:  # keep the journal quiet
        pass

    def _cors(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path in ("/overlay.js", "/overlay.css"):
            body = read_asset(os.path.basename(path))
            if body is None:
                self._send(404, b"not found", "text/plain")
                return
            ctype = "application/javascript" if path.endswith(".js") else "text/css"
            self._send(200, body, ctype)
            return
        if path == "/state":
            self._send(200, json.dumps(_last).encode(), "application/json")
            return
        if path == "/events":
            self._stream()
            return
        if path in ("/", "/index.html"):
            self._send(200, b"jukebox-overlay ok\n", "text/plain")
            return
        self._send(404, b"not found", "text/plain")

    def do_POST(self) -> None:  # noqa: N802
        if self.path.split("?", 1)[0] != "/update":
            self._send(404, b"not found", "text/plain")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, OSError):
            self._send(400, b"bad json", "text/plain")
            return
        if isinstance(payload, dict) and payload.get("type"):
            broadcast(payload)
        self._send(204, b"", "text/plain")

    def _stream(self) -> None:
        q: queue.Queue = queue.Queue(maxsize=100)
        with _lock:
            _clients.add(q)
            last = _last
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self._cors()
        self.end_headers()
        try:
            if last:
                self.wfile.write(b"data: " + json.dumps(last).encode() + b"\n\n")
                self.wfile.flush()
            while True:
                try:
                    data = q.get(timeout=15)
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    continue
                self.wfile.write(b"data: " + data.encode() + b"\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            with _lock:
                _clients.discard(q)


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = True
    log("jukebox-overlay listening on %s:%d (root=%s)" % (HOST, PORT, ROOT))
    server.serve_forever()


if __name__ == "__main__":
    main()
