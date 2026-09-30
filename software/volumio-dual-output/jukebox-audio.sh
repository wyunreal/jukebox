#!/usr/bin/env bash
#
# jukebox-audio.sh - dual audio output for a Volumio jukebox on Raspberry Pi
#
# Splits Volumio's audio pipeline so the same audio goes to BOTH:
#   * the I2S DAC (main output, speakers), whose level is controlled by the
#     usual Volumio volume slider / API, and
#   * the Raspberry Pi 3.5 mm jack (fed to a spectrum analyser) at a constant
#     level that Volumio volume changes do NOT affect.
#
# How it works
# ------------
# Volumio builds /etc/asound.conf from "asound contributions" of its plugins.
# The standard contribution (softvolume.postVolume.conf) is replaced with a
# split chain:
#
#   volumio -> softvolume -> jukeboxRoute -> jukeboxSplit (multi)
#       |- volumioSoftVol (softvol, SoftMaster) -> postVolume -> volumioOutput -> volumioHw (I2S DAC)
#       '- jukeboxJack (3.5 mm jack, fixed full level)
#
# * The software volume control lives on the I2S DAC branch only, so the
#   Volumio UI / API volume affects the DAC alone.
# * The jack branch has no volume control; its hardware mixer (PCM) is kept
#   at full level and MPD's own mixer is disabled, so nothing moves it.
# * systemd units (a boot guard plus a path watcher) re-assert the
#   configuration if Volumio rewrites it from its UI.
#
# Usage (on the Volumio host, as root):
#   sudo ./jukebox-audio.sh install [--with-playback]
#   sudo ./jukebox-audio.sh verify  [--with-playback]
#   sudo ./jukebox-audio.sh apply      # re-assert (used by guard units)
#   sudo ./jukebox-audio.sh status
#   sudo ./jukebox-audio.sh uninstall
#
# From a development machine use deploy.sh, which copies this script over
# SSH and runs it remotely.
#
set -euo pipefail

VERSION="1.0.0"

APPLY_DIR="/usr/local/jukebox-audio"
LOG_FILE="/var/log/jukebox-audio.log"
VOLUMIO_ASOUND_DIR="/data/configuration/audio_interface/alsa_controller/asound"
SNIPPET_PATH="${VOLUMIO_ASOUND_DIR}/softvolume.postVolume.conf"
ALSA_CONFIG_JSON="/data/configuration/audio_interface/alsa_controller/config.json"
SPECIAL_CARDS_JSON="/volumio/app/plugins/music_service/mpd/special_cards_config.json"
BACKUP_ROOT="/var/backups/jukebox-audio"
RESTART_STAMP="/run/jukebox-audio-volumio-restart"
VOLUMIO_RESTART_MIN_INTERVAL=300
JACK_LEVEL="${JB_JACK_LEVEL:-0dB}"          # 0.00 dB == full clean level
JACK_LEVEL_RAW="${JB_JACK_LEVEL_RAW:-0}"
DAC_CARD="${JB_DAC_CARD:-}"
JACK_CARD="${JB_JACK_CARD:-}"
PLAY_TEST=0
JUNK_CONTROLS="JbTestMaster|AddProbeXyz|PersistA|BootCreateTest|LoopbackTest"

# ------------------------------------------------------------------- helpers

log()  { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG_FILE" 2>/dev/null || true; }
say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*"; }
fail() { printf '    \033[1;31mFAIL\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"; }

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }

detect_cards() {
  local f id
  for f in /proc/asound/card*/id; do
    [ -r "$f" ] || continue
    id="$(cat "$f" 2>/dev/null)" || continue
    [ -n "$id" ] || continue
    case "$id" in
      *sndrpirpidac*|*pcm1794a*|*rpi-dac*|*RPiDAC*) [ -n "$DAC_CARD" ] || DAC_CARD="$id" ;;
    esac
    case "$id" in
      Headphones|*Headphones*) [ -n "$JACK_CARD" ] || JACK_CARD="$id" ;;
    esac
  done
  [ -n "$DAC_CARD" ] && [ -n "$JACK_CARD" ]
}

card_num() {
  awk -v n="$1" '
    match($0, /\[[^]]+\]/) {
      id = substr($0, RSTART+1, RLENGTH-2)
      gsub(/ /, "", id)
      if (id == n) { print $1; exit }
    }' /proc/asound/cards
}

# ------------------------------------------------------------------ renderers

render_snippet() {
  cat <<EOF
# Managed by jukebox-audio (dual output). Do not edit by hand.
# Splits the 'volumio' pipeline into two outputs:
#   - I2S DAC with software volume (SoftMaster) -> controlled by Volumio
#   - 3.5 mm jack at a fixed level               -> not affected by volume
pcm.softvolume {
    type            plug
    slave {
        pcm         "jukeboxRoute"
        format      S32_LE
    }
}

pcm.jukeboxRoute {
    type            route
    slave {
        pcm         "jukeboxSplit"
        channels    4
    }
    ttable.0.0 1
    ttable.0.2 1
    ttable.1.1 1
    ttable.1.3 1
}

pcm.jukeboxSplit {
    type            multi
    slaves.a.pcm    "volumioSoftVol"
    slaves.a.channels 2
    slaves.b.pcm    "jukeboxJack"
    slaves.b.channels 2
    bindings.0.slave   a
    bindings.0.channel 0
    bindings.1.slave   a
    bindings.1.channel 1
    bindings.2.slave   b
    bindings.2.channel 0
    bindings.3.slave   b
    bindings.3.channel 1
}

pcm.volumioSoftVol {
    type            softvol
    slave {
        pcm         "postVolume"
    }
    control {
        name        "SoftMaster Playback Volume"
        card        "$DAC_CARD"
        device      0
    }
    max_dB 0.0
    min_dB -50.0
    resolution 100
}

pcm.jukeboxJack {
    type            plug
    slave {
        pcm {
            type    hw
            card    "$JACK_CARD"
            device  0
        }
    }
}
EOF
}

render_asound() {
  cat <<EOF
pcm.!default {
    type             empty
    slave.pcm       "volumio"
}

pcm.volumio {
    type             empty
    slave.pcm       "softvolume"
}

$(render_snippet)

pcm.postVolume {
    type             empty
    slave.pcm       "volumioOutput"
}


# There is always a plug before the hardware to be safe
pcm.volumioOutput {
    type plug
    slave.pcm "volumioHw"
}

pcm.volumioHw {
    type hw
    card "$DAC_CARD"
}
EOF
}

write_elements_state() {
  local file="$1" value="${2:-99}"
  cat >"$file" <<EOF
state.$DAC_CARD {
	control.1 {
		iface MIXER
		name 'SoftMaster Playback Volume'
		value.0 $value
		value.1 $value
		comment {
			access 'read write user'
			type INTEGER
			count 2
			range '0 - 99'
		}
	}
	control.2 {
		iface MIXER
		name 'SoftMaster Playback Switch'
		value true
		comment {
			access 'read write user'
			type BOOLEAN
			count 2
		}
	}
}
EOF
}

# --------------------------------------------------------------- config edits

patch_config_json() {
  python3 - "$ALSA_CONFIG_JSON" "$DAC_CARD" <<'PY'
import json, sys
path, dac = sys.argv[1], sys.argv[2]
with open(path) as fh:
    d = json.load(fh)
label = (d.get("outputdevicename") or {}).get("value") or "R-PI DAC"
changed = False

def setv(key, typ, val):
    global changed
    cur = d.get(key)
    if cur is None:
        d[key] = {"type": typ, "value": val}
        changed = True
        return
    if cur.get("value") != val:
        cur["value"] = val
        changed = True
    cur.setdefault("type", typ)

setv("softvolume", "boolean", True)
setv("mixer", "string", "SoftMaster")
setv("mixer_type", "string", "Software")
setv("outputdevicecardname", "string", dac)
setv("outputdevicename", "string", label)
od = (d.get("outputdevice") or {}).get("value")
if od is not None:
    setv("softvolumenumber", "string", str(od))
with open(path, "w") as fh:
    fh.write(json.dumps(d, separators=(",", ":")) + "\n")
print("changed" if changed else "unchanged")
PY
}

patch_special_cards() {
  python3 - "$SPECIAL_CARDS_JSON" "$ALSA_CONFIG_JSON" <<'PY'
import json, sys
special_path, cfg_path = sys.argv[1], sys.argv[2]
try:
    with open(cfg_path) as fh:
        label = (json.load(fh).get("outputdevicename") or {}).get("value") or "R-PI DAC"
except Exception:
    label = "R-PI DAC"
try:
    with open(special_path) as fh:
        d = json.load(fh)
    if not isinstance(d, dict):
        d = {}
except Exception:
    d = {}
want = ['mixer_type "none"', 'buffer_time "200000"', 'period_time "50000"']
if d.get(label) != want:
    d[label] = want
    with open(special_path, "w") as fh:
        fh.write(json.dumps(d, indent=2) + "\n")
    print("changed")
else:
    print("unchanged")
PY
}

# ---------------------------------------------------------------- alsa state

# Clean the stored ALSA state: drop leftover test controls, drop the old bare
# 'SoftMaster' element anywhere (replaced by the Playback Volume/Switch pair
# on the DAC card), and make sure that pair is present so it is restored at
# every boot.
fix_state() {
  python3 - "$1" "$DAC_CARD" "$JUNK_CONTROLS" <<'PY'
import re, sys
path, dac, junk_re = sys.argv[1], sys.argv[2], sys.argv[3]
junk = set(junk_re.split("|"))
with open(path) as fh:
    text = fh.read()

def split_blocks(section):
    parts = re.split(r'(?=^\tcontrol\.)', section, flags=re.M)
    return parts[0], parts[1:]

def ctl_name(block):
    m = re.search(r"name '?([^'\n]+)'?", block)
    return m.group(1).strip() if m else ""

out = []
seen_dac = False
for chunk in re.split(r'(?=^state\.)', text, flags=re.M):
    m = re.match(r'state\.([^\s{]+)', chunk)
    if not m:
        out.append(chunk)
        continue
    card = m.group(1)
    head, blocks = split_blocks(chunk)
    kept = []
    for b in blocks:
        name = ctl_name(b)
        if name in junk:
            continue
        if name == "SoftMaster":       # old bare element, drop everywhere
            continue
        kept.append(b)
    if card == dac:
        seen_dac = True
        have = {ctl_name(b) for b in kept}
        nums = [int(m.group(1)) for b in kept
                for m in [re.match(r'\tcontrol\.(\d+)', b)] if m]
        num = (max(nums) + 1) if nums else 1
        if "SoftMaster Playback Volume" not in have:
            kept.append(
                "\tcontrol.%d {\n\t\tiface MIXER\n\t\tname 'SoftMaster Playback Volume'\n"
                "\t\tvalue.0 99\n\t\tvalue.1 99\n\t\tcomment {\n\t\t\taccess 'read write user'\n"
                "\t\t\ttype INTEGER\n\t\t\tcount 2\n\t\t\trange '0 - 99'\n\t\t}\n\t}\n" % num)
            num += 1
        if "SoftMaster Playback Switch" not in have:
            kept.append(
                "\tcontrol.%d {\n\t\tiface MIXER\n\t\tname 'SoftMaster Playback Switch'\n"
                "\t\tvalue true\n\t\tcomment {\n\t\t\taccess 'read write user'\n"
                "\t\t\ttype BOOLEAN\n\t\t\tcount 2\n\t\t}\n\t}\n" % num)
    out.append(head + "".join(kept))
if not seen_dac:
    out.append(
        "state.%s {\n\tcontrol.1 {\n\t\tiface MIXER\n\t\tname 'SoftMaster Playback Volume'\n"
        "\t\tvalue.0 99\n\t\tvalue.1 99\n\t\tcomment {\n\t\t\taccess 'read write user'\n"
        "\t\t\ttype INTEGER\n\t\t\tcount 2\n\t\t\trange '0 - 99'\n\t\t}\n\t}\n"
        "\tcontrol.2 {\n\t\tiface MIXER\n\t\tname 'SoftMaster Playback Switch'\n"
        "\t\tvalue true\n\t\tcomment {\n\t\t\taccess 'read write user'\n"
        "\t\t\ttype BOOLEAN\n\t\t\tcount 2\n\t\t}\n\t}\n}\n" % dac)
with open(path, "w") as fh:
    fh.write("".join(out))
print("fixed")
PY
}

# ------------------------------------------------------------------- actions

set_jack_level() {
  amixer -q -c "$JACK_CARD" sset PCM "$JACK_LEVEL" >/dev/null 2>&1 \
    || warn "could not set jack level on $JACK_CARD"
  amixer -q -c "$JACK_CARD" sset PCM unmute >/dev/null 2>&1 || true
}

softmaster_volume_present() {
  # The volume/switch elements are queried through their merged base name.
  amixer -q -c "$DAC_CARD" sget SoftMaster >/dev/null 2>&1
}

# Create the volume/switch elements when missing (restored at every boot from
# the ALSA state; created here on first install).
ensure_softmaster_elements() {
  softmaster_volume_present && return 0
  local value="${1:-99}" tmp
  tmp="$(mktemp /tmp/jukebox-elements.XXXXXX.state)"
  write_elements_state "$tmp" "$value"
  if alsactl -f "$tmp" restore "$DAC_CARD" >/dev/null 2>&1 && softmaster_volume_present; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  # fall back: open the chain once; softvol creates the volume element itself
  aplay -q -D volumio -f S16_LE -r 44100 -c 2 -d 1 /dev/zero >/dev/null 2>&1 || true
  softmaster_volume_present
}

wait_for_volumio() {
  local t=0
  until curl -sf localhost:3000/api/v1/getState >/dev/null 2>&1; do
    sleep 2
    t=$((t + 2))
    [ "$t" -ge 180 ] && return 1
  done
  return 0
}

restart_volumio() {
  local force="${1:-}" noblock="${2:-}"
  if [ "$force" != "force" ] && [ -f "$RESTART_STAMP" ]; then
    local now age
    now="$(date +%s)"
    age=$((now - $(stat -c %Y "$RESTART_STAMP" 2>/dev/null || echo 0)))
    if [ "$age" -lt "$VOLUMIO_RESTART_MIN_INTERVAL" ]; then
      log "skipping volumio restart (last restart ${age}s ago)"
      return 0
    fi
  fi
  touch "$RESTART_STAMP"
  log "restarting volumio${noblock:+ (non-blocking)}"
  if [ "$noblock" = "noblock" ]; then
    systemctl restart --no-block volumio
  else
    systemctl restart volumio
  fi
}

backup_config() {
  local ts dir
  ts="$(date +%Y%m%d-%H%M%S)"
  dir="$BACKUP_ROOT/$ts"
  mkdir -p "$dir"
  for f in /etc/asound.conf /etc/mpd.conf "$SNIPPET_PATH" "$ALSA_CONFIG_JSON" "$SPECIAL_CARDS_JSON" /var/lib/alsa/asound.state; do
    [ -e "$f" ] || continue
    cp -a "$f" "$dir/$(basename "$f")" 2>/dev/null || true
  done
  ln -sfn "$dir" "$BACKUP_ROOT/latest"
  ok "backup saved in $dir"
}

write_apply_dir() {
  mkdir -p "$APPLY_DIR"
  render_snippet >"$APPLY_DIR/snippet.conf"
  render_asound >"$APPLY_DIR/asound.conf"
  echo "$VERSION" >"$APPLY_DIR/VERSION"
  cat >"$APPLY_DIR/clean-controls.py" <<'PY'
#!/usr/bin/env python3
"""Remove leftover user mixer elements from an ALSA card (kernel side)."""
import ctypes
import ctypes.util
import re
import subprocess
import sys


def main():
    if len(sys.argv) < 3:
        print("usage: clean-controls.py CARD ELEMENT1[|ELEMENT2...]")
        return 2
    card = sys.argv[1]
    junk = set(sys.argv[2].split("|"))

    lib = ctypes.CDLL(ctypes.util.find_library("asound"))
    handle = ctypes.c_void_p()
    if lib.snd_ctl_open(ctypes.byref(handle), ("hw:%s" % card).encode(), 0) < 0:
        print("cannot open ctl hw:%s" % card)
        return 0

    out = subprocess.run(
        ["amixer", "-c", card, "controls"], capture_output=True, text=True
    ).stdout
    items = re.findall(r"numid=(\d+),iface=MIXER,name='([^']+)'", out)

    removed = []
    for numid, name in items:
        if name in junk or name == "SoftMaster":
            idp = ctypes.c_void_p()
            lib.snd_ctl_elem_id_malloc(ctypes.byref(idp))
            lib.snd_ctl_elem_id_set_numid(idp, int(numid))
            ret = lib.snd_ctl_elem_remove(handle, idp)
            lib.snd_ctl_elem_id_free(idp)
            if ret >= 0:
                removed.append(name)
            else:
                print("could not remove %s (ret=%d)" % (name, ret))
    lib.snd_ctl_close(handle)
    print("removed: %s" % (", ".join(removed) if removed else "nothing"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
  chmod 0755 "$APPLY_DIR/clean-controls.py"
  local self
  self="$(readlink -f "$0")"
  if [ "$self" != "$APPLY_DIR/jukebox-audio.sh" ]; then
    install -m 0755 "$self" "$APPLY_DIR/jukebox-audio.sh"
  fi
  ok "canonical files in $APPLY_DIR"
}

# Remove experimental/old user elements from the running kernel so they can
# never be persisted again by alsa-restore's shutdown store.
clean_kernel_controls() {
  [ -x "$APPLY_DIR/clean-controls.py" ] || return 0
  python3 "$APPLY_DIR/clean-controls.py" "$DAC_CARD" "$JUNK_CONTROLS" >/dev/null 2>&1 || true
}

install_live_files() {
  put_file "$APPLY_DIR/snippet.conf" "$SNIPPET_PATH"
  put_file "$APPLY_DIR/asound.conf" /etc/asound.conf
  ok "wrote $SNIPPET_PATH"
  ok "wrote /etc/asound.conf"
}

# Atomically install a file with the right owner (avoids races with Volumio
# regenerating the same paths).
put_file() {
  local src="$1" dst="$2" tmp
  tmp="$(dirname "$dst")/.jukebox-audio.$$"
  install -m 0644 -o volumio -g volumio "$src" "$tmp"
  mv -f "$tmp" "$dst"
}

install_units() {
  cat >/etc/systemd/system/jukebox-audio-guard.service <<EOF
[Unit]
Description=Jukebox dual-output audio guard (re-assert configuration)
Wants=alsa-restore.service
After=alsa-restore.service local-fs.target

[Service]
Type=oneshot
TimeoutStartSec=180
ExecStart=$APPLY_DIR/jukebox-audio.sh apply

[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/jukebox-audio-guard.path <<EOF
[Unit]
Description=Watch jukebox audio configuration files

[Path]
PathChanged=/etc/asound.conf
PathChanged=$SNIPPET_PATH
PathChanged=$SPECIAL_CARDS_JSON

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable jukebox-audio-guard.service >/dev/null 2>&1 || true
  systemctl enable jukebox-audio-guard.path >/dev/null 2>&1 || true
  systemctl start jukebox-audio-guard.path >/dev/null 2>&1 || true
  ok "guard units installed"
}

alsa_playback_test() {
  local dn jn ok_dac=0 ok_jack=0 pid
  dn="$(card_num "$DAC_CARD")"
  jn="$(card_num "$JACK_CARD")"
  [ -n "$dn" ] && [ -n "$jn" ] || return 1
  aplay -q -D volumio -f S16_LE -r 44100 -c 2 -d 3 /dev/zero >/dev/null 2>&1 &
  pid=$!
  sleep 1.5
  grep -q RUNNING /proc/asound/card${dn}/pcm0p/sub*/status 2>/dev/null && ok_dac=1
  grep -q RUNNING /proc/asound/card${jn}/pcm0p/sub*/status 2>/dev/null && ok_jack=1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$ok_dac" = 1 ] && [ "$ok_jack" = 1 ]
}

mpd_playback_test() {
  local was_playing=0 dn jn r=0 cur="" restored=0
  mpc status 2>/dev/null | grep -q '\[playing\]' && was_playing=1
  if [ "$was_playing" = 0 ]; then
    if ! mpc play >/dev/null 2>&1; then
      warn "MPD queue is empty; skipping MPD playback test"
      return 0
    fi
    sleep 4
  fi
  cur="$(amixer -c "$DAC_CARD" sget SoftMaster 2>/dev/null \
        | sed -n 's/.*Playback \([0-9]*\) \[\([0-9]*%\)\].*/\2/p' | head -1)"
  if [ -n "$cur" ]; then
    amixer -q -c "$DAC_CARD" sset SoftMaster 20% >/dev/null 2>&1 && restored=1
  fi
  dn="$(card_num "$DAC_CARD")"
  jn="$(card_num "$JACK_CARD")"
  mpc status 2>/dev/null | grep -q '\[playing\]' || r=1
  grep -q RUNNING /proc/asound/card${dn}/pcm0p/sub*/status 2>/dev/null || r=1
  grep -q RUNNING /proc/asound/card${jn}/pcm0p/sub*/status 2>/dev/null || r=1
  if [ "$restored" = 1 ]; then
    amixer -q -c "$DAC_CARD" sset SoftMaster "$cur" >/dev/null 2>&1 || true
  fi
  [ "$was_playing" = 0 ] && mpc stop >/dev/null 2>&1 || true
  return $r
}

# --------------------------------------------------------------------- modes

cmd_install() {
  require_root
  detect_cards || die "could not detect the I2S DAC / 3.5mm jack cards (looked in /proc/asound)"
  [ -d "$VOLUMIO_ASOUND_DIR" ] || die "this does not look like a Volumio install ($VOLUMIO_ASOUND_DIR missing)"

  say "Installing jukebox dual output (v$VERSION)"
  echo "    DAC card  : $DAC_CARD"
  echo "    Jack card : $JACK_CARD"
  echo "    Jack level: $JACK_LEVEL"

  local vol_state="" tmp
  vol_state="$(curl -sf localhost:3000/api/v1/getState 2>/dev/null \
    | sed -n 's/.*"volume":"\([0-9][0-9]*\)".*/\1/p' || true)"
  [ -n "$vol_state" ] || vol_state=99

  say "Backing up current configuration"
  backup_config

  say "Writing ALSA split configuration"
  write_apply_dir
  install_live_files

  say "Updating Volumio configuration"
  [ "$(patch_config_json)" = "changed" ] && ok "updated $ALSA_CONFIG_JSON" || ok "config.json already correct"
  [ "$(patch_special_cards)" = "changed" ] && ok "updated $SPECIAL_CARDS_JSON" || ok "special cards config already correct"

  say "Installing guard units"
  install_units

  say "Restarting Volumio"
  restart_volumio force
  wait_for_volumio && ok "Volumio is up" || warn "Volumio did not report ready within the timeout"
  sleep 3
  systemctl is-active --quiet mpd || systemctl start mpd >/dev/null 2>&1 || true

  say "Setting output levels"
  set_jack_level
  clean_kernel_controls
  tmp="$(mktemp /tmp/jukebox-elements.XXXXXX.state)"
  write_elements_state "$tmp" "$vol_state"
  alsactl -f "$tmp" restore "$DAC_CARD" >/dev/null 2>&1 || true
  rm -f "$tmp"
  if softmaster_volume_present; then
    ok "SoftMaster volume control ready on $DAC_CARD (volume ${vol_state}%)"
  else
    warn "SoftMaster volume control not created yet; it will appear on first playback"
  fi
  alsactl store 2>/dev/null && ok "ALSA state stored" || warn "alsactl store failed"
  fix_state /var/lib/alsa/asound.state
  ok "ALSA state cleaned (leftover controls removed)"

  cmd_verify || true

  say "Done"
  cat <<EOF
    Installed. A reboot is recommended to verify everything comes up cleanly.

    * DAC (speakers) : volume controlled by Volumio as usual.
    * 3.5 mm jack    : constant fixed level ($JACK_LEVEL), for the analyser.
    * Revert anytime : sudo $0 uninstall
    * Logs           : $LOG_FILE and 'journalctl -u jukebox-audio-guard'
EOF
}

cmd_apply() {
  require_root
  log "apply: start"
  [ -d "$APPLY_DIR" ] || { log "apply: not installed"; exit 0; }
  sleep 2
  if ! detect_cards; then
    log "apply: audio cards not found; nothing to do"
    exit 0
  fi

  local fixed_s=0 fixed_a=0 fixed_x=0 fixed_c=0 out

  if [ ! -f "$SNIPPET_PATH" ] || ! grep -q jukeboxSplit "$SNIPPET_PATH" 2>/dev/null; then
    put_file "$APPLY_DIR/snippet.conf" "$SNIPPET_PATH"
    fixed_s=1
    log "apply: restored ALSA snippet"
  fi
  if [ ! -f /etc/asound.conf ] || ! grep -q jukeboxSplit /etc/asound.conf 2>/dev/null; then
    put_file "$APPLY_DIR/asound.conf" /etc/asound.conf
    fixed_a=1
    log "apply: restored /etc/asound.conf"
  fi
  out="$(patch_special_cards)"
  [ "$out" = "changed" ] && { fixed_x=1; log "apply: fixed special_cards_config.json"; }
  out="$(patch_config_json)"
  [ "$out" = "changed" ] && { fixed_c=1; log "apply: fixed alsa_controller config.json"; }

  set_jack_level
  ensure_softmaster_elements || true
  clean_kernel_controls

  if [ "$fixed_c" = 1 ] || [ "$fixed_x" = 1 ]; then
    restart_volumio "" noblock
    systemctl is-active --quiet mpd || systemctl start --no-block mpd >/dev/null 2>&1 || true
  elif [ "$fixed_s" = 1 ] || [ "$fixed_a" = 1 ]; then
    systemctl restart --no-block mpd >/dev/null 2>&1 || true
  fi
  log "apply: done (snippet=$fixed_s asound=$fixed_a special=$fixed_x config=$fixed_c)"
}

cmd_verify() {
  local rc=0 jraw volparsed

  say "Verification"

  if grep -q jukeboxSplit "$SNIPPET_PATH" 2>/dev/null; then
    ok "Volumio ALSA snippet contains the dual-output split"
  else
    fail "ALSA snippet missing or replaced: $SNIPPET_PATH"; rc=$((rc + 1))
  fi

  if grep -q jukeboxSplit /etc/asound.conf 2>/dev/null; then
    ok "/etc/asound.conf wired through the split chain"
  else
    fail "/etc/asound.conf is not wired through the split chain"; rc=$((rc + 1))
  fi

  if grep -q "SoftMaster Playback Volume" /etc/asound.conf 2>/dev/null \
     && grep -q "$DAC_CARD" /etc/asound.conf 2>/dev/null; then
    ok "volume control bound to the DAC card only"
  else
    fail "volume control is not bound to the DAC card"; rc=$((rc + 1))
  fi

  if grep -q 'mixer_type[[:space:]]*"none"' /etc/mpd.conf 2>/dev/null; then
    ok "MPD mixer disabled (MPD volume cannot touch the jack)"
  else
    fail "MPD mixer not disabled in /etc/mpd.conf"; rc=$((rc + 1))
  fi

  if grep -q 'buffer_time' /etc/mpd.conf 2>/dev/null; then
    ok "MPD buffer settings for the split chain present"
  else
    warn "MPD buffer_time/period_time missing (MPD may fail to open the split chain)"
  fi

  if python3 - "$ALSA_CONFIG_JSON" "$DAC_CARD" <<'PY' >/dev/null 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
g = lambda k: (d.get(k) or {}).get("value")
assert g("softvolume") in (True, "true")
assert g("mixer") == "SoftMaster"
assert g("mixer_type") == "Software"
assert g("outputdevicecardname") == sys.argv[2]
PY
  then
    ok "Volumio volume settings point at the DAC"
  else
    fail "Volumio alsa_controller config.json is not set up as expected"; rc=$((rc + 1))
  fi

  jraw="$(amixer -c "$JACK_CARD" sget PCM 2>/dev/null | sed -n 's/^ *Mono: Playback \([0-9-]*\).*/\1/p' | head -1)"
  if [ -n "$jraw" ]; then
    if [ "$jraw" = "$JACK_LEVEL_RAW" ]; then
      ok "jack level is fixed (raw $jraw)"
    else
      fail "jack level is raw $jraw, expected $JACK_LEVEL_RAW"; rc=$((rc + 1))
    fi
    if amixer -c "$JACK_CARD" sget PCM 2>/dev/null | grep -q '\[on\]'; then
      ok "jack output is unmuted"
    else
      fail "jack output is muted"; rc=$((rc + 1))
    fi
  else
    warn "could not read the jack level"
  fi

  if softmaster_volume_present; then
    volparsed="$(amixer -M get -c "$DAC_CARD" SoftMaster 2>/dev/null \
      | awk '$0~/%/{print}' | cut -d '[' -f2 | tr -d '[]%' | head -1)"
    if [ -n "$volparsed" ]; then
      ok "volume control present and readable (${volparsed}%)"
    else
      fail "volume control present but not readable as 'SoftMaster'"; rc=$((rc + 1))
    fi
  else
    warn "volume control not materialized yet (appears on first playback)"
  fi

  if alsa_playback_test; then
    ok "split chain opens both outputs simultaneously"
  else
    fail "could not open the split chain on both outputs (is something else playing?)"; rc=$((rc + 1))
  fi

  if [ "$PLAY_TEST" = 1 ]; then
    if mpd_playback_test; then
      ok "MPD playback runs through the split chain"
    else
      fail "MPD playback test failed"; rc=$((rc + 1))
    fi
  fi

  if [ "$rc" = 0 ]; then
    say "All checks passed"
  else
    say "$rc check(s) failed"
  fi
  return "$rc"
}

cmd_status() {
  echo "jukebox-audio v$VERSION"
  if [ -d "$APPLY_DIR" ]; then echo "installed       : yes ($APPLY_DIR)"; else echo "installed       : no"; fi
  echo "guard service   : $(systemctl is-enabled jukebox-audio-guard.service 2>/dev/null || echo -) / $(systemctl is-active jukebox-audio-guard.service 2>/dev/null || echo -)"
  echo "guard watcher   : $(systemctl is-enabled jukebox-audio-guard.path 2>/dev/null || echo -) / $(systemctl is-active jukebox-audio-guard.path 2>/dev/null || echo -)"
  if grep -q jukeboxSplit /etc/asound.conf 2>/dev/null; then echo "dual-output     : configured"; else echo "dual-output     : NOT configured"; fi
  if grep -q 'mixer_type[[:space:]]*"none"' /etc/mpd.conf 2>/dev/null; then echo "mpd mixer       : disabled"; else echo "mpd mixer       : active (may affect jack)"; fi
}

cmd_uninstall() {
  require_root
  say "Uninstalling jukebox dual output"
  systemctl disable --now jukebox-audio-guard.path >/dev/null 2>&1 || true
  systemctl disable --now jukebox-audio-guard.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/jukebox-audio-guard.path /etc/systemd/system/jukebox-audio-guard.service
  systemctl daemon-reload
  ok "guard units removed"

  if [ -d "$BACKUP_ROOT/latest" ]; then
    local pair src b
    for pair in "/etc/asound.conf:asound.conf" \
                "/etc/mpd.conf:mpd.conf" \
                "$SNIPPET_PATH:softvolume.postVolume.conf" \
                "$ALSA_CONFIG_JSON:config.json" \
                "$SPECIAL_CARDS_JSON:special_cards_config.json" \
                "/var/lib/alsa/asound.state:asound.state"; do
      src="${pair%%:*}"
      b="${pair##*:}"
      if [ -f "$BACKUP_ROOT/latest/$b" ]; then
        cp -a "$BACKUP_ROOT/latest/$b" "$src" && ok "restored $src"
      fi
    done
  else
    warn "no backup found; Volumio will regenerate its own configuration"
  fi

  rm -rf "$APPLY_DIR"
  systemctl restart volumio >/dev/null 2>&1 || true
  systemctl restart mpd >/dev/null 2>&1 || true
  ok "uninstalled (reboot recommended)"
}

main() {
  local mode=""
  for arg in "$@"; do
    case "$arg" in
      --with-playback) PLAY_TEST=1 ;;
      -h|--help) usage; exit 0 ;;
      install|apply|verify|status|uninstall) mode="$arg" ;;
      *) die "unknown argument: $arg" ;;
    esac
  done
  [ -n "$mode" ] || { usage; exit 1; }
  case "$mode" in
    install)   cmd_install ;;
    apply)     cmd_apply ;;
    verify)    require_root; detect_cards || die "could not detect audio cards"; cmd_verify ;;
    status)    cmd_status ;;
    uninstall) cmd_uninstall ;;
  esac
}

main "$@"
