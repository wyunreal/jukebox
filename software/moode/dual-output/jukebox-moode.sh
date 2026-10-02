#!/usr/bin/env bash
#
# jukebox-moode.sh - jukebox dual output + tone control for moOde audio player 10
#
# moOde already ships CamillaDSP 4.1.3 and the scripple "cdsp" ALSA plugin
# (/etc/alsa/conf.d/camilladsp.conf). Its output chain is:
#
#   MPD -> _audioout -> [peppy|camilladsp|plughw] -> sound card
#
# This installer turns the DAC branch into a CamillaDSP tone stage and adds a
# second, fixed-level branch for the spectrum analyser:
#
#   MPD -> _audioout -> jukeboxSplit (multi)
#        |- a: camilladsp  (CamillaDSP: balance + bass + treble + volume) -> DAC
#        '- b: jukeboxAnalyser (fixed level)                                -> USB
#
# When the analyser card is absent the chain degrades to DAC-only: _audioout
# goes straight to camilladsp (still with tone + balance + volume).
#
# Volume must be moOde's "CamillaDSP" type (mpdmixer=null +
# camilladsp_volume_sync=on): the volume then lives in the CamillaDSP fader,
# so only the DAC branch is affected and the analyser keeps a fixed level.
#
# Commands:
#   sudo ./jukebox-moode.sh install [--second-output usb|none]
#   sudo ./jukebox-moode.sh verify [--with-playback]
#   sudo ./jukebox-moode.sh apply       # re-assert (used by the guard unit)
#   sudo ./jukebox-moode.sh status
#   sudo ./jukebox-moode.sh uninstall
#
# Options:
#   --second-output usb|none       analyser branch (default: usb)
#   --tone / --no-tone             bass+treble via CamillaDSP (default: on)
#   --analyser-trim / --no-analyser-trim   fixed low-shelf on the analyser
#                                  branch (default: on)
#   --analyser-freq HZ             shelf corner (default: 60)
#   --analyser-gain dB             shelf gain (default: -6.02 = half level)
#   --analyser-q Q                 shelf Q (default: 0.5)
#   --mpd-buffer US                MPD ALSA buffer (default: 3000000 = 3 s)
#   --no-patch-cdsp                keep moOde's stock cdsp plugin
#
set -euo pipefail

VERSION="1.0.0"

SCRIPT_BASENAME="$(basename "$0")"
APPLY_DIR="/usr/local/jukebox-moode"
CONFIG_ENV="$APPLY_DIR/config.env"
LOG_FILE="/var/log/jukebox-moode.log"
MOODE_DB="/var/local/www/db/moode-sqlite3.db"
ALSA_CONF_DIR="/etc/alsa/conf.d"
AUDIOOUT_CONF="$ALSA_CONF_DIR/_audioout.conf"
SPLIT_CONF="$ALSA_CONF_DIR/90-jukebox-split.conf"
CAMILLA_DIR="/usr/share/camilladsp"
CAMILLA_CONFIGS="$CAMILLA_DIR/configs"
CAMILLA_WORKING="$CAMILLA_DIR/working_config.yml"
TONE_CONFIG="$CAMILLA_CONFIGS/jukebox-tone.yml"
TONE_NAME="jukebox-tone"
BACKUP_ROOT="/var/backups/jukebox-moode"
GUARD_SERVICE="/etc/systemd/system/jukebox-moode-guard.service"
GUARD_PATH="/etc/systemd/system/jukebox-moode-guard.path"
UDEV_RULE="/etc/udev/rules.d/89-jukebox-moode.rules"

# Tone defaults (same as the Volumio package)
TONE_ENABLE="${JB_TONE:-on}"
TONE_BASS_FREQ="${JB_TONE_BASS_FREQ:-120}"
TONE_TREBLE_FREQ="${JB_TONE_TREBLE_FREQ:-6000}"
TONE_SHELF_Q="${JB_TONE_Q:-0.7}"
TONE_MAX_DB="${JB_TONE_MAX_DB:-12}"

SECOND_OUTPUT="${JB_SECOND_OUTPUT:-usb}"   # usb | none
DAC_CARD="${JB_DAC_CARD:-sndrpirpidac}"
USB_CARD="${JB_USB_CARD:-Device}"
USB_RATE="${JB_USB_RATE:-48000}"
CHUNKSIZE="${JB_CHUNKSIZE:-4096}"
MPD_BUFFER_TIME="${JB_MPD_BUFFER_TIME:-3000000}"   # 3 s, absorbs player stalls
PLAY_TEST=0

# Analyser bass trim (same design as the Volumio package): a fixed low-shelf
# on the analyser branch only, to compensate the spectrum analyser's hardware
# bass over-read. Implemented with CAPS Eq4p via the alsaequal "equal" ALSA
# plugin (moOde ships both).
ANALYSER_TRIM="${JB_ANALYSER_TRIM:-on}"          # on | off
ANALYSER_FREQ_HZ="${JB_ANALYSER_FREQ_HZ:-60}"
ANALYSER_GAIN_DB="${JB_ANALYSER_GAIN_DB:--6.02}"
ANALYSER_Q="${JB_ANALYSER_Q:-0.5}"
EQ_CONTROLS_SRC="$APPLY_DIR/analyser-eq.bin"
EQ_CONTROLS_DEST="/var/lib/jukebox-moode/analyser-eq.bin"
EQ_LIBRARY="/usr/lib/ladspa/caps.so"
EQ_MODULE="Eq4p"
EQ_CAPS_ID=2608

# Patched cdsp plugin (underrun concealment + atomic config write). moOde
# ships its own build; this package installs ours when requested. The build
# runs natively on the Pi (moOde has gcc + libasound2-dev).
PATCH_CDSP="${JB_PATCH_CDSP:-auto}"   # auto | on | off
CDSP_PLUGIN_DEST="/usr/lib/aarch64-linux-gnu/alsa-lib/libasound_module_pcm_cdsp.so"

# ------------------------------------------------------------------- helpers

log()  { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG_FILE" 2>/dev/null || true; }
say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*"; }
fail() { printf '    \033[1;31mFAIL\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"; }

card_num() { # card_num NAME -> number or empty
  local n="$1" i id
  for i in 0 1 2 3 4 5 6 7; do
    id="$(cat /proc/asound/card$i/id 2>/dev/null || true)"
    [ "$id" = "$n" ] && { echo "$i"; return 0; }
  done
  return 1
}

analyser_available() {
  [ "$SECOND_OUTPUT" = "usb" ] && [ -n "$(card_num "$USB_CARD" 2>/dev/null || true)" ]
}

# The analyser branch must hit the USB card at full level: the hardware mixer
# of those cheap cards powers up quite low (29% on our C-Media). The Volumio
# package has the equivalent step; without it the analyser sees a very weak
# signal even though everything looks "RUNNING".
set_analyser_level() {
  analyser_available || return 0
  local usbnum
  usbnum="$(card_num "$USB_CARD" 2>/dev/null || true)"
  [ -n "$usbnum" ] || return 0
  amixer -c "$usbnum" sset PCM 100% unmute >/dev/null 2>&1 || true
  # Persist it too: alsa-restore runs at boot and would put back whatever was
  # stored in asound.state (often the card's low power-on level).
  alsactl store "$usbnum" >/dev/null 2>&1 || alsactl store >/dev/null 2>&1 || true
}

# --------------------------------------------------------------- config file

load_config_env() {
  if [ -f "$CONFIG_ENV" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_ENV"
    SECOND_OUTPUT="${JB_SECOND_OUTPUT:-usb}"
    DAC_CARD="${JB_DAC_CARD:-sndrpirpidac}"
    USB_CARD="${JB_USB_CARD:-Device}"
    USB_RATE="${JB_USB_RATE:-48000}"
    TONE_ENABLE="${JB_TONE:-on}"
    TONE_BASS_FREQ="${JB_TONE_BASS_FREQ:-120}"
    TONE_TREBLE_FREQ="${JB_TONE_TREBLE_FREQ:-6000}"
    TONE_SHELF_Q="${JB_TONE_Q:-0.7}"
    TONE_MAX_DB="${JB_TONE_MAX_DB:-12}"
    CHUNKSIZE="${JB_CHUNKSIZE:-4096}"
    MPD_BUFFER_TIME="${JB_MPD_BUFFER_TIME:-3000000}"
    ANALYSER_TRIM="${JB_ANALYSER_TRIM:-on}"
    ANALYSER_FREQ_HZ="${JB_ANALYSER_FREQ_HZ:-60}"
    ANALYSER_GAIN_DB="${JB_ANALYSER_GAIN_DB:--6.02}"
    ANALYSER_Q="${JB_ANALYSER_Q:-0.5}"
  fi
}

write_config_env() {
  mkdir -p "$APPLY_DIR"
  cat >"$CONFIG_ENV" <<EOF
# jukebox-moode configuration (edit with care; rerun install to regenerate)
JB_SECOND_OUTPUT=$SECOND_OUTPUT
JB_DAC_CARD=$DAC_CARD
JB_USB_CARD=$USB_CARD
JB_USB_RATE=$USB_RATE
JB_TONE=$TONE_ENABLE
JB_TONE_BASS_FREQ=$TONE_BASS_FREQ
JB_TONE_TREBLE_FREQ=$TONE_TREBLE_FREQ
JB_TONE_Q=$TONE_SHELF_Q
JB_TONE_MAX_DB=$TONE_MAX_DB
JB_CHUNKSIZE=$CHUNKSIZE
JB_MPD_BUFFER_TIME=$MPD_BUFFER_TIME
JB_ANALYSER_TRIM=$ANALYSER_TRIM
JB_ANALYSER_FREQ_HZ=$ANALYSER_FREQ_HZ
JB_ANALYSER_GAIN_DB=$ANALYSER_GAIN_DB
JB_ANALYSER_Q=$ANALYSER_Q
EOF
  chmod 0644 "$CONFIG_ENV"
}

# ------------------------------------------------------------- ALSA split

render_split_conf() {
  cat <<EOF
# Managed by jukebox-moode. Do not edit by hand.
#
# Splits moOde's _audioout into two branches:
#   a) CamillaDSP tone/volume stage  -> I2S DAC (speakers)
#   b) fixed-level analyser feed     -> USB sound card (spectrum analyser)
#
# The split happens before CamillaDSP, so the analyser branch never sees the
# volume or tone changes applied to the DAC branch.

pcm.jukeboxSplit {
    type            plug
    slave {
        pcm         "jukeboxRoute"
        format      S32_LE
    }
}

# Expand 2 -> 4 channels and duplicate L/R (rows) before the multi. Without
# this stage the multi only receives 2 channels, so branch b (bound to
# channels 2/3) would read silence. Same structure as the Volumio package.
pcm.jukeboxRoute {
    type            route
    slave {
        pcm         "jukeboxSplitRaw"
        channels    4
    }
    ttable.0.0 1
    ttable.0.2 1
    ttable.1.1 1
    ttable.1.3 1
}

pcm.jukeboxSplitRaw {
    type            multi
    slaves.a.pcm    "camilladsp"
    slaves.a.channels 2
    slaves.b.pcm    "jukeboxAnalyser"
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

pcm.jukeboxAnalyser {
    type            plug
    slave {
        pcm         "jukeboxAnalyserEq"
        rate        $USB_RATE
    }
}

$(render_analyser_eq "jukeboxAnalyserRaw" "$USB_RATE")

pcm.jukeboxAnalyserRaw {
    type            plug
    slave {
        pcm         "hw:CARD=$USB_CARD,DEV=0"
        rate        $USB_RATE
    }
}
EOF
}

# Emit the analyser-branch filter block. With the trim on, a CAPS Eq4p
# low-shelf (via alsaequal) attenuates the deep bass for the analyser only;
# with it off, a plain plug keeps the branch transparent. Same design as the
# Volumio package.
render_analyser_eq() {
  local target="$1" rate="$2"
  if [ "$ANALYSER_TRIM" = "on" ]; then
    cat <<EOF
# Analyser bass trim: low-shelf ${ANALYSER_FREQ_HZ} Hz ${ANALYSER_GAIN_DB} dB (Q ${ANALYSER_Q}).
# Fixed via a deterministic controls file; affects this branch only.
# The wrapper plug pins rate + FLOAT for the 'equal' plugin (which only
# accepts float); without that the ALSA 'multi' plugin fails to negotiate.
pcm.jukeboxAnalyserEq {
    type            plug
    slave {
        pcm         "jukeboxAnalyserEqDsp"
        rate        ${rate:-48000}
        format      FLOAT_LE
    }
}

pcm.jukeboxAnalyserEqDsp {
    type            equal
    slave.pcm       "$target"
    controls        "$EQ_CONTROLS_DEST"
    library         "$EQ_LIBRARY"
    module          "$EQ_MODULE"
    channels        2
}
EOF
  else
    cat <<EOF
# Analyser bass trim disabled: transparent pass-through.
pcm.jukeboxAnalyserEq {
    type            plug
    slave.pcm       "$target"
}
EOF
  fi
}

# Deterministic alsaequal controls file for CAPS Eq4p: band a = low shelf at
# ANALYSER_FREQ_HZ / ANALYSER_GAIN_DB / ANALYSER_Q, bands b/c/d off.
# Layout (alsaequal LADSPA_Control): header (4 unsigned longs + 2 ints, so
# 40 bytes on aarch64 and 24 on armhf), then one 72-byte record per control
# port {int32 index; float data[16]; int32 type}, then a trailing float[16]
# per port. Kept byte-stable so the file is identical every install.
write_analyser_eq_controls() {
  python3 - "$1" "$ANALYSER_FREQ_HZ" "$ANALYSER_GAIN_DB" "$ANALYSER_Q" "$EQ_CAPS_ID" <<'PY'
import struct, sys
path, f, gain, q, uid = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), int(sys.argv[5])
channels = 2
spec = [(0, 0.0, 0), (1, f, 0), (2, q, 0), (3, gain, 0),          # a: low shelf
        (4, -1.0, 0), (5, 529.161, 0), (6, 0.5, 0), (7, 0.0, 0),  # b: off
        (8, -1.0, 0), (9, 529.161, 0), (10, 0.25, 0), (11, 0.0, 0),  # c: off
        (12, -1.0, 0), (13, 2721.776, 0), (14, 0.25, 0), (15, 0.0, 0),  # d: off
        (16, 3.0, 1)]                                             # _latency (out)
body = bytearray()
for idx, val, typ in spec:
    rec = bytearray(72)
    struct.pack_into('<i', rec, 0, idx)
    for c in range(channels):
        struct.pack_into('<f', rec, 4 + c * 4, val)
    struct.pack_into('<i', rec, 68, typ)
    body += rec
tail = bytearray()
for idx, val, typ in spec:
    for c in range(channels):
        tail += struct.pack('<f', val)
# LADSPA_Control uses C 'unsigned long' fields: 8 bytes on 64-bit (aarch64),
# 4 on 32-bit (armhf). The header size must match the running alsaequal.
if struct.calcsize('P') == 8:
    hdr_size, hdr_fmt = 40, '<4Q2i'
else:
    hdr_size, hdr_fmt = 24, '<6I'
length = hdr_size + len(body) + len(tail)
hdr = struct.pack(hdr_fmt, length, uid, channels, len(spec), 17, 18)
open(path, 'wb').write(hdr + bytes(body) + bytes(tail))
print("wrote %s (%d bytes)" % (path, length))
PY
}

# Point moOde's _audioout at the jukebox chain. moOde rewrites this line
# whenever the output device / DSP selection changes, so it is re-asserted by
# the guard unit.
point_audioout() { # point_audioout split|tone
  [ -f "$AUDIOOUT_CONF" ] || die "$AUDIOOUT_CONF not found (is moOde installed?)"
  local target
  if [ "$1" = "split" ]; then target="jukeboxSplit"; else target="camilladsp"; fi
  if grep -q "^slave.pcm \"$target\"" "$AUDIOOUT_CONF"; then
    chmod 0644 "$AUDIOOUT_CONF"
    return 0
  fi
  sed -i "s/^slave.pcm.*/slave.pcm \"$target\"/" "$AUDIOOUT_CONF"
  # ALSA confs under /etc/alsa/conf.d must stay readable by mpd/other users;
  # a redirect during testing must never leave them 0600.
  chmod 0644 "$AUDIOOUT_CONF"
  [ -f "$SPLIT_CONF" ] && chmod 0644 "$SPLIT_CONF"
}

restore_audioout() {
  [ -f "$AUDIOOUT_CONF" ] || return 0
  sed -i 's/^slave.pcm.*/slave.pcm "peppy"/' "$AUDIOOUT_CONF"
  chmod 0644 "$AUDIOOUT_CONF"
}

# ------------------------------------------------------- CamillaDSP tone config

render_tone_config() {
  cat <<EOF
---
# Managed by jukebox-moode: tone (bass/treble) + balance for the jukebox.
# The "gain" values are rewritten live by jukebox-pots followed by a SIGHUP;
# moOde may also re-select this file through working_config.yml.
devices:
  samplerate: 44100
  chunksize: $CHUNKSIZE
  queuelimit: 1
  volume_ramp_time: 150
  capture:
    type: Stdin
    channels: 2
    format: S32_LE
  playback:
    type: Alsa
    channels: 2
    device: "plughw:CARD=$DAC_CARD,DEV=0"
    format: S32_LE

filters:
  balance_l:
    type: Gain
    parameters:
      gain: 0.0
  balance_r:
    type: Gain
    parameters:
      gain: 0.0
  bass:
    type: Biquad
    parameters:
      type: Lowshelf
      freq: $TONE_BASS_FREQ
      q: $TONE_SHELF_Q
      gain: 0.0
  treble:
    type: Biquad
    parameters:
      type: Highshelf
      freq: $TONE_TREBLE_FREQ
      q: $TONE_SHELF_Q
      gain: 0.0

pipeline:
  - type: Filter
    channels: [0]
    names: [balance_l]
  - type: Filter
    channels: [1]
    names: [balance_r]
  - type: Filter
    channels: [0, 1]
    names: [bass, treble]
EOF
}

install_tone_config() {
  mkdir -p "$CAMILLA_CONFIGS"
  local tmp
  tmp="$(mktemp "$CAMILLA_CONFIGS/.jukebox-tone.XXXXXX")"
  render_tone_config >"$tmp"
  # Keep the current gains (tone/balance) across reinstalls.
  if [ -f "$TONE_CONFIG" ]; then
    python3 - "$TONE_CONFIG" "$tmp" <<'PY'
import re, sys
old, new = open(sys.argv[1]).read(), open(sys.argv[2]).read()
for which in ("Lowshelf", "Highshelf"):
    m = re.search(r"type:\s*%s\b(?:[^\n]*\n)*?[^\n]*?gain:\s*([-+]?[0-9]*\.?[0-9]+)" % which, old)
    if m:
        new = re.sub(r"(type:\s*%s\b(?:[^\n]*\n)*?[^\n]*?gain:\s*)[-+]?[0-9]*\.?[0-9]+" % which,
                     lambda mm, v=m.group(1): mm.group(1) + v, new, count=1)
for name in ("balance_l", "balance_r"):
    m = re.search(r"(%s:\s*\n(?:[^\n]*\n)*?[^\n]*?gain:\s*)([-+]?[0-9]*\.?[0-9]+)" % name, old)
    if m:
        new = re.sub(r"(%s:\s*\n(?:[^\n]*\n)*?[^\n]*?gain:\s*)([-+]?[0-9]*\.?[0-9]+)" % name,
                     lambda mm, v=m.group(2): mm.group(1) + v, new, count=1)
open(sys.argv[2], "w").write(new)
PY
  fi
  chmod 0666 "$tmp"
  mv -f "$tmp" "$TONE_CONFIG"
  ln -sfn "$TONE_CONFIG" "$CAMILLA_WORKING"
}

# moOde state: select our config and switch volume to the CamillaDSP fader.
# The /etc/mpd.conf regeneration (mixer_type null + buffer_time) and the
# mpd2cdspvolume service are handled by moode-sync.php + systemctl.
ensure_moode_state() {
  sqlite3 "$MOODE_DB" "UPDATE cfg_system SET value='$TONE_NAME.yml' WHERE param='camilladsp';"
  sqlite3 "$MOODE_DB" "UPDATE cfg_system SET value='on' WHERE param='camilladsp_volume_sync';"
  sqlite3 "$MOODE_DB" "UPDATE cfg_mpd SET value='null' WHERE param='mixer_type';"
  sqlite3 "$MOODE_DB" "UPDATE cfg_system SET value='null' WHERE param='mpdmixer';"
  sqlite3 "$MOODE_DB" "UPDATE cfg_system SET value='null' WHERE param='mpdmixer_local';"
}

# Regenerate /etc/mpd.conf through moOde's own code so mixer_type, device and
# buffer settings stay consistent with its database.
moode_sync() {
  [ -f "$APPLY_DIR/moode-sync.php" ] || return 0
  php "$APPLY_DIR/moode-sync.php" >>"$LOG_FILE" 2>&1 || warn "moode-sync.php failed (see $LOG_FILE)"
}

enable_volume_sync() {
  systemctl enable mpd2cdspvolume >/dev/null 2>&1 || true
  # moOde starts/stops it with playback; a restart here picks up the config.
  if systemctl is-active --quiet mpd; then
    systemctl restart mpd2cdspvolume >/dev/null 2>&1 || true
  fi
}

# ------------------------------------------------------------------ install

# Set to 1 by apply_all when the live chain changed (split <-> DAC-only), so
# MPD is restarted once to re-open the new chain.
CHAIN_CHANGED=0

apply_all() {
  load_config_env
  if [ "${TONE_ENABLE:-on}" = "on" ]; then
    # Ensure the tone config exists and is complete. If moOde regenerated it
    # from its template (no shelves) or it is missing, render ours while
    # preserving whatever tone/balance gains were already set.
    if ! grep -q 'Lowshelf' "$TONE_CONFIG" 2>/dev/null; then
      install_tone_config
    fi
    # moOde may have re-pointed working_config.yml at another config.
    if [ "$(readlink -f "$CAMILLA_WORKING" 2>/dev/null)" != "$TONE_CONFIG" ]; then
      ln -sfn "$TONE_CONFIG" "$CAMILLA_WORKING"
    fi
  fi

  local prev=""
  if [ -f "$AUDIOOUT_CONF" ]; then
    prev="$(grep -m1 '^slave.pcm' "$AUDIOOUT_CONF" | sed 's/.*"\(.*\)".*/\1/')"
  fi

  if analyser_available; then
    render_split_conf >"$SPLIT_CONF"
    chmod 0644 "$SPLIT_CONF"
    point_audioout split
    set_analyser_level
    # Analyser bass trim controls file (deterministic; must stay writable by
    # whoever opens the chain).
    if [ "${ANALYSER_TRIM:-on}" = "on" ]; then
      mkdir -p "$(dirname "$EQ_CONTROLS_DEST")"
      if [ ! -f "$EQ_CONTROLS_SRC" ] || ! cmp -s "$EQ_CONTROLS_SRC" "$EQ_CONTROLS_DEST" 2>/dev/null; then
        write_analyser_eq_controls "$EQ_CONTROLS_SRC" >/dev/null 2>&1 || true
        install -m 0666 "$EQ_CONTROLS_SRC" "$EQ_CONTROLS_DEST" 2>/dev/null || true
      fi
    fi
    log "apply: split chain (DAC + USB analyser)"
  else
    rm -f "$SPLIT_CONF"
    point_audioout tone
    log "apply: DAC-only chain (analyser card not present)"
  fi

  local now=""
  if [ -f "$AUDIOOUT_CONF" ]; then
    now="$(grep -m1 '^slave.pcm' "$AUDIOOUT_CONF" | sed 's/.*"\(.*\)".*/\1/')"
  fi
  if [ "$prev" != "$now" ]; then
    CHAIN_CHANGED=1
  fi
  ensure_mpd_running
}

install_units() {
  cat >"$GUARD_SERVICE" <<EOF
[Unit]
Description=Jukebox moOde audio guard (re-assert configuration)
After=mpd.service alsa-restore.service
Wants=alsa-restore.service

[Service]
Type=oneshot
TimeoutStartSec=180
ExecStart=$APPLY_DIR/jukebox-moode.sh apply

[Install]
WantedBy=multi-user.target
EOF
  cat >"$GUARD_PATH" <<EOF
[Unit]
Description=Watch moOde audio configuration files

[Path]
PathChanged=$AUDIOOUT_CONF
PathChanged=$CAMILLA_WORKING

[Install]
WantedBy=multi-user.target
EOF
  # USB sound card hotplug: re-evaluate the chain (split <-> DAC-only) and
  # restart MPD only when the live chain actually changed.
  cat >"$UDEV_RULE" <<EOF
# Jukebox: re-evaluate the analyser branch when the USB sound card appears.
ACTION=="add", SUBSYSTEM=="sound", KERNEL=="card*", RUN+="/usr/bin/systemctl --no-block start jukebox-moode-guard.service"
ACTION=="remove", SUBSYSTEM=="sound", KERNEL=="card*", RUN+="/usr/bin/systemctl --no-block start jukebox-moode-guard.service"
EOF
  systemctl daemon-reload
  udevadm control --reload-rules >/dev/null 2>&1 || true
  systemctl enable jukebox-moode-guard.service >/dev/null 2>&1 || true
  systemctl enable --now jukebox-moode-guard.path >/dev/null 2>&1 || true
}

remove_units() {
  systemctl disable --now jukebox-moode-guard.path >/dev/null 2>&1 || true
  systemctl disable --now jukebox-moode-guard.service >/dev/null 2>&1 || true
  rm -f "$GUARD_PATH" "$GUARD_SERVICE" "$UDEV_RULE"
  systemctl daemon-reload
  udevadm control --reload-rules >/dev/null 2>&1 || true
}

backup_config() {
  local ts dir
  ts="$(date +%Y%m%d-%H%M%S)"
  dir="$BACKUP_ROOT/$ts"
  mkdir -p "$dir"
  for f in "$AUDIOOUT_CONF" "$CAMILLA_WORKING" "$MOODE_DB" /etc/mpd.conf; do
    [ -e "$f" ] || continue
    cp -a "$f" "$dir/$(basename "$f")" 2>/dev/null || true
  done
  ln -sfn "$dir" "$BACKUP_ROOT/latest"
  chmod -R go-rwx "$BACKUP_ROOT" 2>/dev/null || true
  ok "backup saved in $dir"
}

ensure_mpd_running() {
  systemctl is-active --quiet mpd || systemctl start --no-block mpd >/dev/null 2>&1 || true
}

# Build and install the patched cdsp plugin natively on the Pi. moOde ships
# the upstream plugin; ours adds underrun concealment (never kills playback)
# and atomic active-config writes (root vs mpd file ownership).
build_patched_cdsp() {
  [ "$PATCH_CDSP" = "off" ] && return 0
  local src="$APPLY_DIR/cdsp"
  if [ ! -f "$src/libasound_module_pcm_cdsp.c" ]; then
    [ "$PATCH_CDSP" = "on" ] && die "cdsp source not found in $src"
    return 0
  fi
  command -v gcc >/dev/null 2>&1 || { warn "gcc missing; keeping moOde's cdsp plugin"; return 0; }
  [ -f /usr/include/alsa/asoundlib.h ] || { warn "libasound2-dev missing; keeping moOde's cdsp plugin"; return 0; }
  if ! gcc -DPIC -std=gnu11 -O2 -fPIC -shared -I/usr/include \
        -o /tmp/libasound_module_pcm_cdsp.so "$src/libasound_module_pcm_cdsp.c" 2>>"$LOG_FILE"; then
    warn "cdsp build failed (see $LOG_FILE); keeping moOde's plugin"
    return 0
  fi
  [ -f "$CDSP_PLUGIN_DEST.moode-orig" ] || cp -a "$CDSP_PLUGIN_DEST" "$CDSP_PLUGIN_DEST.moode-orig" 2>/dev/null || true
  install -m 0644 /tmp/libasound_module_pcm_cdsp.so "$CDSP_PLUGIN_DEST"
  rm -f /tmp/libasound_module_pcm_cdsp.so
  ok "patched cdsp plugin installed (underrun concealment)"
}

# Copy the payload (cdsp sources, sync helper) from the deploy directory into
# APPLY_DIR so the guard can re-run everything from a stable location.
install_files_from_payload() {
  local here
  here="$(cd "$(dirname "$0")" && pwd)"
  mkdir -p "$APPLY_DIR"
  # The guard unit runs $APPLY_DIR/jukebox-moode.sh: make sure the script and
  # its payload live there even when installed from the deploy directory.
  if [ "$here" != "$APPLY_DIR" ]; then
    install -m 0755 "$here/$SCRIPT_BASENAME" "$APPLY_DIR/$SCRIPT_BASENAME"
    [ -f "$here/moode-sync.php" ] && install -m 0755 "$here/moode-sync.php" "$APPLY_DIR/moode-sync.php"
    if [ -d "$here/cdsp" ]; then
      mkdir -p "$APPLY_DIR/cdsp"
      cp -a "$here/cdsp/." "$APPLY_DIR/cdsp/"
    fi
  fi
}

# ------------------------------------------------------------------ commands

cmd_install() {
  require_root
  say "Installing jukebox moOde dual output + tone"
  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 not found"
  [ -f "$AUDIOOUT_CONF" ] || die "moOde ALSA config not found"
  backup_config
  write_config_env
  install_files_from_payload
  build_patched_cdsp
  ensure_moode_state
  moode_sync
  apply_all
  enable_volume_sync
  install_units
  ok "installed"
  cmd_verify || true
  say "Done"
  cat <<EOF
    Installed.

    * DAC (speakers) : tone + balance + volume via CamillaDSP ("$TONE_NAME").
    * Second output  : $(analyser_available && echo "usb (constant level)" || echo "none (DAC-only)").
    * Volume type    : CamillaDSP (knob -> fader; analyser unaffected).
    * Revert anytime : sudo $0 uninstall
EOF
}

cmd_apply() {
  require_root
  [ -d "$APPLY_DIR" ] || { log "apply: not installed"; exit 0; }
  apply_all
  if [ "${CHAIN_CHANGED:-0}" = "1" ] && systemctl is-active --quiet mpd; then
    # The live ALSA chain changed (split <-> DAC-only): MPD must re-open it.
    # Pause-then-play keeps the queue position.
    local was_playing=""
    mpc status 2>/dev/null | grep -q '\[playing\]' && was_playing=1
    systemctl restart mpd >/dev/null 2>&1 || true
    sleep 2
    if [ -n "$was_playing" ]; then
      mpc play >/dev/null 2>&1 || true
    fi
    log "apply: chain changed; MPD restarted${was_playing:+ (resumed)}"
  fi
}

cmd_verify() {
  local rc=0 v want
  say "Verification"
  echo "    second output : $SECOND_OUTPUT"
  echo "    tone config   : $TONE_NAME"

  if analyser_available; then want="jukeboxSplit"; else want="camilladsp"; fi
  if grep -q "^slave.pcm \"$want\"" "$AUDIOOUT_CONF" 2>/dev/null; then
    ok "_audioout.conf points at $want"
  else
    fail "_audioout.conf does not point at $want"; rc=$((rc+1))
  fi

  if [ "$want" = "jukeboxSplit" ]; then
    if [ -f "$SPLIT_CONF" ] && grep -q 'pcm.jukeboxSplit' "$SPLIT_CONF"; then
      ok "split definition present ($SPLIT_CONF)"
    else
      fail "split definition missing"; rc=$((rc+1))
    fi
  fi

  if [ -e "$CAMILLA_WORKING" ] && [ "$(readlink -f "$CAMILLA_WORKING")" = "$TONE_CONFIG" ]; then
    ok "working_config.yml -> $TONE_NAME.yml"
  else
    fail "working_config.yml is not pointing at $TONE_NAME.yml"; rc=$((rc+1))
  fi

  if grep -q 'Lowshelf' "$TONE_CONFIG" 2>/dev/null && grep -q 'Highshelf' "$TONE_CONFIG" 2>/dev/null; then
    ok "tone config has bass + treble shelves"
  else
    fail "tone config missing or incomplete"; rc=$((rc+1))
  fi

  v="$(sqlite3 "$MOODE_DB" "SELECT value FROM cfg_mpd WHERE param='mixer_type';" 2>/dev/null || true)"
  if [ "$v" = "null" ]; then
    ok "MPD volume type is CamillaDSP (analyser unaffected)"
  else
    warn "MPD mixer_type is '$v' (expected null)"
  fi

  if [ "$SECOND_OUTPUT" = "usb" ]; then
    if analyser_available; then
      ok "USB analyser card present ($USB_CARD)"
    else
      warn "USB analyser card '$USB_CARD' not present"
    fi
  fi

  if analyser_available; then
    local usbnum lvl
    usbnum="$(card_num "$USB_CARD" 2>/dev/null || true)"
    lvl="$(amixer -c "$usbnum" sget PCM 2>/dev/null | grep -m1 'Front Left:' | grep -oE '\[[0-9]+%\]' | tr -d '[]%')"
    case "$lvl" in
      ""|100) ok "analyser card level is full (PCM ${lvl:-n/a})" ;;
      *) fail "analyser card PCM is at ${lvl}% (should be 100%)"; rc=$((rc+1)) ;;
    esac
  fi

  if command -v aplay >/dev/null 2>&1 && aplay -L 2>/dev/null | grep -qx jukeboxSplit; then
    ok "ALSA sees the jukeboxSplit PCM"
  elif [ "$want" = "jukeboxSplit" ]; then
    fail "ALSA does not expose jukeboxSplit"; rc=$((rc+1))
  fi

  if [ "$PLAY_TEST" = "1" ]; then
    if playback_test; then
      ok "chain opens with playback (DAC + analyser)"
    else
      fail "playback test failed (see $LOG_FILE)"; rc=$((rc+1))
    fi
  fi

  [ $rc -eq 0 ] && say "All checks passed" || say "Checks failed: $rc"
  return $rc
}

# Play a short deterministic WAV through the live chain (like the Volumio
# package) and confirm the involved PCMs reach RUNNING. Skipped while MPD is
# playing so a verify never interrupts the user.
playback_test() {
  local dev dacnum usbnum wav ok_dac=0 ok_usb=0
  dacnum="$(card_num "$DAC_CARD" 2>/dev/null || true)"
  usbnum="$(card_num "$USB_CARD" 2>/dev/null || true)"
  [ -n "$dacnum" ] || return 1
  if mpc status 2>/dev/null | grep -q '\[playing\]'; then
    log "playback test: skipped (MPD is playing)"
    return 0
  fi
  wav="$(mktemp /tmp/jukebox-moode-test.XXXXXX.wav)"
  python3 - "$wav" <<'PY'
import struct, sys, wave
p = sys.argv[1]
with wave.open(p, "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
    n = 44100 * 3
    w.writeframes(struct.pack("<%dh" % (n * 2), *([4000, -4000] * n)))
PY
  aplay -q -D jukeboxSplit "$wav" >/dev/null 2>&1 &
  local pid=$!
  local i=0
  while [ "$i" -lt 20 ]; do
    sleep 0.25
    [ "$(head -1 /proc/asound/card$dacnum/pcm0p/sub0/status 2>/dev/null)" = "state: RUNNING" ] && ok_dac=1
    if [ -n "$usbnum" ]; then
      [ "$(head -1 /proc/asound/card$usbnum/pcm0p/sub0/status 2>/dev/null)" = "state: RUNNING" ] && ok_usb=1
    fi
    [ "$ok_dac" = 1 ] && { [ -z "$usbnum" ] || [ "$ok_usb" = 1 ]; } && break
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$wav"
  [ "$ok_dac" = 1 ] || { log "playback test: DAC PCM never reached RUNNING"; return 1; }
  if [ -n "$usbnum" ]; then
    [ "$ok_usb" = 1 ] || { log "playback test: USB PCM never reached RUNNING"; return 1; }
  fi
  return 0
}

cmd_status() {
  say "jukebox-moode status"
  echo "    installed     : $([ -d "$APPLY_DIR" ] && echo yes || echo no)"
  if [ -f "$CONFIG_ENV" ]; then . "$CONFIG_ENV"; echo "    second output : ${JB_SECOND_OUTPUT:-?}"; fi
  [ -f "$AUDIOOUT_CONF" ] && echo "    _audioout     : $(grep '^slave.pcm' "$AUDIOOUT_CONF" | head -1)"
  [ -e "$CAMILLA_WORKING" ] && echo "    camilla cfg   : $(readlink -f "$CAMILLA_WORKING")"
  echo "    mpd mixer     : $(sqlite3 "$MOODE_DB" "SELECT value FROM cfg_mpd WHERE param='mixer_type';" 2>/dev/null || true)"
  echo "    guard.path    : $(systemctl is-active jukebox-moode-guard.path 2>/dev/null || true)"
}

cmd_uninstall() {
  require_root
  say "Uninstalling jukebox moOde dual output"
  remove_units

  # Restore the moOde values the install changed. Prefer the pre-install DB
  # backup; fall back to moOde-ish defaults when it is not available.
  local bdb="$BACKUP_ROOT/latest/moode-sqlite3.db"
  local camilla="off" sync="off" mpdmixer="software" mixer="software" buffer="500000"
  if [ -f "$bdb" ]; then
    camilla="$(sqlite3 "$bdb" "SELECT value FROM cfg_system WHERE param='camilladsp';" 2>/dev/null || echo off)"
    sync="$(sqlite3 "$bdb" "SELECT value FROM cfg_system WHERE param='camilladsp_volume_sync';" 2>/dev/null || echo off)"
    mpdmixer="$(sqlite3 "$bdb" "SELECT value FROM cfg_system WHERE param='mpdmixer';" 2>/dev/null || echo software)"
    mixer="$(sqlite3 "$bdb" "SELECT value FROM cfg_mpd WHERE param='mixer_type';" 2>/dev/null || echo software)"
    buffer="$(sqlite3 "$bdb" "SELECT value FROM cfg_mpd WHERE param='buffer_time';" 2>/dev/null || echo 500000)"
  fi
  sqlite3 "$MOODE_DB" "UPDATE cfg_system SET value='$camilla' WHERE param='camilladsp';"
  sqlite3 "$MOODE_DB" "UPDATE cfg_system SET value='$sync' WHERE param='camilladsp_volume_sync';"
  sqlite3 "$MOODE_DB" "UPDATE cfg_system SET value='$mpdmixer' WHERE param='mpdmixer';"
  sqlite3 "$MOODE_DB" "UPDATE cfg_system SET value='$mpdmixer' WHERE param='mpdmixer_local';"
  sqlite3 "$MOODE_DB" "UPDATE cfg_mpd SET value='$mixer' WHERE param='mixer_type';"
  sqlite3 "$MOODE_DB" "UPDATE cfg_mpd SET value='$buffer' WHERE param='buffer_time';"

  # Hand the output config back to moOde: its own code writes the right
  # slave.pcm for the restored DSP selection.
  if [ -x "$APPLY_DIR/moode-sync.php" ]; then
    php "$APPLY_DIR/moode-sync.php" --restore >>"$LOG_FILE" 2>&1 || restore_audioout
    JB_MPD_BUFFER_TIME="$buffer" php "$APPLY_DIR/moode-sync.php" >>"$LOG_FILE" 2>&1 || true
  else
    restore_audioout
  fi
  rm -f "$SPLIT_CONF" "$TONE_CONFIG"
  rm -rf "$APPLY_DIR"
  ok "uninstalled (moOde config restored; reboot recommended)"
}

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  local mode=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --with-playback) PLAY_TEST=1; shift ;;
      --second-output=*) SECOND_OUTPUT="${1#*=}"; shift ;;
      --second-output) SECOND_OUTPUT="$2"; shift 2 ;;
      --no-tone) TONE_ENABLE=off; shift ;;
      --tone) TONE_ENABLE=on; shift ;;
      --analyser-trim) ANALYSER_TRIM=on; shift ;;
      --no-analyser-trim) ANALYSER_TRIM=off; shift ;;
      --analyser-freq) ANALYSER_FREQ_HZ="$2"; shift 2 ;;
      --analyser-freq=*) ANALYSER_FREQ_HZ="${1#*=}"; shift ;;
      --analyser-gain) ANALYSER_GAIN_DB="$2"; shift 2 ;;
      --analyser-gain=*) ANALYSER_GAIN_DB="${1#*=}"; shift ;;
      --analyser-q) ANALYSER_Q="$2"; shift 2 ;;
      --analyser-q=*) ANALYSER_Q="${1#*=}"; shift ;;
      --mpd-buffer) MPD_BUFFER_TIME="$2"; shift 2 ;;
      --mpd-buffer=*) MPD_BUFFER_TIME="${1#*=}"; shift ;;
      --no-patch-cdsp) PATCH_CDSP=off; shift ;;
      -h|--help) usage; exit 0 ;;
      install|verify|apply|status|uninstall) mode="$1"; shift ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
  done
  case "$mode" in
    install) cmd_install ;;
    verify) cmd_verify ;;
    apply) cmd_apply ;;
    status) cmd_status ;;
    uninstall) cmd_uninstall ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
