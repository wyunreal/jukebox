#!/usr/bin/env bash
#
# jukebox-audio.sh - dual audio output for a Volumio jukebox on Raspberry Pi
#
# Splits Volumio's audio pipeline so the same audio goes to BOTH:
#   * the I2S DAC (main output, speakers), whose level is controlled by the
#     usual Volumio volume slider / API, and
#   * a second output at a constant level for a spectrum analyser, either the
#     Raspberry Pi 3.5 mm jack (default), an HDMI audio extractor
#     (--second-output hdmi) or a USB DAC (--second-output usb).
#     HDMI/USB are immune to the PWM noise of the 3.5 mm jack; USB does not
#     interfere with the display at all.
#
# How it works
# ------------
# Volumio builds /etc/asound.conf from "asound contributions" of its plugins.
# The standard contribution (softvolume.postVolume.conf) is replaced with a
# split chain:
#
#   volumio -> softvolume -> jukeboxRoute -> jukeboxSplit (multi)
#       |- volumioSoftVol (softvol, SoftMaster) -> postVolume -> volumioOutput -> volumioHw (I2S DAC)
#       '- second branch: jukeboxEq (analyser low-shelf filter) -> jukeboxJack/Hdmi/Usb
#
# * The software volume control lives on the I2S DAC branch only, so the
#   Volumio UI / API volume affects the DAC alone.
# * The second branch has no volume control; for the jack its hardware mixer
#   is kept at full level, for HDMI the level is inherently constant.
# * The second branch carries an optional fixed low-shelf filter for the
#   spectrum analyser (spectrum analyser bars tend to over-read the deep bass).
#   See "ANALYSER BASS TRIM" below.
# * MPD is told (via its "device special settings") to use no mixer, so MPD
#   volume commands cannot touch the second output.
#
# ANALYSER BASS TRIM
# ------------------
# The analyser branch can be trimmed with a fixed low-shelf (CAPS Eq4p via the
# alsaequal 'equal' ALSA plugin). Parameters (JB_ANALYSER_*):
#   JB_ANALYSER_TRIM     on|off        (default on)
#   JB_ANALYSER_FREQ_HZ  shelf corner  (default 60)
#   JB_ANALYSER_GAIN_DB  shelf gain    (default -6.02 == "half" the level)
#   JB_ANALYSER_Q        shelf Q       (default 0.5)
# "50% amplitude" is -6.02 dB. The trim is baked into a deterministic controls
# file, so it is identical on every install. The filter is applied to the
# ANALYSER BRANCH ONLY; the DAC (speakers) path is untouched.
#
# HDMI fail-safe: the ALSA 'multi' plugin fails entirely if one branch cannot
# open, so when the HDMI extractor is absent (no EDID) the chain is
# automatically rewritten to a DAC-only variant, and the HDMI branch is
# restored as soon as the extractor appears (udev + guard).
#
# systemd units (a boot guard plus a path watcher and a udev rule) keep the
# configuration in place if Volumio rewrites it from its UI.
#
# Usage (on the Volumio host, as root):
#   sudo ./jukebox-audio.sh install [--second-output jack|hdmi|usb|none] [--with-playback]
#   sudo ./jukebox-audio.sh install [--analyser-trim on|off] [--analyser-freq HZ]
#                                  [--analyser-gain dB] [--analyser-q Q]
#   sudo ./jukebox-audio.sh install [--tone on|off] [--tone-bass HZ]
#                                  [--tone-treble HZ] [--tone-q Q]
#   sudo ./jukebox-audio.sh verify  [--with-playback]
#   sudo ./jukebox-audio.sh apply      # re-assert (used by guard units)
#   sudo ./jukebox-audio.sh status
#   sudo ./jukebox-audio.sh uninstall
#
# From a development machine use deploy.sh, which copies this script over
# SSH and runs it remotely.
#
set -euo pipefail

VERSION="1.2.4"

APPLY_DIR="/usr/local/jukebox-audio"
CONFIG_ENV="$APPLY_DIR/config.env"
LOG_FILE="/var/log/jukebox-audio.log"
VOLUMIO_ASOUND_DIR="/data/configuration/audio_interface/alsa_controller/asound"
SNIPPET_PATH="${VOLUMIO_ASOUND_DIR}/softvolume.postVolume.conf"
ALSA_CONFIG_JSON="/data/configuration/audio_interface/alsa_controller/config.json"
SPECIAL_CARDS_JSON="/volumio/app/plugins/music_service/mpd/special_cards_config.json"
BACKUP_ROOT="/var/backups/jukebox-audio"
RESTART_STAMP="/run/jukebox-audio-volumio-restart"
VOLUMIO_RESTART_MIN_INTERVAL=300
UDEV_RULE="/etc/udev/rules.d/89-jukebox-audio.rules"
# alsaequal + CAPS LADSPA plugin power the analyser low-shelf filter.
EQ_CONTROLS_SRC="$APPLY_DIR/analyser-eq.bin"
EQ_CONTROLS_DEST="/var/lib/jukebox-audio/analyser-eq.bin"
EQ_LIBRARY="/usr/lib/ladspa/caps.so"
EQ_MODULE="Eq4p"
EQ_CAPS_ID=2608

# --- tone control (bass/treble via CamillaDSP) ------------------------------
# An ALSA "cdsp" plugin in front of the split runs CamillaDSP, whose pipeline
# holds a low-shelf and a high-shelf. Both branches (DAC and analyser) go
# through it, so the analyser reflects the tone. The gains are rewritten by
# jukebox-pots and applied live via SIGHUP.
TONE_ENABLE="${JB_TONE:-on}"                       # on | off
TONE_BASS_FREQ="${JB_TONE_BASS_FREQ:-120}"
TONE_TREBLE_FREQ="${JB_TONE_TREBLE_FREQ:-6000}"
TONE_SHELF_Q="${JB_TONE_Q:-0.7}"
CAMILLA_BIN="/usr/local/bin/camilladsp"
CDSP_PLUGIN="/usr/lib/arm-linux-gnueabihf/alsa-lib/libasound_module_pcm_cdsp.so"
CDSP_SRC="$APPLY_DIR/cdsp"
CAMILLA_VERSION="4.1.3"
CAMILLA_URL="https://github.com/HEnquist/camilladsp/releases/download/v${CAMILLA_VERSION}/camilladsp-linux-armv7.tar.gz"

# --- options (JB_* environment variables act as defaults)
SECOND_OUTPUT="${JB_SECOND_OUTPUT:-jack}"   # jack | hdmi | usb | none
DAC_CARD="${JB_DAC_CARD:-}"
JACK_CARD="${JB_JACK_CARD:-}"
HDMI_CARD="${JB_HDMI_CARD:-}"
HDMI_RATE="${JB_HDMI_RATE:-48000}"
USB_CARD="${JB_USB_CARD:-}"
USB_RATE="${JB_USB_RATE:-48000}"
JACK_LEVEL="${JB_JACK_LEVEL:-0dB}"          # 0.00 dB == full clean level
JACK_LEVEL_RAW="${JB_JACK_LEVEL_RAW:-0}"
# Analyser branch bass trim (see ANALYSER BASS TRIM above).
ANALYSER_TRIM="${JB_ANALYSER_TRIM:-on}"       # on | off
ANALYSER_FREQ_HZ="${JB_ANALYSER_FREQ_HZ:-60}" # low-shelf corner frequency
ANALYSER_GAIN_DB="${JB_ANALYSER_GAIN_DB:--6.02}" # -6.02 dB == half amplitude
ANALYSER_Q="${JB_ANALYSER_Q:-0.5}"
# JB_HDMI_OVERRIDE=on|off / JB_USB_OVERRIDE=on|off force availability (testing)
PLAY_TEST=0
BOOT_APPLY=0
JUNK_CONTROLS="JbTestMaster|AddProbeXyz|PersistA|BootCreateTest|LoopbackTest"
VARIANTS="jack hdmi usb daconly"

# ------------------------------------------------------------------- helpers

log()  { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG_FILE" 2>/dev/null || true; }
say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*"; }
fail() { printf '    \033[1;31mFAIL\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"; }

# The analyser low-shelf needs the alsaequal PCM plugin (libasound2-plugin-equal)
# and the CAPS LADSPA library (caps). Both are free Debian/Raspbian packages.
# apt on a Volumio box is often left half-configured, so fall back to fetching
# the .debs and installing them with dpkg.
dsp_deps_present() {
  [ -e /usr/lib/arm-linux-gnueabihf/alsa-lib/libasound_module_pcm_equal.so ] \
    && [ -e "$EQ_LIBRARY" ]
}

ensure_dsp_deps() {
  [ "$ANALYSER_TRIM" = "on" ] || return 0
  dsp_deps_present && return 0
  say "Installing DSP dependencies (alsaequal + CAPS LADSPA)"
  if apt-get install -y --no-install-recommends caps libasound2-plugin-equal >/dev/null 2>&1 \
     && dsp_deps_present; then
    ok "installed via apt"
    return 0
  fi
  warn "apt install failed; fetching .debs directly"
  local tmp
  tmp="$(mktemp -d /tmp/jukebox-eq.XXXXXX)"
  ( cd "$tmp" && apt-get download caps libasound2-plugin-equal >/dev/null 2>&1 ) || true
  if ls "$tmp"/*.deb >/dev/null 2>&1; then
    dpkg -i "$tmp"/*.deb >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
  if dsp_deps_present; then
    ok "installed from downloaded .debs"
  else
    die "could not install alsaequal/CAPS; install 'caps' and 'libasound2-plugin-equal' and retry"
  fi
}

usage() { sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Install CamillaDSP (the tone-control engine) and the ALSA "cdsp" plugin it
# needs. Both binaries are shipped precompiled in this directory (armhf); the
# plugin can also be rebuilt from source when a compiler and the ALSA dev
# headers are present. Idempotent: re-running just re-installs the same files.
install_tone_deps() {
  [ "$TONE_ENABLE" = "on" ] || return 0
  say "Installing tone-control engine (CamillaDSP + cdsp plugin)"

  if [ -x "$SCRIPT_DIR/camilladsp" ]; then
    install -m 0755 "$SCRIPT_DIR/camilladsp" "$CAMILLA_BIN"
    ok "CamillaDSP installed ($("$CAMILLA_BIN" --version 2>/dev/null | head -1))"
  elif [ ! -x "$CAMILLA_BIN" ]; then
    warn "CamillaDSP binary not found in $SCRIPT_DIR; tone control will not work"
    warn "fetch it from the releases page (camilladsp-linux-armv7.tar.gz)"
  fi

  install -d /var/lib/jukebox-audio
  # The cdsp plugin (running inside MPD, as the mpd/volumio user) rewrites the
  # active CamillaDSP config on every open, and jukebox-pots rewrites it too.
  # Drop stale copies (they may be owned by root) and keep the directory
  # writable for everyone: install -d does not change an existing dir's mode.
  rm -f /var/lib/jukebox-audio/camilla-active.*.yml
  chmod 0777 /var/lib/jukebox-audio

  # The ALSA plugin: prefer the precompiled .so; rebuild if explicitly asked
  # and a cross/native compiler plus headers are available.
  if [ "${JB_TONE_BUILD_CDSP:-0}" = "1" ] && command -v gcc >/dev/null 2>&1 \
     && [ -e /usr/include/alsa/pcm_external.h ]; then
    say "Building the cdsp plugin from source"
    if gcc -DPIC -std=gnu11 -O2 -fPIC -shared \
         -I/usr/include -o /tmp/libasound_module_pcm_cdsp.so \
         "$SCRIPT_DIR/cdsp/libasound_module_pcm_cdsp.c" 2>/tmp/cdsp-build.log; then
      install -m 0755 /tmp/libasound_module_pcm_cdsp.so "$CDSP_PLUGIN"
      rm -f /tmp/libasound_module_pcm_cdsp.so
      ok "cdsp plugin built and installed"
      return 0
    fi
    warn "cdsp build failed (see /tmp/cdsp-build.log); using the precompiled one"
  fi
  if [ -f "$SCRIPT_DIR/libasound_module_pcm_cdsp.so" ]; then
    install -m 0755 "$SCRIPT_DIR/libasound_module_pcm_cdsp.so" "$CDSP_PLUGIN"
    ok "cdsp plugin installed (precompiled)"
  elif [ ! -e "$CDSP_PLUGIN" ]; then
    warn "cdsp plugin missing and no precompiled copy available"
  fi
}

detect_cards() {
  local f id
  for f in /proc/asound/card*/id; do
    [ -r "$f" ] || continue
    id="$(cat "$f" 2>/dev/null)" || continue
    [ -n "$id" ] || continue
    case "$id" in
      *sndrpirpidac*|*pcm1794a*|*rpi-dac*|*RPiDAC*) [ -n "$DAC_CARD" ] || DAC_CARD="$id" ;;
      Headphones|*Headphones*) [ -n "$JACK_CARD" ] || JACK_CARD="$id" ;;
      vc4hdmi*|*hdmi*) [ -n "$HDMI_CARD" ] || HDMI_CARD="$id" ;;
    esac
  done
  [ -n "$DAC_CARD" ]
}

# Find the USB sound card (anything that is not the I2S DAC, the jack, an
# HDMI output or a loopback card). Prefer the explicit JB_USB_CARD.
detect_usb_card() {
  local f id
  if [ -n "$USB_CARD" ]; then
    [ -e "/proc/asound/$USB_CARD" ] && return 0
    # fall through: the configured name may be stale
    USB_CARD=""
  fi
  for f in /proc/asound/card*/id; do
    [ -r "$f" ] || continue
    id="$(cat "$f" 2>/dev/null)" || continue
    [ -n "$id" ] || continue
    case "$id" in
      *sndrpirpidac*|*pcm1794a*|*rpi-dac*|*RPiDAC*) continue ;;
      Headphones|*Headphones*) continue ;;
      vc4hdmi*|*hdmi*) continue ;;
      Loopback|*loopback*|Dummy|*dummy*|null|*null*) continue ;;
    esac
    USB_CARD="$id"
    return 0
  done
  return 1
}

card_num() {
  awk -v n="$1" '
    match($0, /\[[^]]+\]/) {
      id = substr($0, RSTART+1, RLENGTH-2)
      gsub(/ /, "", id)
      if (id == n) { print $1; exit }
    }' /proc/asound/cards
}

# vc4hdmi0 -> HDMI-A-1, vc4hdmi1 -> HDMI-A-2
hdmi_connector_idx() {
  local n="${HDMI_CARD#vc4hdmi}"
  case "$n" in 0|1) echo $((n + 1)) ;; *) echo "" ;; esac
}

hdmi_edid_ok() {
  local idx st f bytes
  idx="$(hdmi_connector_idx)"
  [ -n "$idx" ] || return 1
  st="$(cat /sys/class/drm/card*-HDMI-A-${idx}/status 2>/dev/null | head -1)"
  [ "$st" = "connected" ] || return 1
  # Note: sysfs attribute files report size 0 in stat(); read the content.
  for f in /sys/class/drm/card*-HDMI-A-${idx}/edid; do
    [ -r "$f" ] || continue
    bytes="$(dd if="$f" bs=128 count=1 2>/dev/null | wc -c)"
    [ "${bytes:-0}" -ge 128 ] && return 0
  done
  return 1
}

hdmi_usable() {
  case "${JB_HDMI_OVERRIDE:-}" in
    off|no|0) return 1 ;;
    on|yes|1) return 0 ;;
  esac
  hdmi_edid_ok
}

usb_available() {
  case "${JB_USB_OVERRIDE:-}" in
    off|no|0) return 1 ;;
    on|yes|1) : ;;  # forced present: still needs the card to exist
  esac
  detect_usb_card
}

usb_open_ok() {
  [ -n "$USB_CARD" ] || return 1
  timeout 5 aplay -q -D "hw:CARD=$USB_CARD,DEV=0" -f S16_LE -r "$USB_RATE" -c 2 -d 1 /dev/zero >/dev/null 2>&1
}

variant_for_now() {
  case "$SECOND_OUTPUT" in
    jack) echo jack ;;
    none) echo daconly ;;
    hdmi) if hdmi_usable; then echo hdmi; else echo daconly; fi ;;
    usb)  if usb_available; then echo usb;  else echo daconly; fi ;;
    *) echo jack ;;
  esac
}

live_variant() {
  local f
  for f in /etc/asound.conf "$SNIPPET_PATH"; do
    [ -f "$f" ] || continue
    if grep -q "jukebox-audio variant: hdmi" "$f" 2>/dev/null; then echo hdmi; return; fi
    if grep -q "jukebox-audio variant: usb" "$f" 2>/dev/null; then echo usb; return; fi
    if grep -q "jukebox-audio variant: jack" "$f" 2>/dev/null; then echo jack; return; fi
    if grep -q "jukebox-audio variant: daconly" "$f" 2>/dev/null; then echo daconly; return; fi
  done
  echo none
}

# ------------------------------------------------------------------ renderers

# Emit the analyser-branch filter block. With the trim on, a CAPS Eq4p
# low-shelf (via alsaequal) attenuates the deep bass for the analyser only;
# with it off, a plain plug keeps the branch transparent.
render_analyser_eq() {
  local target="$1" rate="$2"
  if [ "$ANALYSER_TRIM" = "on" ]; then
    cat <<EOF
# Analyser bass trim: low-shelf ${ANALYSER_FREQ_HZ} Hz ${ANALYSER_GAIN_DB} dB (Q ${ANALYSER_Q}).
# Fixed via a deterministic controls file; affects this branch only.
# The wrapper plug pins rate + FLOAT for the 'equal' plugin (which only
# accepts float); without that the ALSA 'multi' plugin fails to negotiate.
pcm.jukeboxEq {
    type            plug
    slave {
        pcm         "jukeboxEqDsp"
        rate        ${rate:-48000}
        format      FLOAT_LE
    }
}

pcm.jukeboxEqDsp {
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
pcm.jukeboxEq {
    type            plug
    slave.pcm       "$target"
}
EOF
  fi
}

# Deterministic alsaequal controls file for CAPS Eq4p: band a = low shelf at
# ANALYSER_FREQ_HZ / ANALYSER_GAIN_DB / ANALYSER_Q, bands b/c/d off.
# Layout (alsaequal LADSPA_Control): 6xuint32 header, then one 72-byte record
# per control port {int32 index; float data[16]; int32 type}, then a trailing
# float[16] per port. Kept byte-stable so the file is identical every install.
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
length = 24 + len(body) + len(tail)
hdr = struct.pack('<6I', length, uid, channels, len(spec), 17, 18)
open(path, 'wb').write(hdr + bytes(body) + bytes(tail))
print("wrote %s (%d bytes)" % (path, length))
PY
}

# Emit the CamillaDSP config template for the tone control. The ALSA cdsp
# plugin substitutes $samplerate$/$format$/$channels$ at open; jukebox-audio
# fills the sink here. The tone step lives ONLY on the DAC branch: CamillaDSP
# captures the (already volume-controlled) DAC stream and plays it straight to
# the DAC hardware. The two gains carry markers so jukebox-pots can rewrite
# them and trigger a live reload (SIGHUP). With both gains at 0.0 the signal
# is bit-for-bit unchanged (flat shelves).
render_camilla_template() {
  local sink="$1"
  cat <<'EOF'
# Managed by jukebox-audio (tone control, DAC branch only). Do not edit by hand.
# Gains carry JUKEBOX_TONE_BASS / JUKEBOX_TONE_TREBLE markers.
---
devices:
  samplerate: $samplerate$
  chunksize: 512
  queuelimit: 1
  capture:
    type: Stdin
    channels: $channels$
    format: $format$
  playback:
    type: Alsa
    channels: 2
    device: "SINK_PLACEHOLDER"
    format: S32_LE

filters:
  bass:
    type: Biquad
    parameters:
      type: Lowshelf
      freq: BASS_FREQ_PLACEHOLDER
      q: Q_PLACEHOLDER
      gain: 0.0  # JUKEBOX_TONE_BASS
  treble:
    type: Biquad
    parameters:
      type: Highshelf
      freq: TREBLE_FREQ_PLACEHOLDER
      q: Q_PLACEHOLDER
      gain: 0.0  # JUKEBOX_TONE_TREBLE

pipeline:
  - type: Filter
    channels: [0, 1]
    names: [bass, treble]
EOF
}

# The tone step feeds CamillaDSP which plays to the DAC hardware directly.
tone_sink() {
  echo "plughw:CARD=$DAC_CARD,DEV=0"
}

# Render the tone PCM block (empty when the tone is off). It sits on the DAC
# branch: the software volume feeds it and it feeds postVolume -> DAC.
render_tone_pcm() {
  local v="$1"
  [ "$TONE_ENABLE" = "on" ] || return 0
  cat <<EOF
pcm.jukeboxTone {
    type            cdsp
    cpath           "$CAMILLA_BIN"
    config_in       "$APPLY_DIR/cdsp/camilla.$v.yml"
    config_out      "/var/lib/jukebox-audio/camilla-active.$v.yml"
    channels        2
    rates           [44100 48000 88200 96000 176400 192000 352800]
    cargs [
        "-e"
        "16384"
    ]
}
EOF
}

# The software volume feeds the tone step when enabled, else postVolume.
tone_or_post() {
  [ "$TONE_ENABLE" = "on" ] && echo jukeboxTone || echo postVolume
}

render_snippet_usb() {
  cat <<EOF
# jukebox-audio variant: usb
# Managed by jukebox-audio (dual output). Do not edit by hand.
# Splits the 'volumio' pipeline into two outputs:
#   - I2S DAC with software volume (SoftMaster) -> controlled by Volumio
#   - USB DAC at a constant level                -> not affected by volume
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
    slaves.b.pcm    "jukeboxEq"
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

$(render_tone_pcm usb)

pcm.volumioSoftVol {
    type            softvol
    slave {
        pcm         "$(tone_or_post)"
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

$(render_analyser_eq "jukeboxUsb" "$USB_RATE")

pcm.jukeboxUsb {
    type            plug
    slave {
        pcm         "hw:CARD=$USB_CARD,DEV=0"
        rate        $USB_RATE
    }
}
EOF
}

render_snippet_jack() {
  cat <<EOF
# jukebox-audio variant: jack
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
    slaves.b.pcm    "jukeboxEq"
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

$(render_tone_pcm jack)

pcm.volumioSoftVol {
    type            softvol
    slave {
        pcm         "$(tone_or_post)"
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

$(render_analyser_eq "jukeboxJack" "48000")

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

render_snippet_hdmi() {
  cat <<EOF
# jukebox-audio variant: hdmi
# Managed by jukebox-audio (dual output). Do not edit by hand.
# Splits the 'volumio' pipeline into two outputs:
#   - I2S DAC with software volume (SoftMaster) -> controlled by Volumio
#   - HDMI (audio extractor) at a constant level -> not affected by volume
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
    slaves.b.pcm    "jukeboxEq"
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

$(render_tone_pcm hdmi)

pcm.volumioSoftVol {
    type            softvol
    slave {
        pcm         "$(tone_or_post)"
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

$(render_analyser_eq "jukeboxHdmi" "$HDMI_RATE")

pcm.jukeboxHdmi {
    type            plug
    slave {
        pcm         "hdmi:CARD=$HDMI_CARD,DEV=0"
        rate        $HDMI_RATE
    }
}
EOF
}

render_snippet_daconly() {
  cat <<EOF
# jukebox-audio variant: daconly
# Managed by jukebox-audio (second output temporarily unavailable).
# Single output: I2S DAC with software volume (SoftMaster).
pcm.softvolume {
    type            plug
    slave {
        pcm         "volumioSoftVol"
        format      "S24_3LE"
    }
}

$(render_tone_pcm daconly)

pcm.volumioSoftVol {
    type            softvol
    slave {
        pcm         "$(tone_or_post)"
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
EOF
}

render_snippet() {
  case "$1" in
    jack)    render_snippet_jack ;;
    hdmi)    render_snippet_hdmi ;;
    usb)     render_snippet_usb ;;
    daconly) render_snippet_daconly ;;
    *) return 1 ;;
  esac
}

# Full /etc/asound.conf, byte-compatible with what Volumio's ALSA config
# generator produces for the given contribution, so Volumio leaves it alone.
render_asound() {
  local snip="$1" s
  s="$(cat "$APPLY_DIR/snippet.$snip.conf")"
  cat <<EOF
pcm.!default {
    type             empty
    slave.pcm       "volumio"
}

pcm.volumio {
    type             empty
    slave.pcm       "softvolume"
}

$s

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

# Copy the shelf gains (Lowshelf/Highshelf) from an existing CamillaDSP config
# into a freshly rendered one. Keeps the tone setting across regenerations.
preserve_tone_gains() {
  local old="$1" new="$2"
  [ -f "$old" ] || return 0
  local bass treble
  bass="$(awk '/type: *Lowshelf/{f=1} f&&/gain:/{print $2; exit}' "$old")"
  treble="$(awk '/type: *Highshelf/{f=1} f&&/gain:/{print $2; exit}' "$old")"
  [ -n "$bass" ] || return 0
  awk -v b="$bass" -v t="$treble" '
    /type: *Lowshelf/ { inb=1 }
    /type: *Highshelf/ { inb=0; int_=1 }
    inb && /gain:/ { sub(/gain: *[-0-9.]+/, "gain: " b) }
    int_ && /gain:/ { sub(/gain: *[-0-9.]+/, "gain: " t) }
    { print }
  ' "$new" >"$new.preserved" && mv -f "$new.preserved" "$new"
  return 0
}

write_canonical() {
  mkdir -p "$APPLY_DIR" "$APPLY_DIR/cdsp"
  local v tmp
  for v in $VARIANTS; do
    render_snippet "$v" >"$APPLY_DIR/snippet.$v.conf"
    render_asound "$v" >"$APPLY_DIR/asound.$v.conf"
    # CamillaDSP tone-control template for this variant. Keep the shelf gains
    # that jukebox-pots last applied, so regenerating (guard/apply) never
    # resets the user's tone setting.
    tmp="$(mktemp "$APPLY_DIR/cdsp/.camilla.XXXXXX")"
    render_camilla_template "$v" \
      | sed -e "s|SINK_PLACEHOLDER|$(tone_sink "$v")|" \
            -e "s|BASS_FREQ_PLACEHOLDER|$TONE_BASS_FREQ|" \
            -e "s|TREBLE_FREQ_PLACEHOLDER|$TONE_TREBLE_FREQ|" \
            -e "s|Q_PLACEHOLDER|$TONE_SHELF_Q|" \
      >"$tmp"
    if [ -f "$APPLY_DIR/cdsp/camilla.$v.yml" ]; then
      preserve_tone_gains "$APPLY_DIR/cdsp/camilla.$v.yml" "$tmp"
    fi
    mv -f "$tmp" "$APPLY_DIR/cdsp/camilla.$v.yml"
    # MPD (running as an unprivileged user) must be able to read the template
    # and rewrite the active config.
    chmod 0644 "$APPLY_DIR/cdsp/camilla.$v.yml"
  done
  echo "$VERSION" >"$APPLY_DIR/VERSION"
  cat >"$CONFIG_ENV" <<EOF
# jukebox-audio settings (edited by install; used by the guard)
JB_SECOND_OUTPUT=$SECOND_OUTPUT
JB_DAC_CARD=$DAC_CARD
JB_JACK_CARD=$JACK_CARD
JB_HDMI_CARD=$HDMI_CARD
JB_HDMI_RATE=$HDMI_RATE
JB_USB_CARD=$USB_CARD
JB_USB_RATE=$USB_RATE
JB_JACK_LEVEL=$JACK_LEVEL
JB_JACK_LEVEL_RAW=$JACK_LEVEL_RAW
JB_ANALYSER_TRIM=$ANALYSER_TRIM
JB_ANALYSER_FREQ_HZ=$ANALYSER_FREQ_HZ
JB_ANALYSER_GAIN_DB=$ANALYSER_GAIN_DB
JB_ANALYSER_Q=$ANALYSER_Q
JB_TONE=$TONE_ENABLE
JB_TONE_BASS_FREQ=$TONE_BASS_FREQ
JB_TONE_TREBLE_FREQ=$TONE_TREBLE_FREQ
JB_TONE_Q=$TONE_SHELF_Q
EOF
  write_analyser_eq_controls "$EQ_CONTROLS_SRC" >/dev/null
  ok "analyser bass trim: $ANALYSER_TRIM (${ANALYSER_FREQ_HZ} Hz ${ANALYSER_GAIN_DB} dB, Q ${ANALYSER_Q})"
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

load_config_env() {
  if [ -f "$CONFIG_ENV" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_ENV"
    SECOND_OUTPUT="${JB_SECOND_OUTPUT:-jack}"
    DAC_CARD="${JB_DAC_CARD:-}"
    JACK_CARD="${JB_JACK_CARD:-}"
    HDMI_CARD="${JB_HDMI_CARD:-}"
    HDMI_RATE="${JB_HDMI_RATE:-48000}"
    USB_CARD="${JB_USB_CARD:-}"
    USB_RATE="${JB_USB_RATE:-48000}"
    JACK_LEVEL="${JB_JACK_LEVEL:-0dB}"
    JACK_LEVEL_RAW="${JB_JACK_LEVEL_RAW:-0}"
    ANALYSER_TRIM="${JB_ANALYSER_TRIM:-on}"
    ANALYSER_FREQ_HZ="${JB_ANALYSER_FREQ_HZ:-60}"
    ANALYSER_GAIN_DB="${JB_ANALYSER_GAIN_DB:--6.02}"
    ANALYSER_Q="${JB_ANALYSER_Q:-0.5}"
    TONE_ENABLE="${JB_TONE:-on}"
    TONE_BASS_FREQ="${JB_TONE_BASS_FREQ:-120}"
    TONE_TREBLE_FREQ="${JB_TONE_TREBLE_FREQ:-6000}"
    TONE_SHELF_Q="${JB_TONE_Q:-0.7}"
  fi
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

# Volumio generates /etc/mpd.conf from its own template, but only while its
# plugin is initialised. If the file is missing (fresh install, manual cleanup,
# botched update) MPD never starts and nothing plays. Rebuild it from the
# template with the current Volumio settings.
ensure_mpd_conf() {
  local tmpl="/volumio/app/plugins/music_service/mpd/mpd.conf.tmpl"
  [ -s /etc/mpd.conf ] && return 0
  [ -f "$tmpl" ] || { warn "no /etc/mpd.conf and no Volumio template to rebuild it"; return 1; }
  say "Rebuilding /etc/mpd.conf from the Volumio template"
  python3 - "$tmpl" "$ALSA_CONFIG_JSON" "$SPECIAL_CARDS_JSON" <<'PY'
import json, sys
tmpl, cfg_path, special_path = sys.argv[1], sys.argv[2], sys.argv[3]

def val(d, key, default=""):
    v = (d.get(key) or {}).get("value")
    return default if v is None else v

try:
    cfg = json.load(open(cfg_path))
except Exception:
    cfg = {}

label = val(cfg, "outputdevicename", "R-PI DAC")

special = ""
try:
    d = json.load(open(special_path))
    items = d.get(label)
    if isinstance(items, list):
        special = "\n".join("\t\t" + str(i) for i in items)
except Exception:
    pass

text = open(tmpl).read()
for k, v in {
    "${log_level}": "default",
    "${device}": "volumio",
    "${dop}": "no",
    "${mixer}": 'mixer_type\t\t"none"',
    "${format}": "",
    "${special_settings}": special,
}.items():
    text = text.replace(k, v)

open("/etc/mpd.conf", "w").write(text)
print("wrote /etc/mpd.conf")
PY
  chmod 0666 /etc/mpd.conf 2>/dev/null || true
  ok "wrote /etc/mpd.conf"
}

patch_special_cards() {  python3 - "$SPECIAL_CARDS_JSON" "$ALSA_CONFIG_JSON" <<'PY'
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
want = ['mixer_type "none"', 'buffer_time "3000000"', 'period_time "50000"']
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

# Clean the stored ALSA state: drop leftover test controls and the old bare
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

# ------------------------------------------------------------------- actions

set_jack_level() {
  [ "$SECOND_OUTPUT" = "jack" ] || return 0
  amixer -q -c "$JACK_CARD" sset PCM "$JACK_LEVEL" >/dev/null 2>&1 \
    || warn "could not set jack level on $JACK_CARD"
  amixer -q -c "$JACK_CARD" sset PCM unmute >/dev/null 2>&1 || true
}

softmaster_volume_present() {
  # The volume/switch elements are queried through their merged base name.
  amixer -q -c "$DAC_CARD" sget SoftMaster >/dev/null 2>&1
}

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

clean_kernel_controls() {
  [ -x "$APPLY_DIR/clean-controls.py" ] || return 0
  python3 "$APPLY_DIR/clean-controls.py" "$DAC_CARD" "$JUNK_CONTROLS" >/dev/null 2>&1 || true
}

put_file() {
  local src="$1" dst="$2" tmp
  tmp="$(dirname "$dst")/.jukebox-audio.$$"
  install -m 0644 -o volumio -g volumio "$src" "$tmp"
  mv -f "$tmp" "$dst"
}

# Install the live ALSA files for a given variant (atomic-ish writes).
# The cdsp plugin rewrites the active CamillaDSP config on every open and runs
# as whoever opens the chain: root during install/verify, mpd during playback.
# If root leaves the file as root:0644, mpd cannot rewrite it and playback dies
# after ~1 s with "Error writing output config file". Keep it world-writable,
# whichever user created it last.
fix_active_perms() {
  chmod 0666 /var/lib/jukebox-audio/camilla-active.*.yml 2>/dev/null || true
}

install_live_files() {
  local v="$1"
  put_file "$APPLY_DIR/snippet.$v.conf" "$SNIPPET_PATH"
  put_file "$APPLY_DIR/asound.$v.conf" /etc/asound.conf
  # The controls file must be writable by whoever opens the chain (mpd);
  # alsaequal mmaps it read/write even for plain playback. The directory also
  # holds CamillaDSP's active config, which MPD's cdsp plugin rewrites on every
  # open, so it must stay writable by non-root users too.
  install -d -m 0777 /var/lib/jukebox-audio
  install -m 0666 "$EQ_CONTROLS_SRC" "$EQ_CONTROLS_DEST"
  fix_active_perms
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

# True if the live ALSA config is already managed by this tool. Used to avoid
# overwriting a clean pre-install backup with an already-managed state on
# re-install.
is_jukebox_active() {
  local f
  for f in /etc/asound.conf "$SNIPPET_PATH"; do
    [ -f "$f" ] || continue
    grep -q "jukebox-audio variant:" "$f" 2>/dev/null && return 0
  done
  return 1
}

backup_config() {
  local ts dir
  # Never overwrite a clean pre-install backup with a managed state: a re-run
  # of install must not poison the restore point. If the current files already
  # carry the jukebox markers, keep the existing backup (if any).
  if is_jukebox_active; then
    if [ -d "$BACKUP_ROOT/latest" ]; then
      ok "already installed; keeping existing backup $(readlink -f "$BACKUP_ROOT/latest")"
      return 0
    fi
    warn "current ALSA config already carries jukebox markers but no backup exists"
    warn "a restore point can no longer be captured; uninstall will let Volumio regenerate"
  fi

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

install_units() {
  cat >/etc/systemd/system/jukebox-audio-guard.service <<EOF
[Unit]
Description=Jukebox dual-output audio guard (re-assert configuration)
Wants=alsa-restore.service
After=alsa-restore.service local-fs.target

[Service]
Type=oneshot
TimeoutStartSec=180
ExecStart=$APPLY_DIR/jukebox-audio.sh apply --boot

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
  # HDMI hotplug and USB sound card hotplug: re-evaluate the chain.
  cat >"$UDEV_RULE" <<EOF
ACTION=="change", SUBSYSTEM=="drm", KERNEL=="card*-HDMI-A-*", RUN+="/usr/bin/systemctl --no-block restart jukebox-audio-guard.service"
ACTION=="add|remove", SUBSYSTEM=="sound", KERNEL=="card*", RUN+="/usr/bin/systemctl --no-block restart jukebox-audio-guard.service"
EOF
  systemctl daemon-reload
  systemctl enable jukebox-audio-guard.service >/dev/null 2>&1 || true
  systemctl enable jukebox-audio-guard.path >/dev/null 2>&1 || true
  systemctl start jukebox-audio-guard.path >/dev/null 2>&1 || true
  udevadm control --reload-rules >/dev/null 2>&1 || true
  ok "guard units + udev rule installed"
}

remove_units() {
  systemctl disable --now jukebox-audio-guard.path >/dev/null 2>&1 || true
  systemctl disable --now jukebox-audio-guard.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/jukebox-audio-guard.path /etc/systemd/system/jukebox-audio-guard.service
  rm -f "$UDEV_RULE"
  systemctl daemon-reload
  udevadm control --reload-rules >/dev/null 2>&1 || true
}

alsa_playback_test() {
  local v="$1" dn hn jn un ok_dac=0 ok_second=0 pid wav
  dn="$(card_num "$DAC_CARD")"
  jn="$(card_num "$JACK_CARD")"
  hn="$(card_num "$HDMI_CARD")"
  un="$(card_num "$USB_CARD")"
  [ -n "$dn" ] || return 1
  # The cdsp tone step needs a source that paces the stream. /dev/zero is
  # written as fast as possible and makes the plugin report XRUN, so play a
  # short real WAV instead.
  wav="$(mktemp /tmp/jukebox-test.XXXXXX.wav)"
  python3 - "$wav" <<'PY'
import struct, sys, wave
p = sys.argv[1]
with wave.open(p, "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
    n = 44100 * 4
    w.writeframes(b"".join(struct.pack("<hh", int(6000*((i % 100) - 50)/50), int(6000*((i % 100) - 50)/50)) for i in range(n)))
PY
  aplay -q -D volumio "$wav" >/dev/null 2>&1 &
  pid=$!
  sleep 1.5
  grep -q RUNNING /proc/asound/card${dn}/pcm0p/sub*/status 2>/dev/null && ok_dac=1
  case "$v" in
    jack)    [ -n "$jn" ] && grep -q RUNNING /proc/asound/card${jn}/pcm0p/sub*/status 2>/dev/null && ok_second=1 ;;
    hdmi)    [ -n "$hn" ] && grep -q RUNNING /proc/asound/card${hn}/pcm0p/sub*/status 2>/dev/null && ok_second=1 ;;
    usb)     [ -n "$un" ] && grep -q RUNNING /proc/asound/card${un}/pcm0p/sub*/status 2>/dev/null && ok_second=1 ;;
    daconly) ok_second=1 ;;
  esac
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$wav"
  [ "$ok_dac" = 1 ] && [ "$ok_second" = 1 ]
}

mpd_playback_test() {
  # Returns: 0 = passed, 1 = failed, 2 = skipped (nothing to play).
  local was_playing=0 dn jn hn un r=0 cur="" restored=0 v added=0 track
  v="$(live_variant)"
  mpc status 2>/dev/null | grep -q '\[playing\]' && was_playing=1

  if [ "$was_playing" = 0 ]; then
    # Right after boot MPD is slow to start: its database may not be loaded
    # yet and the first output can take a while to open. Give it 20 s so the
    # test does not fail for a reason that is not the audio chain.
    sleep 20
    # The queue is often empty (e.g. right after a reboot) and then `mpc play`
    # does nothing and the test would fail for no good reason. Pull a track
    # from the library so there is something to play, and remember to clean it
    # up afterwards (the queue was empty, so clearing restores it exactly).
    if ! mpc playlist 2>/dev/null | grep -q .; then
      track="$(mpc listall 2>/dev/null | head -1)"
      if [ -z "$track" ]; then
        warn "no track in the MPD queue or library; skipping MPD playback test"
        return 2
      fi
      if mpc add "$track" >/dev/null 2>&1; then
        added=1
        ok "queue was empty; added a track for the test ($track)"
      fi
    fi
    if ! mpc play >/dev/null 2>&1; then
      warn "could not start MPD playback; skipping MPD playback test"
      [ "$added" = 1 ] && mpc clear >/dev/null 2>&1 || true
      return 2
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
  hn="$(card_num "$HDMI_CARD")"
  un="$(card_num "$USB_CARD")"
  mpc status 2>/dev/null | grep -q '\[playing\]' || r=1
  grep -q RUNNING /proc/asound/card${dn}/pcm0p/sub*/status 2>/dev/null || r=1
  case "$v" in
    jack) [ -n "$jn" ] && grep -q RUNNING /proc/asound/card${jn}/pcm0p/sub*/status 2>/dev/null || r=1 ;;
    hdmi) [ -n "$hn" ] && grep -q RUNNING /proc/asound/card${hn}/pcm0p/sub*/status 2>/dev/null || r=1 ;;
    usb)  [ -n "$un" ] && grep -q RUNNING /proc/asound/card${un}/pcm0p/sub*/status 2>/dev/null || r=1 ;;
  esac
  if [ "$restored" = 1 ]; then
    amixer -q -c "$DAC_CARD" sset SoftMaster "$cur" >/dev/null 2>&1 || true
  fi
  [ "$was_playing" = 0 ] && mpc stop >/dev/null 2>&1 || true
  [ "$added" = 1 ] && mpc clear >/dev/null 2>&1 || true
  return $r
}

# --------------------------------------------------------------------- modes

cmd_install() {
  local wanted_variant=""

  require_root
  detect_cards || die "could not detect the I2S DAC (looked in /proc/asound)"
  [ -d "$VOLUMIO_ASOUND_DIR" ] || die "this does not look like a Volumio install ($VOLUMIO_ASOUND_DIR missing)"

  case "$SECOND_OUTPUT" in
    jack)
      [ -n "$JACK_CARD" ] || die "second output jack requested, but the 3.5 mm jack card was not found"
      ;;
    hdmi)
      [ -n "$HDMI_CARD" ] || die "second output hdmi requested, but no HDMI audio card was found"
      ;;
    usb)
      detect_usb_card || warn "second output usb requested, but no USB sound card is connected yet"
      ;;
    none) ;;
    *) die "invalid second output: $SECOND_OUTPUT (use jack|hdmi|usb|none)" ;;
  esac

  say "Installing jukebox dual output (v$VERSION)"
  echo "    DAC card      : $DAC_CARD"
  echo "    Second output : $SECOND_OUTPUT"
  if [ "$SECOND_OUTPUT" = "jack" ]; then
    echo "    Jack card     : $JACK_CARD  (level $JACK_LEVEL)"
  elif [ "$SECOND_OUTPUT" = "hdmi" ]; then
    echo "    HDMI card     : $HDMI_CARD  (rate $HDMI_RATE)"
  elif [ "$SECOND_OUTPUT" = "usb" ]; then
    echo "    USB card      : ${USB_CARD:-<not connected>}  (rate $USB_RATE)"
  fi

  local vol_state="" tmp
  vol_state="$(curl -sf localhost:3000/api/v1/getState 2>/dev/null \
    | sed -n 's/.*"volume":"\([0-9][0-9]*\)".*/\1/p' || true)"
  [ -n "$vol_state" ] || vol_state=99

  say "Backing up current configuration"
  backup_config

  say "Writing ALSA split configuration"
  ensure_dsp_deps
  install_tone_deps
  write_canonical
  wanted_variant="$(variant_for_now)"
  if [ "$SECOND_OUTPUT" = "hdmi" ] && [ "$wanted_variant" = "daconly" ]; then
    warn "HDMI extractor not detected right now (no EDID)"
    warn "installing with DAC-only fallback; HDMI will activate automatically when the extractor appears"
  fi
  if [ "$SECOND_OUTPUT" = "usb" ] && [ "$wanted_variant" = "daconly" ]; then
    warn "USB sound card not detected right now"
    warn "installing with DAC-only fallback; USB will activate automatically when the card is connected"
  fi
  install_live_files "$wanted_variant"
  ok "live variant: $wanted_variant"
  ok "wrote $SNIPPET_PATH"
  ok "wrote /etc/asound.conf"

  say "Updating Volumio configuration"
  ensure_mpd_conf
  [ "$(patch_config_json)" = "changed" ] && ok "updated $ALSA_CONFIG_JSON" || ok "config.json already correct"
  [ "$(patch_special_cards)" = "changed" ] && ok "updated $SPECIAL_CARDS_JSON" || ok "special cards config already correct"

  say "Installing guard units"
  install_units

  say "Restarting Volumio"
  restart_volumio force
  wait_for_volumio && ok "Volumio is up" || warn "Volumio did not report ready within the timeout"
  sleep 3
  systemctl is-active --quiet mpd || systemctl start --no-block mpd >/dev/null 2>&1 || true

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

  # HDMI reality check: if the chain cannot really open with HDMI now,
  # fall back to DAC-only so playback keeps working.
  if [ "$wanted_variant" = "hdmi" ]; then
    if ! alsa_playback_test hdmi; then
      sleep 3
      if ! alsa_playback_test hdmi; then
        if mpc status 2>/dev/null | grep -q '\[playing\]'; then
          warn "chain test inconclusive (MPD is playing)"
        else
          warn "HDMI chain did not open; falling back to DAC-only"
          SECOND_OUTPUT="hdmi"     # keep the intent; live variant is the fallback
          install_live_files daconly
          systemctl restart --no-block mpd >/dev/null 2>&1 || true
        fi
      else
        ok "HDMI chain opens both outputs"
      fi
    else
      ok "HDMI chain opens both outputs"
    fi
  fi

  cmd_verify || true
  fix_active_perms

  say "Done"
  cat <<EOF
    Installed. A reboot is recommended to verify everything comes up cleanly.

    * DAC (speakers) : volume controlled by Volumio as usual.
    * Second output  : $SECOND_OUTPUT $( [ "$SECOND_OUTPUT" = jack ] && echo "(constant level $JACK_LEVEL)" || echo "(constant digital level)" )
    * Revert anytime : sudo $0 uninstall
    * Logs           : $LOG_FILE and 'journalctl -u jukebox-audio-guard'
EOF
}

cmd_apply() {
  require_root
  log "apply: start (boot=$BOOT_APPLY)"
  [ -d "$APPLY_DIR" ] || { log "apply: not installed"; exit 0; }
  sleep 2
  load_config_env
  if ! detect_cards; then
    log "apply: audio cards not found; nothing to do"
    exit 0
  fi
  if [ ! -f "$CONFIG_ENV" ] || [ ! -f "$APPLY_DIR/asound.jack.conf" ]; then
    log "apply: canonical files missing; regenerating"
    write_canonical
  fi
  # Keep the analyser controls file in step with the canonical copy.
  if [ "$ANALYSER_TRIM" = "on" ] && [ -f "$EQ_CONTROLS_SRC" ]; then
    ensure_dsp_deps
    install -d -m 0777 /var/lib/jukebox-audio
    if ! cmp -s "$EQ_CONTROLS_SRC" "$EQ_CONTROLS_DEST" 2>/dev/null; then
      install -m 0666 "$EQ_CONTROLS_SRC" "$EQ_CONTROLS_DEST"
      log "apply: refreshed analyser controls file"
    fi
  fi
  fix_active_perms
  if [ "$SECOND_OUTPUT" = "hdmi" ] && [ "$BOOT_APPLY" = 1 ]; then
    # give the HDMI sink a moment to come up before deciding
    local i=0
    while [ "$i" -lt 20 ] && ! hdmi_usable; do
      sleep 2
      i=$((i + 2))
    done
  fi

  local desired live fixed_s=0 fixed_a=0 fixed_x=0 fixed_c=0 out
  desired="$(variant_for_now)"
  live="$(live_variant)"

  if ! cmp -s "$APPLY_DIR/snippet.$desired.conf" "$SNIPPET_PATH" 2>/dev/null \
     || ! cmp -s "$APPLY_DIR/asound.$desired.conf" /etc/asound.conf 2>/dev/null; then
    install_live_files "$desired"
    fixed_s=1
    log "apply: live variant $live -> $desired (files written)"
  fi
  ensure_mpd_conf
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
  elif [ "$fixed_s" = 1 ]; then
    systemctl restart --no-block mpd >/dev/null 2>&1 || true
  fi
  log "apply: done (variant=$desired snippet=$fixed_s special=$fixed_x config=$fixed_c)"
}

cmd_verify() {
  local rc=0 jraw volparsed v want_variant
  v="$(live_variant)"

  say "Verification"
  echo "    second output : $SECOND_OUTPUT"
  echo "    live variant  : $v"

  if [ "$v" != "none" ]; then
    ok "Volumio ALSA snippet contains the jukebox chain ($v)"
  else
    fail "ALSA snippet missing or replaced: $SNIPPET_PATH"; rc=$((rc + 1))
  fi

  if grep -q "jukebox-audio variant: $v" /etc/asound.conf 2>/dev/null; then
    ok "/etc/asound.conf wired through the jukebox chain"
  else
    fail "/etc/asound.conf is not wired through the jukebox chain"; rc=$((rc + 1))
  fi

  if grep -q "SoftMaster Playback Volume" /etc/asound.conf 2>/dev/null \
     && grep -q "$DAC_CARD" /etc/asound.conf 2>/dev/null; then
    ok "volume control bound to the DAC card only"
  else
    fail "volume control is not bound to the DAC card"; rc=$((rc + 1))
  fi

  if grep -q 'mixer_type[[:space:]]*"none"' /etc/mpd.conf 2>/dev/null; then
    ok "MPD mixer disabled (MPD volume cannot touch the second output)"
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

  case "$v" in
    jack)
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
      ;;
    hdmi)
      if hdmi_edid_ok; then
        ok "HDMI extractor present (EDID detected)"
      else
        fail "HDMI branch is live but no EDID is visible"; rc=$((rc + 1))
      fi
      ;;
    usb)
      if [ -n "$USB_CARD" ] && [ -e "/proc/asound/$USB_CARD" ]; then
        ok "USB sound card present ($USB_CARD)"
      else
        fail "USB branch is live but the card is not present"; rc=$((rc + 1))
      fi
      ;;
    daconly)
      if [ "$SECOND_OUTPUT" = "hdmi" ]; then
        warn "second output (HDMI) currently unavailable; DAC-only fallback active"
      elif [ "$SECOND_OUTPUT" = "usb" ]; then
        warn "second output (USB) currently unavailable; DAC-only fallback active"
      else
        warn "no second output configured"
      fi
      ;;
  esac
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

  if [ "$v" != "daconly" ] && [ "$v" != "none" ]; then
    if [ "$ANALYSER_TRIM" = "on" ]; then
      if grep -q 'pcm.jukeboxEq' /etc/asound.conf 2>/dev/null \
         && grep -q 'type *equal' /etc/asound.conf 2>/dev/null; then
        ok "analyser bass trim active (${ANALYSER_FREQ_HZ} Hz ${ANALYSER_GAIN_DB} dB on the second branch)"
      else
        fail "analyser bass trim enabled but the equal plugin is not wired in"; rc=$((rc + 1))
      fi
      if [ -f "$EQ_CONTROLS_DEST" ]; then
        ok "analyser controls file present ($EQ_CONTROLS_DEST)"
      else
        fail "analyser controls file missing ($EQ_CONTROLS_DEST)"; rc=$((rc + 1))
      fi
    else
      if grep -q 'pcm.jukeboxEq' /etc/asound.conf 2>/dev/null \
         && grep -q 'type *equal' /etc/asound.conf 2>/dev/null; then
        fail "analyser bass trim is set to off but the equal plugin is still wired in"; rc=$((rc + 1))
      else
        ok "analyser bass trim disabled (transparent second branch)"
      fi
    fi
  fi

  if alsa_playback_test "$v"; then
    if [ "$v" = "daconly" ]; then
      ok "chain opens (DAC only)"
    else
      ok "chain opens both outputs simultaneously"
    fi
  else
    fail "could not open the chain (is something else playing?)"; rc=$((rc + 1))
  fi

  if [ "$PLAY_TEST" = 1 ]; then
    local prc=0
    mpd_playback_test || prc=$?
    case "$prc" in
      0) ok "MPD playback runs through the chain" ;;
      2) warn "MPD playback test skipped (nothing to play)" ;;
      *) fail "MPD playback test failed"; rc=$((rc + 1)) ;;
    esac
  fi

  if [ "$rc" = 0 ]; then
    say "All checks passed"
  else
    say "$rc check(s) failed"
  fi
  return "$rc"
}

cmd_status() {
  load_config_env
  detect_cards >/dev/null 2>&1 || true
  local v
  v="$(live_variant)"
  echo "jukebox-audio v$VERSION"
  if [ -d "$APPLY_DIR" ]; then echo "installed       : yes ($APPLY_DIR)"; else echo "installed       : no"; fi
  echo "second output   : $SECOND_OUTPUT"
  echo "live variant    : $v"
  echo "guard service   : $(systemctl is-enabled jukebox-audio-guard.service 2>/dev/null || echo -) / $(systemctl is-active jukebox-audio-guard.service 2>/dev/null || echo -)"
  echo "guard watcher   : $(systemctl is-enabled jukebox-audio-guard.path 2>/dev/null || echo -) / $(systemctl is-active jukebox-audio-guard.path 2>/dev/null || echo -)"
  if [ "$SECOND_OUTPUT" = "hdmi" ]; then
    if hdmi_edid_ok; then echo "hdmi sink       : present (EDID)"; else echo "hdmi sink       : absent (DAC-only fallback)"; fi
  fi
  if [ "$SECOND_OUTPUT" = "usb" ]; then
    if detect_usb_card; then echo "usb card        : present ($USB_CARD)"; else echo "usb card        : absent (DAC-only fallback)"; fi
  fi
  if grep -q 'mixer_type[[:space:]]*"none"' /etc/mpd.conf 2>/dev/null; then echo "mpd mixer       : disabled"; else echo "mpd mixer       : active (may affect second output)"; fi
  if [ "$ANALYSER_TRIM" = "on" ]; then
    echo "analyser trim   : on (${ANALYSER_FREQ_HZ} Hz ${ANALYSER_GAIN_DB} dB, Q ${ANALYSER_Q})"
  else
    echo "analyser trim   : off"
  fi
}

cmd_uninstall() {
  require_root
  say "Uninstalling jukebox dual output"
  remove_units
  ok "guard units and udev rule removed"

  local backup_dir
  backup_dir="$(readlink -f "$BACKUP_ROOT/latest" 2>/dev/null || true)"
  if [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
    local pair src b
    for pair in "/etc/asound.conf:asound.conf" \
                "/etc/mpd.conf:mpd.conf" \
                "$SNIPPET_PATH:softvolume.postVolume.conf" \
                "$ALSA_CONFIG_JSON:config.json" \
                "$SPECIAL_CARDS_JSON:special_cards_config.json" \
                "/var/lib/alsa/asound.state:asound.state"; do
      src="${pair%%:*}"
      b="${pair##*:}"
      [ -f "$backup_dir/$b" ] || continue
      # A restore point that already carries jukebox markers is not a clean
      # pre-install state (older installer poisoned it). Drop the managed file
      # instead and let Volumio regenerate its own configuration.
      if grep -q "jukebox-audio variant:" "$backup_dir/$b" 2>/dev/null; then
        warn "backup $b is a managed state, not a clean one; removing $src"
        rm -f "$src"
        continue
      fi
      cp -a "$backup_dir/$b" "$src" && ok "restored $src"
    done
  else
    warn "no backup found; Volumio will regenerate its own configuration"
  fi

  rm -rf "$APPLY_DIR"
  rm -rf /var/lib/jukebox-audio
  systemctl restart volumio >/dev/null 2>&1 || true
  systemctl restart mpd >/dev/null 2>&1 || true
  ok "uninstalled (reboot recommended)"
}

main() {
  local mode=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --with-playback) PLAY_TEST=1; shift ;;
      --boot) BOOT_APPLY=1; shift ;;
      --second-output=*) SECOND_OUTPUT="${1#*=}"; shift ;;
      --second-output)
        shift
        [ $# -gt 0 ] || die "--second-output needs a value: jack|hdmi|usb|none"
        SECOND_OUTPUT="$1"
        shift
        ;;
      --no-analyser-trim) ANALYSER_TRIM=off; shift ;;
      --analyser-trim=*) ANALYSER_TRIM="${1#*=}"; shift ;;
      --analyser-trim)
        shift
        [ $# -gt 0 ] || die "--analyser-trim needs a value: on|off"
        ANALYSER_TRIM="$1"
        shift
        ;;
      --no-tone) TONE_ENABLE=off; shift ;;
      --tone=*) TONE_ENABLE="${1#*=}"; shift ;;
      --tone)
        shift
        [ $# -gt 0 ] || die "--tone needs a value: on|off"
        TONE_ENABLE="$1"
        shift
        ;;
      --tone-bass=*) TONE_BASS_FREQ="${1#*=}"; shift ;;
      --tone-bass)
        shift
        [ $# -gt 0 ] || die "--tone-bass needs a value in Hz"
        TONE_BASS_FREQ="$1"; shift
        ;;
      --tone-treble=*) TONE_TREBLE_FREQ="${1#*=}"; shift ;;
      --tone-treble)
        shift
        [ $# -gt 0 ] || die "--tone-treble needs a value in Hz"
        TONE_TREBLE_FREQ="$1"; shift
        ;;
      --tone-q=*) TONE_SHELF_Q="${1#*=}"; shift ;;
      --tone-q)
        shift
        [ $# -gt 0 ] || die "--tone-q needs a value"
        TONE_SHELF_Q="$1"; shift
        ;;
      --analyser-freq=*) ANALYSER_FREQ_HZ="${1#*=}"; shift ;;
      --analyser-gain=*) ANALYSER_GAIN_DB="${1#*=}"; shift ;;
      --analyser-q=*) ANALYSER_Q="${1#*=}"; shift ;;
      -h|--help) usage; exit 0 ;;
      install|apply|verify|status|uninstall) mode="$1"; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  case "$SECOND_OUTPUT" in
    jack|hdmi|usb|none) ;;
    *) die "--second-output must be jack|hdmi|usb|none (got: $SECOND_OUTPUT)" ;;
  esac
  case "$ANALYSER_TRIM" in
    on|off) ;;
    *) die "--analyser-trim must be on|off (got: $ANALYSER_TRIM)" ;;
  esac
  case "$TONE_ENABLE" in
    on|off) ;;
    *) die "--tone must be on|off (got: $TONE_ENABLE)" ;;
  esac
  [ -n "$mode" ] || { usage; exit 1; }
  case "$mode" in
    install)   cmd_install ;;
    apply)     cmd_apply ;;
    verify)    require_root; detect_cards || die "could not detect audio cards"; load_config_env; cmd_verify ;;
    status)    cmd_status ;;
    uninstall) cmd_uninstall ;;
  esac
}

main "$@"
