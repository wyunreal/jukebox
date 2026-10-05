#!/usr/bin/env python3
"""jukebox-pots - drive the DAC volume and balance from the PowerAndPots Arduino.

The PowerAndPotsArduino firmware prints the state of its potentiometers on the
USB serial port (9600 baud, only on change):

    POT volume: 15 (raw 700)
    POT balance: 10 (raw 512)

This daemon reads those two lines and maps them onto the I2S DAC software
volume:

  * volume  -> the normal Volumio volume (0..100), applied through the Volumio
               API so the UI / API stay in sync;
  * balance -> a per-channel attenuation applied afterwards, written straight
               to the ALSA mixer ("SoftMaster Playback Volume" has one value per
               channel).

Only the DAC branch of the jukebox-audio split is touched.  The second,
constant-level output that feeds the spectrum analyser is never modified: it
does not carry the SoftMaster control at all.

It has no third-party dependencies (no pyserial): the serial port is opened and
configured directly through termios.  The port is re-scanned when it is missing,
so the service survives the Arduino being unplugged and replugged.

Which board is which is decided by the USB product string baked into each
board's firmware (the keyboard Micro reports "Jukebox Keyboard", the
PowerAndPots one "Jukebox Pots"), never by the USB port.  The two Micros share
a VID:PID and carry no unique USB serial, so a port number or a by-path link
would break whenever a cable or hub moved; the product string does not.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import select
import subprocess
import sys
import termios
import time
import urllib.request

# --------------------------------------------------------------------- config


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default)


def _env_int(name: str, default: int) -> int:
    try:
        return int(_env(name, str(default)))
    except ValueError:
        return default


def _env_bool(name: str, default: bool) -> bool:
    return _env(name, "1" if default else "0").strip().lower() not in ("0", "no", "false", "off")


DAC_CARD = _env("JP_DAC_CARD", "")
EXPLICIT_PORT = _env("JP_PORT", "")
BAUD = _env_int("JP_BAUD", 9600)

# Board selection is by USB product string, written per board in the firmware
# (see platformio.ini, -DUSB_PRODUCT).  The two Micros share a VID:PID and have
# no unique USB serial, so this string is the only thing that makes each board
# addressable without tying it to a physical USB port.  It shows up both in
# /dev/serial/by-id and in the sysfs "product" attribute.
PRODUCT_MATCH = _env("JP_PRODUCT", "Jukebox Pots")

# Optional overlay: POST every balance/bass/treble change to the jukebox-overlay
# server so the UI can show a circular indicator next to the volume one.  It is
# best-effort: if the overlay is not installed the POST fails fast and is
# ignored.
OVERLAY_ENABLED = _env_bool("JP_OVERLAY", True)
OVERLAY_URL = _env("JP_OVERLAY_URL", "http://localhost:3210/update")

VOLUMIO = _env("JP_VOLUMIO", "localhost:3000")
USE_API = _env_bool("JP_USE_API", True)

POT_MAX = _env_int("JP_POT_MAX", 20)          # firmware range of both pots
VOLUME_MAX = _env_int("JP_VOLUME_MAX", 100)   # Volumio volume scale
BALANCE_CENTER = _env_int("JP_BALANCE_CENTER", 10)
BALANCE_SPAN = _env_int("JP_BALANCE_SPAN", 10) or 1
BALANCE_INVERT = _env_bool("JP_BALANCE_INVERT", False)
VOLUME_INVERT = _env_bool("JP_VOLUME_INVERT", False)

POLL_MS = _env_int("JP_POLL_MS", 200)
RESCAN_MS = _env_int("JP_RESCAN_MS", 3000)

# --- tone control (bass/treble via CamillaDSP) ------------------------------
# The jukebox-audio chain runs audio through CamillaDSP (the ALSA cdsp plugin).
# Its config carries two shelf gains marked JUKEBOX_TONE_BASS / JUKEBOX_TONE_TREBLE.
# Both pots read 0..20 with 10 = flat (0 dB); they map to +/-TONE_MAX_DB.
TONE_ENABLE = _env_bool("JP_TONE", True)
TONE_MAX_DB = _env_int("JP_TONE_MAX_DB", 12)
TONE_POT_CENTER = _env_int("JP_TONE_CENTER", 10)
TONE_POT_SPAN = _env_int("JP_TONE_SPAN", 10) or 1
TONE_BASS_INVERT = _env_bool("JP_TONE_BASS_INVERT", False)
TONE_TREBLE_INVERT = _env_bool("JP_TONE_TREBLE_INVERT", False)
TONE_TEMPLATE = _env("JP_TONE_TEMPLATE", "/usr/local/jukebox-audio/cdsp/camilla.%s.yml")
TONE_ACTIVE = _env("JP_TONE_ACTIVE", "/var/lib/jukebox-audio/camilla-active.%s.yml")
TONE_VARIANTS = ("usb", "hdmi", "jack", "daconly")
# CamillaDSP is (re)started by the cdsp plugin; we locate it to reload it.
CAMILLA_PROC = _env("JP_CAMILLA_PROC", "camilladsp")

VOLUMIO_RE = re.compile(r"^POT volume:\s*(-?\d+)")
BALANCE_RE = re.compile(r"^POT balance:\s*(-?\d+)")
# The two spare pots feed the tone control. Which firmware line maps to which
# function is configurable so we can pin it down by moving each pot.
TONE_POTS = {
    "single": r"^POT single:\s*(-?\d+)",
    "multisecond": r"^POT multi second:\s*(-?\d+)",
}
TONE_BASS_POT = _env("JP_TONE_BASS_POT", "single")
TONE_TREBLE_POT = _env("JP_TONE_TREBLE_POT", "multisecond")


def log(msg: str) -> None:
    print("%s %s" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg), flush=True)


def clamp(value: float, lo: float, hi: float) -> float:
    return lo if value < lo else hi if value > hi else value


# ------------------------------------------------------------------- mapping


def map_volume(pot: int, pot_max: int = POT_MAX, volume_max: int = VOLUME_MAX,
               invert: bool = VOLUME_INVERT) -> int:
    """Pot value (0..pot_max) -> Volumio volume (0..volume_max)."""
    pot = int(clamp(pot, 0, pot_max))
    if invert:
        pot = pot_max - pot
    return int(round(pot / float(pot_max) * volume_max))


def map_balance(pot: int, center: int = BALANCE_CENTER, span: int = BALANCE_SPAN,
                invert: bool = BALANCE_INVERT) -> float:
    """Pot value -> pan in [-1, +1]; 0 is centered, +1 fully right."""
    b = (int(pot) - center) / float(span)
    if invert:
        b = -b
    return float(clamp(b, -1.0, 1.0))


def balance_lr(base: int, pan: float) -> tuple[int, int]:
    """Attenuate the channel opposite to the pan, keeping the base level."""
    base = int(clamp(base, 0, 10 ** 6))
    if pan > 0:                      # pan right -> attenuate left
        return max(0, int(round(base * (1.0 - pan)))), base
    if pan < 0:                      # pan left -> attenuate right
        return base, max(0, int(round(base * (1.0 + pan))))
    return base, base


def map_tone(pot: int, center: int = TONE_POT_CENTER, span: int = TONE_POT_SPAN,
             max_db: int = TONE_MAX_DB, invert: bool = False) -> float:
    """Tone pot -> shelf gain in dB. Pot == center -> 0.0 dB (flat)."""
    g = (int(clamp(pot, 0, 10 ** 6)) - center) / float(span) * max_db
    if invert:
        g = -g
    return float(clamp(g, -max_db, max_db))


# -------------------------------------------------------------------- serial


def _usb_product(tty: str) -> str:
    """Read a /dev/ttyXXX's USB product string from sysfs, or "" if unknown.

    This is the string the board reports at enumeration (see the firmware's
    -DUSB_PRODUCT), not a USB VID/PID and not a port name.
    """
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


def _product_matches(product: str) -> bool:
    return product.strip().lower() == PRODUCT_MATCH.strip().lower()


def request_status(fd: int) -> None:
    """Ask the firmware for a full status report.

    The firmware only prints a value when it changes, so a board that was
    already running when the Pi booted would stay silent. Any byte received
    makes it re-emit every pot/switch once; the daemon then seeds volume and
    balance from the current pot positions.
    """
    try:
        os.write(fd, b"\n")
    except OSError:
        pass


def open_serial(path: str) -> int:
    # Deliberately does NOT assert DTR: on the Arduino Micro (ATmega32U4) DTR is
    # wired to the reset line, so raising it reboots the board — which would also
    # reset the power state machine on the same board and could drop the relay.
    # The firmware streams regardless, so plain termios is enough.
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = termios.tcgetattr(fd)
    cc = list(cc)
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 0
    cflag = termios.CS8 | termios.CREAD | termios.CLOCAL
    ispeed = ospeed = getattr(termios, "B%d" % BAUD)
    termios.tcsetattr(fd, termios.TCSANOW,
                      [0, 0, cflag, 0, ispeed, ospeed, cc])
    return fd


def read_lines(fd: int, timeout: float = 0.2) -> tuple[list[str], bool]:
    """Read available lines. Returns (lines, alive); alive is False once the
    port disappears (unplugged), so the caller can drop it and re-scan."""
    lines: list[str] = []
    buf = b""
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            r, _, _ = select.select([fd], [], [], remaining)
        except OSError:
            return lines, False
        if not r:
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


def find_port() -> str | None:
    """Return the serial device of the PowerAndPots Arduino, or None.

    Selection is by the USB product string the board's firmware reports
    (PRODUCT_MATCH), not by a port number or a USB VID/PID.  Preference:
    an explicit JP_PORT override, then /dev/serial/by-id links whose name
    matches, then any ttyACM/ttyUSB whose sysfs product matches.
    """
    if EXPLICIT_PORT:
        return EXPLICIT_PORT if os.path.exists(EXPLICIT_PORT) else None

    want = PRODUCT_MATCH.strip().lower().replace(" ", "_")
    for link in sorted(glob.glob("/dev/serial/by-id/*")):
        name = os.path.basename(link).lower()
        if want in name:
            real = os.path.realpath(link)
            if os.path.exists(real):
                return real

    for pattern in ("/dev/ttyACM*", "/dev/ttyUSB*"):
        for tty in sorted(glob.glob(pattern)):
            if _product_matches(_usb_product(tty)):
                return tty
    return None


# ---------------------------------------------------------------------- ALSA


def amixer(args: list[str], quiet: bool = False) -> subprocess.CompletedProcess | None:
    # Writes pass quiet=True. Reads do not: on the Pi, "amixer -q sget" returns
    # an empty stdout, so the query helpers below would never see the values.
    cmd = ["amixer"]
    if quiet:
        cmd.append("-q")
    if DAC_CARD:
        cmd += ["-c", DAC_CARD]
    try:
        return subprocess.run(cmd + args, capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None


def softmaster_range() -> tuple[int, int]:
    proc = amixer(["sget", "SoftMaster"])
    if proc and proc.returncode == 0:
        m = re.search(r"Limits:\s*Playback\s+(\d+)\s*-\s*(\d+)", proc.stdout)
        if m:
            return int(m.group(1)), int(m.group(2))
    return 0, 99


def read_softmaster() -> tuple[int, int] | None:
    proc = amixer(["sget", "SoftMaster"])
    if not proc or proc.returncode != 0:
        return None
    left = re.search(r"Front Left:\s*Playback\s+(\d+)", proc.stdout)
    right = re.search(r"Front Right:\s*Playback\s+(\d+)", proc.stdout)
    if not left or not right:
        return None
    return int(left.group(1)), int(right.group(1))


def write_softmaster(left: int, right: int) -> bool:
    proc = amixer(["sset", "SoftMaster", "%d,%d" % (left, right)], quiet=True)
    return bool(proc and proc.returncode == 0)


def ensure_softmaster() -> bool:
    """The softvol element is created the first time the chain is opened."""
    if read_softmaster() is not None:
        return True
    try:
        subprocess.run(
            ["aplay", "-q", "-D", "volumio", "-f", "S16_LE", "-r", "44100",
             "-c", "2", "-d", "1", "/dev/zero"],
            capture_output=True, timeout=8,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return read_softmaster() is not None


def set_volume(percent: int) -> bool:
    """Set the DAC volume through the Volumio API, or a direct mixer write."""
    percent = int(clamp(percent, 0, VOLUME_MAX))
    if USE_API:
        url = "http://%s/api/v1/commands/?cmd=volume&volume=%d" % (VOLUMIO, percent)
        try:
            with urllib.request.urlopen(url, timeout=3) as resp:
                resp.read()
            return True
        except Exception:
            pass  # fall through to the direct write
    lo, hi = softmaster_range()
    raw = int(round((percent - 0) / float(VOLUME_MAX) * (hi - lo) + lo))
    return write_softmaster(raw, raw)


def notify_overlay(kind: str, **fields) -> None:
    """Best-effort POST of a pot change to the jukebox-overlay server."""
    if not OVERLAY_ENABLED:
        return
    payload = {"type": kind}
    payload.update(fields)
    data = json.dumps(payload).encode()
    try:
        req = urllib.request.Request(OVERLAY_URL, data=data,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=1) as resp:
            resp.read()
    except Exception:
        pass  # overlay not installed / not reachable


# ---------------------------------------------------------------------- tone


class ToneControl:
    """Rewrite the CamillaDSP shelf gains and reload it live (SIGHUP)."""

    def __init__(self) -> None:
        self.bass_db: float | None = None
        self.treble_db: float | None = None
        self.last: tuple[float, float] | None = None
        self.variant: str | None = None
        self._warned = False

    def pot_feed(self, name: str, value: int) -> None:
        if name == TONE_BASS_POT:
            db = map_tone(value, invert=TONE_BASS_INVERT)
            if db != self.bass_db:
                self.bass_db = db
                notify_overlay("bass", db=round(db, 2))
        elif name == TONE_TREBLE_POT:
            db = map_tone(value, invert=TONE_TREBLE_INVERT)
            if db != self.treble_db:
                self.treble_db = db
                notify_overlay("treble", db=round(db, 2))

    def _active_variant(self) -> str | None:
        for v in TONE_VARIANTS:
            if os.path.exists(TONE_ACTIVE % v):
                return v
        return None

    @staticmethod
    def _commit(path: str, new_text: str) -> bool:
        """Atomic write preserving mode/ownership; True when it changed."""
        try:
            with open(path) as fh:
                if fh.read() == new_text:
                    return True
        except OSError:
            return False
        try:
            st = os.stat(path)
            tmp = path + ".tmp"
            with open(tmp, "w") as fh:
                fh.write(new_text)
            os.chmod(tmp, st.st_mode & 0o7777)
            try:
                os.chown(tmp, st.st_uid, st.st_gid)
            except OSError:
                pass
            os.replace(tmp, path)
        except OSError:
            return False
        return True

    @staticmethod
    def _rewrite(path: str, which: str, value: float) -> bool:
        """Set the gain of the low/high shelf in a CamillaDSP config.

        Locates the filter by its biquad type (Lowshelf/Highshelf) so it does
        not depend on any comment marker, and keeps the file's mode/ownership
        so MPD's cdsp plugin can keep rewriting it.
        """
        try:
            with open(path) as fh:
                text = fh.read()
        except OSError:
            return False
        type_re = "Lowshelf" if which == "bass" else "Highshelf"
        # Match the filter block of the requested type and replace its gain.
        pattern = re.compile(
            r"(type:\s*%s\b(?:[^\n]*\n)*?[^\n]*?gain:\s*)([-+]?[0-9]*\.?[0-9]+)"
            % type_re)
        new_text, n = pattern.subn(lambda m: m.group(1) + ("%.2f" % value), text)
        if n == 0:
            return False
        return ToneControl._commit(path, new_text)

    def _reload_camilla(self) -> None:
        try:
            subprocess.run(["pkill", "-HUP", "-x", CAMILLA_PROC], timeout=5,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.SubprocessError):
            pass

    def apply(self) -> None:
        if not TONE_ENABLE:
            return
        if self.bass_db is None or self.treble_db is None:
            return
        if self.last == (self.bass_db, self.treble_db):
            return
        # Rewrite every variant template (so the gains persist whatever branch
        # the chain runs) plus the active config.
        paths = [TONE_TEMPLATE % v for v in TONE_VARIANTS]
        paths += [TONE_ACTIVE % v for v in TONE_VARIANTS if os.path.exists(TONE_ACTIVE % v)]
        wrote = False
        for path in paths:
            if self._rewrite(path, "bass", self.bass_db):
                wrote = True
            self._rewrite(path, "treble", self.treble_db)
        if not wrote and not any(os.path.exists(TONE_ACTIVE % v) for v in TONE_VARIANTS):
            if not self._warned:
                log("tone: no CamillaDSP config found (is jukebox-audio installed?)")
                self._warned = True
            return
        self._warned = False
        self._reload_camilla()
        self.last = (self.bass_db, self.treble_db)
        log("tone bass %+.1f dB / treble %+.1f dB" % (self.bass_db, self.treble_db))


# ----------------------------------------------------------------- controller


class Controller:
    def __init__(self) -> None:
        self.pot_volume: int | None = None
        self.pot_balance: int | None = None
        self.last_api: int | None = None
        self.last_pan: float | None = None
        self.volume_dirty = False
        self.warned_missing = False
        self.next_ensure = 0.0
        self.tone = ToneControl()

    def feed(self, line: str) -> None:
        m = VOLUMIO_RE.match(line)
        if m:
            value = int(m.group(1))
            if value != self.pot_volume:
                self.pot_volume = value
                self.volume_dirty = True
            return
        m = BALANCE_RE.match(line)
        if m:
            self.pot_balance = int(m.group(1))
            return
        for name, pattern in TONE_POTS.items():
            m = re.match(pattern, line)
            if m:
                self.tone.pot_feed(name, int(m.group(1)))
                return

    def apply_volume(self) -> None:
        if self.pot_volume is None or not self.volume_dirty:
            return
        pct = map_volume(self.pot_volume)
        if pct == self.last_api and read_softmaster() is not None:
            self.volume_dirty = False
            return
        if set_volume(pct):
            self.last_api = pct
            self.volume_dirty = False
            log("volume pot %s -> %d%%" % (self.pot_volume, pct))

    def apply_balance(self) -> None:
        if self.pot_balance is None:
            return
        pan = map_balance(self.pot_balance)
        if round(pan, 3) != self.last_pan:
            self.last_pan = round(pan, 3)
            notify_overlay("balance", pan=round(pan, 3))
        current = read_softmaster()
        if current is None:
            if not self.warned_missing:
                log("SoftMaster control not available on card %r "
                    "(is jukebox-audio installed?)" % DAC_CARD)
                self.warned_missing = True
            now = time.monotonic()
            if now >= self.next_ensure:
                self.next_ensure = now + 10.0
                ensure_softmaster()
            return
        self.warned_missing = False
        left, right = current
        base = max(left, right)
        want = balance_lr(base, pan)
        if (left, right) != want:
            write_softmaster(*want)

    def tick(self) -> None:
        self.apply_volume()
        self.apply_balance()
        self.tone.apply()


# ---------------------------------------------------------------------- probe


def probe() -> int:
    port = find_port()
    print("dac card      : %s" % (DAC_CARD or "<not set>"))
    if port:
        print("serial port   : %s" % port)
        print("usb product   : %s" % (_usb_product(port) or "?"))
    else:
        print("serial port   : <not found>")
        print("                (no serial device reports product %r)" % PRODUCT_MATCH)
    for path in sorted(glob.glob("/dev/ttyACM*") + glob.glob("/dev/ttyUSB*")):
        print("candidate     : %s -> %s" % (path, _usb_product(path) or "<unknown product>"))
    print("SoftMaster    : %s" % (read_softmaster(),))
    if port:
        try:
            fd = open_serial(port)
        except OSError as exc:
            print("serial open   : FAILED (%s)" % exc)
            return 1
        request_status(fd)
        deadline = time.monotonic() + 3.0
        seen = []
        while time.monotonic() < deadline and len(seen) < 4:
            lines, alive = read_lines(fd, 0.3)
            for line in lines:
                if VOLUMIO_RE.match(line) or BALANCE_RE.match(line):
                    seen.append(line)
            if not alive:
                break
        os.close(fd)
        print("serial read   : %s" % (seen if seen else "<no POT lines seen>"))
        return 0
    return 1


def selftest() -> int:
    assert map_volume(0) == 0 and map_volume(20) == 100 and map_volume(10) == 50
    assert map_volume(20, invert=True) == 0
    assert map_balance(10) == 0.0 and map_balance(20) == 1.0 and map_balance(0) == -1.0
    assert balance_lr(99, 0.0) == (99, 99)
    assert balance_lr(99, 1.0) == (0, 99)
    assert balance_lr(99, -1.0) == (99, 0)
    assert balance_lr(50, 0.5) == (25, 50)
    print("selftest ok")
    return 0


# ----------------------------------------------------------------------- main


def main() -> int:
    parser = argparse.ArgumentParser(description="jukebox pots -> DAC volume/balance")
    parser.add_argument("--probe", action="store_true",
                        help="show the detected port/mixer and exit")
    parser.add_argument("--selftest", action="store_true",
                        help="run the mapping self-tests and exit")
    parser.add_argument("--once", action="store_true",
                        help="apply the current mixer state once and exit")
    args = parser.parse_args()

    if args.selftest:
        return selftest()
    if args.probe:
        return probe()

    if not DAC_CARD:
        log("JP_DAC_CARD is not set; cannot pick the mixer card")
        return 2

    controller = Controller()

    if args.once:
        controller.tick()
        return 0

    log("jukebox-pots starting (card=%s, api=%s)" % (DAC_CARD, USE_API))
    fd: int | None = None
    port = ""
    next_scan = 0.0

    try:
        while True:
            now = time.monotonic()
            if fd is None:
                if now >= next_scan:
                    port = find_port() or ""
                    if port:
                        try:
                            fd = open_serial(port)
                            request_status(fd)
                            log("connected to %s (status requested)" % port)
                        except Exception as exc:
                            log("cannot open %s: %s" % (port, exc))
                            port = ""
                    if not port:
                        log("waiting for the PowerAndPots Arduino...")
                    next_scan = now + RESCAN_MS / 1000.0
                controller.tick()
                time.sleep(POLL_MS / 1000.0)
                continue

            lines, alive = read_lines(fd, POLL_MS / 1000.0)
            for line in lines:
                controller.feed(line)
            if not alive:
                log("lost %s (unplugged?)" % port)
                os.close(fd)
                fd = None
                port = ""
                next_scan = time.monotonic() + RESCAN_MS / 1000.0
                continue
            controller.tick()
    except KeyboardInterrupt:
        pass
    finally:
        if fd is not None:
            os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
