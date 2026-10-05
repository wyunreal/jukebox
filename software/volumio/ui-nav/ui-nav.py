#!/usr/bin/env python3
"""jukebox-ui-nav - daemon -> UI navigation channel for the jukebox.

A tiny, dependency-free HTTP/SSE server that lets a local daemon (e.g.
jukebox-keyboard's open/close key) ask the Volumio UI to change screen:

  GET  /ui-nav.js   -> the client script (injected into the Volumio UI)
  GET  /events      -> Server-Sent Events stream of navigation commands
  GET  /state       -> latest command (JSON), for debugging
  POST /update      -> {"type":"nav","view":"toggle"} fed by a daemon

It only carries *screen navigation*; nothing about audio or pots. The client
script calls the UI's ui-router `$state` to switch between the now-playing home
and the play queue. No third-party modules.
"""

from __future__ import annotations

import json
import os
import queue
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("JK_NAV_HOST", "0.0.0.0")
PORT = int(os.environ.get("JK_NAV_PORT", "3211"))
ROOT = os.environ.get("JK_NAV_ROOT", "/usr/local/jukebox-ui-nav")
# Volumio's favourites/playlist files (read-only, for the queries below).
FAV_DIR = os.environ.get("JK_NAV_FAV_DIR", "/data/favourites")
PLAYLIST_DIR = os.environ.get("JK_NAV_PLAYLIST_DIR", "/data/playlist")
# Prefix for auto-named "save queue as playlist" files.
PLAYLIST_PREFIX = os.environ.get("JK_NAV_PLAYLIST_PREFIX", "Playlist")

_lock = threading.Lock()
_clients: "set[queue.Queue]" = set()
_last: dict = {}


def log(msg: str) -> None:
    print("%s %s" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg), flush=True)


def broadcast(payload: dict) -> None:
    global _last
    data = json.dumps(payload)
    with _lock:
        _last = payload
        clients = list(_clients)
    for q in clients:
        try:
            q.put_nowait(data)
        except queue.Full:
            pass


def read_asset(name: str) -> bytes | None:
    try:
        with open(os.path.join(ROOT, name), "rb") as fh:
            return fh.read()
    except OSError:
        return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args) -> None:
        pass

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/ui-nav.js":
            body = read_asset("ui-nav.js")
            if body is None:
                self._send(404, b"not found", "text/plain")
                return
            self._send(200, body, "application/javascript")
            return
        if path == "/favourite":
            self._favourite()
            return
        if path == "/next-playlist-name":
            self._next_playlist_name()
            return
        if path == "/state":
            self._send(200, json.dumps(_last).encode(), "application/json")
            return
        if path == "/events":
            self._stream()
            return
        self._send(200, b"jukebox-ui-nav ok\n", "text/plain")

    def _favourite(self) -> None:
        """Whether a track/station is in Volumio's favourites.

        Volumio does not expose this over REST (and for webradio it does not
        report it over socket either), so the client asks us and we read the
        file Volumio keeps. Query: ?service=webradio&uri=...
        """
        from urllib.parse import urlparse, parse_qs
        q = parse_qs(urlparse(self.path).query)
        service = (q.get("service") or ["mpd"])[0]
        uri = (q.get("uri") or [""])[0]
        name = "radio-favourites" if service == "webradio" else "favourites"
        fav = False
        try:
            with open(os.path.join(FAV_DIR, name), encoding="utf-8") as fh:
                for e in json.load(fh):
                    if isinstance(e, dict) and e.get("uri") == uri:
                        fav = True
                        break
        except (OSError, ValueError):
            pass
        self._send(200, json.dumps({"favourite": fav}).encode(), "application/json")

    def _next_playlist_name(self) -> None:
        """Next free "<prefix> N" name, based on the playlists Volumio already
        has (files in /data/playlist). Query: ?prefix=Playlist (optional)."""
        from urllib.parse import urlparse, parse_qs
        q = parse_qs(urlparse(self.path).query)
        prefix = (q.get("prefix") or [PLAYLIST_PREFIX])[0] or PLAYLIST_PREFIX
        highest = 0
        try:
            for fn in os.listdir(PLAYLIST_DIR):
                if fn == prefix:
                    highest = max(highest, 1)
                    continue
                if fn.startswith(prefix + " "):
                    try:
                        highest = max(highest, int(fn[len(prefix) + 1:]))
                    except ValueError:
                        pass
        except OSError:
            pass
        self._send(200, json.dumps({"name": "%s %d" % (prefix, highest + 1)}).encode(),
                   "application/json")

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
        self.send_header("Access-Control-Allow-Origin", "*")
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
    log("jukebox-ui-nav listening on %s:%d (root=%s)" % (HOST, PORT, ROOT))
    server.serve_forever()


if __name__ == "__main__":
    main()
