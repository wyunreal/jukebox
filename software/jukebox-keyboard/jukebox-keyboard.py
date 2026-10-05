#!/usr/bin/env python3
"""jukebox-keyboard - turn the KeyboardArduino into playback transport keys.

The KeyboardArduino firmware scans a 4x4 button matrix and prints key events on
its USB serial port (9600 baud, 1-based coordinates):

    DOWN 2 3      button pressed
    UP 2 3        button released
    PRESS 2 3     released after a short press
    LONG_PRESS 2 3
    PRESSED 2 3   repeat while held

This daemon watches that port and, on key *press*, runs the configured Volumio
command for that key (play, pause, stop, previous track, next track). The
key -> action map lives in the config file (`JK_KEY_<action>=row,col`).

It has no third-party dependencies: the serial port is opened and configured
directly through termios. The board is selected by its USB product string
(`Jukebox Keyboard`), never by USB port, because the two Arduino Micros are
identical (same VID:PID, no unique serial).
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import select
import sys
import termios
import time
import urllib.request

# --------------------------------------------------------------------- config


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default)


BAUD = int(_env("JK_BAUD", "9600"))
PRODUCT_MATCH = _env("JK_PRODUCT", "Jukebox Keyboard")
VOLUMIO = _env("JK_VOLUMIO", "localhost:3000")

# Longest side of the matrix; keys outside 1..N are ignored as noise.
MATRIX_N = int(_env("JK_MATRIX_N", "4"))

# Which key triggers which action, as "row,col" (1-based). Empty = unassigned.
ACTIONS = {
    "PLAY": _env("JK_KEY_PLAY", ""),
    "PAUSE": _env("JK_KEY_PAUSE", ""),
    "STOP": _env("JK_KEY_STOP", ""),
    "PREV": _env("JK_KEY_PREV", ""),
    "NEXT": _env("JK_KEY_NEXT", ""),
}
# Volumio command per action.
CMD = {
    "PLAY": "play",
    "PAUSE": "pause",
    "STOP": "stop",
    "PREV": "prev",
    "NEXT": "next",
}

# "DOWN r c" is the press event; we act on it so keys feel immediate.
PRESS_RE = re.compile(r"^DOWN\s+(\d+)\s+(\d+)\s*$")

RESCAN_MS = int(_env("JK_RESCAN_MS", "3000"))
POLL_MS = int(_env("JK_POLL_MS", "200"))


def log(msg: str) -> None:
    print("%s %s" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg), flush=True)


# -------------------------------------------------------------------- lookup


def key_of(action: str) -> tuple[int, int] | None:
    spec = ACTIONS.get(action, "").strip()
    if not spec:
        return None
    m = re.match(r"^(\d+)\s*,\s*(\d+)$", spec)
    if not m:
        return None
    return int(m.group(1)), int(m.group(2))


def action_for(row: int, col: int) -> str | None:
    for action in ("PLAY", "PAUSE", "STOP", "PREV", "NEXT"):
        if key_of(action) == (row, col):
            return action
    return None


def run_action(action: str) -> None:
    cmd = CMD.get(action)
    if not cmd:
        return
    url = "http://%s/api/v1/commands/?cmd=%s" % (VOLUMIO, cmd)
    try:
        with urllib.request.urlopen(url, timeout=3) as resp:
            resp.read()
        log("%s -> cmd=%s" % (action, cmd))
    except Exception as exc:  # noqa: BLE001
        log("%s -> failed (%s)" % (action, exc))


# -------------------------------------------------------------------- serial


def _usb_product(tty: str) -> str:
    node = os.path.realpath("/sys/class/tty/%s/device" % os.path.basename(tty))
    for _ in range(6):
        if not node or node == "/":
            break
        path = os.path.join(node, "product")
        if os.path.exists(path):
            try:
                return open(path).read().strip()
            except OSError:
                return ""
        node = os.path.dirname(node)
    return ""


def find_port() -> str | None:
    explicit = _env("JK_PORT", "")
    if explicit:
        return explicit if os.path.exists(explicit) else None
    want = PRODUCT_MATCH.strip().lower().replace(" ", "_")
    for link in sorted(glob.glob("/dev/serial/by-id/*")):
        if want in os.path.basename(link).lower():
            real = os.path.realpath(link)
            if os.path.exists(real):
                return real
    for pattern in ("/dev/ttyACM*", "/dev/ttyUSB*"):
        for tty in sorted(glob.glob(pattern)):
            if _usb_product(tty).strip().lower() == PRODUCT_MATCH.strip().lower():
                return tty
    return None


def open_serial(path: str) -> int:
    # No DTR: on the Micro DTR is wired to reset, which would reboot the board.
    fd = os.open(path, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
    _, _, cflag, _, _, _, cc = termios.tcgetattr(fd)
    cc = list(cc)
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 0
    cflag = termios.CS8 | termios.CREAD | termios.CLOCAL
    speed = getattr(termios, "B%d" % BAUD)
    termios.tcsetattr(fd, termios.TCSANOW, [0, 0, cflag, 0, speed, speed, cc])
    return fd


def read_lines(fd: int, timeout: float = 0.2) -> tuple[list[str], bool]:
    lines: list[str] = []
    buf = b""
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            ready, _, _ = select.select([fd], [], [], remaining)
        except OSError:
            return lines, False
        if not ready:
            break
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            return lines, False
        if not chunk:
            return lines, False
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            lines.append(line.decode("ascii", "ignore").strip())
    return lines, True


# --------------------------------------------------------------- diagnostics


def _describe() -> None:
    port = find_port()
    print("board product : %s" % PRODUCT_MATCH)
    print("serial port   : %s" % (port or "<not found>"))
    for action in ("PLAY", "PAUSE", "STOP", "PREV", "NEXT"):
        k = key_of(action)
        print("key %-5s     : %s" % (action, ("%d,%d" % k) if k else "<unassigned>"))


def probe() -> int:
    _describe()
    if not any(key_of(a) for a in ACTIONS):
        print("\nNo keys are assigned yet. Use --watch to see the coordinates of a")
        print("key while you press it, then set JK_KEY_<action> in config.env.")
    return 0 if find_port() else 1


def watch() -> int:
    """Print every key event with its coordinates, to identify the keys."""
    port = find_port()
    if not port:
        print("jukebox-keyboard: no '%s' board found" % PRODUCT_MATCH, file=sys.stderr)
        return 1
    print("jukebox-keyboard: watching %s (Ctrl-C to stop)" % port, flush=True)
    fd = open_serial(port)
    try:
        while True:
            lines, alive = read_lines(fd, POLL_MS / 1000.0)
            for line in lines:
                if not line:
                    continue
                m = PRESS_RE.match(line)
                tag = ""
                if m:
                    action = action_for(int(m.group(1)), int(m.group(2)))
                    tag = "   -> %s" % action if action else ""
                print("%s%s" % (line, tag), flush=True)
            if not alive:
                print("jukebox-keyboard: lost %s" % port, file=sys.stderr)
                return 1
    except KeyboardInterrupt:
        print()
    finally:
        os.close(fd)
    return 0


# ----------------------------------------------------------------------- main


def main() -> int:
    parser = argparse.ArgumentParser(description="jukebox keyboard -> playback keys")
    parser.add_argument("--probe", action="store_true", help="show board + key map")
    parser.add_argument("--watch", action="store_true", help="print key events live")
    args = parser.parse_args()

    if args.probe:
        return probe()
    if args.watch:
        return watch()

    assigned = {a: key_of(a) for a in ACTIONS if key_of(a)}
    log("jukebox-keyboard starting (board=%r)" % PRODUCT_MATCH)
    if assigned:
        log("key map: " + ", ".join("%s=%d,%d" % (a, k[0], k[1]) for a, k in sorted(assigned.items())))
    else:
        log("no keys assigned yet (set JK_KEY_<action> in the config)")

    fd: int | None = None
    next_scan = 0.0
    try:
        while True:
            now = time.monotonic()
            if fd is None:
                if now >= next_scan:
                    port = find_port()
                    if port:
                        try:
                            fd = open_serial(port)
                            log("connected to %s" % port)
                        except Exception as exc:  # noqa: BLE001
                            log("cannot open %s: %s" % (port, exc))
                    else:
                        log("waiting for the KeyboardArduino...")
                    next_scan = now + RESCAN_MS / 1000.0
                time.sleep(POLL_MS / 1000.0)
                continue

            lines, alive = read_lines(fd, POLL_MS / 1000.0)
            for line in lines:
                m = PRESS_RE.match(line)
                if not m:
                    continue
                row, col = int(m.group(1)), int(m.group(2))
                action = action_for(row, col)
                if action:
                    run_action(action)
                else:
                    log("unmapped key %d,%d" % (row, col))
            if not alive:
                log("lost the keyboard board (unplugged?)")
                os.close(fd)
                fd = None
                next_scan = time.monotonic() + RESCAN_MS / 1000.0
    except KeyboardInterrupt:
        pass
    finally:
        if fd is not None:
            os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
