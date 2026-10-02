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
"""

from __future__ import annotations

import argparse
import glob
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

# --- platform backend --------------------------------------------------------
# "volumio": volume through the Volumio API, balance through the SoftMaster
#            mixer (the Volumio chain puts a softvol element on the DAC branch).
# "moode":   volume through moOde's vol.sh (volume type "CamillaDSP", so the
#            fader lives inside CamillaDSP and only the DAC branch is affected)
#            and balance as per-channel gain filters in the CamillaDSP config.
# "auto": pick moOde when /var/www/util/vol.sh exists, else Volumio.
BACKEND = _env("JP_BACKEND", "auto")
MOODE_VOLSH = _env("JP_MOODE_VOLSH", "/var/www/util/vol.sh")
MOODE_TONE_CONFIG = _env("JP_MOODE_TONE_CONFIG", "/usr/share/camilladsp/configs/jukebox-tone.yml")
# Attenuation applied to the opposite channel at full pan (dB, 0 == min).
BALANCE_MAX_DB = _env_int("JP_BALANCE_MAX_DB", 60)

if BACKEND == "auto":
    BACKEND = "moode" if os.path.exists(MOODE_VOLSH) else "volumio"

# Arduino Micro (official + Arduino LLC/SA USB ids) and clones that identify
# themselves by product string.  Used only to pick the right ttyACM/ttyUSB.
ARDUINO_VID_PID = {
    ("2341", "8036"), ("2341", "8037"),
    ("2a03", "0042"), ("2a03", "0043"),
}
# Product strings contain "Arduino" (e.g. "Arduino Micro"); keep the fallback
# narrow so an unrelated serial device is never picked by mistake.
ARDUINO_HINTS = ("arduino",)

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


def _sysfs_usb_ids(tty: str) -> tuple[str, str, str]:
    """Resolve (idVendor, idProduct, product) for a /dev/ttyXXX, or empty."""
    dev = "/sys/class/tty/%s/device" % os.path.basename(tty)
    path = os.path.realpath(dev) if os.path.exists(dev) else ""
    node = path
    for _ in range(6):
        if not node or node == "/":
            break
        vid = os.path.join(node, "idVendor")
        pid = os.path.join(node, "idProduct")
        if os.path.exists(vid) and os.path.exists(pid):
            try:
                product = open(os.path.join(node, "product")).read().strip()
            except OSError:
                product = ""
            return (open(vid).read().strip(), open(pid).read().strip(), product)
        node = os.path.dirname(node)
    return ("", "", "")


def _looks_like_arduino(tty: str) -> bool:
    vid, pid, product = _sysfs_usb_ids(tty)
    if (vid, pid) in ARDUINO_VID_PID:
        return True
    blob = (product + " " + os.path.basename(tty)).lower()
    return any(h in blob for h in ARDUINO_HINTS)


def find_port() -> str | None:
    """Return the serial device for the PowerAndPots Arduino, or None.

    Preference: explicit JP_PORT, then /dev/serial/by-id (stable names), then
    the first ttyACM/ttyUSB whose USB ids look like an Arduino.
    """
    if EXPLICIT_PORT:
        return EXPLICIT_PORT if os.path.exists(EXPLICIT_PORT) else None

    for link in sorted(glob.glob("/dev/serial/by-id/*")):
        name = os.path.basename(link).lower()
        if any(h in name for h in ARDUINO_HINTS):
            real = os.path.realpath(link)
            if os.path.exists(real):
                return real

    for pattern in ("/dev/ttyACM*", "/dev/ttyUSB*"):
        for tty in sorted(glob.glob(pattern)):
            if _looks_like_arduino(tty):
                return tty
    return None


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
    """Set the DAC volume: Volumio API, moOde vol.sh, or a direct mixer write."""
    percent = int(clamp(percent, 0, VOLUME_MAX))
    if USE_API and BACKEND == "volumio":
        url = "http://%s/api/v1/commands/?cmd=volume&volume=%d" % (VOLUMIO, percent)
        try:
            with urllib.request.urlopen(url, timeout=3) as resp:
                resp.read()
            return True
        except Exception:
            pass  # fall through to the direct write
    if USE_API and BACKEND == "moode":
        try:
            proc = subprocess.run([MOODE_VOLSH, str(percent)], capture_output=True,
                                  text=True, timeout=5)
            if proc.returncode == 0:
                return True
        except (OSError, subprocess.SubprocessError):
            pass
        # fall through to the direct write (only meaningful on Volumio chains)
    lo, hi = softmaster_range()
    raw = int(round((percent - 0) / float(VOLUME_MAX) * (hi - lo) + lo))
    return write_softmaster(raw, raw)


def balance_db_lr(pan: float, max_db: int = BALANCE_MAX_DB) -> tuple[float, float]:
    """Pan in [-1,+1] -> per-channel gain in dB (attenuate the far channel)."""
    if pan > 0:                      # pan right -> attenuate left
        return -max_db * pan, 0.0
    if pan < 0:                      # pan left -> attenuate right
        return 0.0, max_db * pan
    return 0.0, 0.0


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
            self.bass_db = map_tone(value, invert=TONE_BASS_INVERT)
        elif name == TONE_TREBLE_POT:
            self.treble_db = map_tone(value, invert=TONE_TREBLE_INVERT)

    def _active_variant(self) -> str | None:
        for v in TONE_VARIANTS:
            if os.path.exists(TONE_ACTIVE % v):
                return v
        return None

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
        return ToneControl._write_if_changed(path, text, new_text, n)

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

    @staticmethod
    def _rewrite_balance(path: str, left_db: float, right_db: float) -> bool:
        """Set the gain of the balance_l / balance_r filters (moOde config)."""
        try:
            with open(path) as fh:
                text = fh.read()
        except OSError:
            return False
        changed = False
        for name, value in (("balance_l", left_db), ("balance_r", right_db)):
            pattern = re.compile(
                r"(%s:\s*\n(?:[^\n]*\n)*?[^\n]*?gain:\s*)([-+]?[0-9]*\.?[0-9]+)"
                % name)
            text, n = pattern.subn(lambda m: m.group(1) + ("%.2f" % value), text)
            changed = changed or n > 0
        if not changed:
            return False
        return ToneControl._commit(path, text)

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
        if BACKEND == "moode":
            # moOde: one CamillaDSP config carries both tone and balance.
            if self._rewrite_moode(self.bass_db, self.treble_db):
                self._reload_camilla()
            self.last = (self.bass_db, self.treble_db)
            log("tone bass %+.1f dB / treble %+.1f dB" % (self.bass_db, self.treble_db))
            return
        # Volumio: rewrite every variant template (so the gains persist
        # whatever branch the chain runs) plus the active config.
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

    def _rewrite_moode(self, bass_db: float, treble_db: float,
                       left_db: float | None = None, right_db: float | None = None) -> bool:
        """Update tone (and optionally balance) in moOde's CamillaDSP config."""
        path = MOODE_TONE_CONFIG
        if not os.path.exists(path):
            if not self._warned:
                log("tone: moOde CamillaDSP config not found (%s)" % path)
                self._warned = True
            return False
        self._warned = False
        ok = self._rewrite(path, "bass", bass_db)
        self._rewrite(path, "treble", treble_db)
        if left_db is not None and right_db is not None:
            if self._rewrite_balance(path, left_db, right_db):
                ok = True
        return ok


# ----------------------------------------------------------------- controller


class Controller:
    def __init__(self) -> None:
        self.pot_volume: int | None = None
        self.pot_balance: int | None = None
        self.last_api: int | None = None
        self.last_balance: tuple[float, float] | None = None
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
        if BACKEND == "moode":
            # Balance lives in the CamillaDSP tone config (per-channel gains).
            want = balance_db_lr(pan)
            if self.last_balance != want:
                if self.tone._rewrite_balance(MOODE_TONE_CONFIG, *want):
                    self.last_balance = want
                    self.tone._reload_camilla()
                    log("balance %+.2f/%+.2f dB (pot %s)" % (want[0], want[1], self.pot_balance))
            return
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
        vid, pid, product = _sysfs_usb_ids(port)
        print("serial port   : %s" % port)
        print("usb id        : %s:%s %s" % (vid or "?", pid or "?", product))
    else:
        print("serial port   : <not found>")
        print("                (no /dev/ttyACM* or ttyUSB* looks like an Arduino)")
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
    assert balance_db_lr(0.0) == (0.0, 0.0)
    assert balance_db_lr(1.0, max_db=60) == (-60.0, 0.0)
    assert balance_db_lr(-1.0, max_db=60) == (0.0, -60.0)
    assert balance_db_lr(0.5, max_db=60) == (-30.0, 0.0)
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
