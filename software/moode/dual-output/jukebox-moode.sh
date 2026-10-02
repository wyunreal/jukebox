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
#   sudo ./jukebox-moode.sh verify
#   sudo ./jukebox-moode.sh apply       # re-assert (used by the guard unit)
#   sudo ./jukebox-moode.sh status
#   sudo ./jukebox-moode.sh uninstall
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
        pcm         "jukeboxSplitRaw"
        format      S32_LE
    }
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
        pcm         "hw:CARD=$USB_CARD,DEV=0"
        rate        $USB_RATE
    }
}
EOF
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
  if analyser_available; then
    render_split_conf >"$SPLIT_CONF"
    chmod 0644 "$SPLIT_CONF"
    point_audioout split
    log "apply: split chain (DAC + USB analyser)"
  else
    rm -f "$SPLIT_CONF"
    point_audioout tone
    log "apply: DAC-only chain (analyser card not present)"
  fi
  ensure_mpd_running
}

install_units() {
  cat >"$GUARD_SERVICE" <<EOF
[Unit]
Description=Jukebox moOde audio guard (re-assert configuration)
After=mpd.service

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
  systemctl daemon-reload
  systemctl enable --now jukebox-moode-guard.path >/dev/null 2>&1 || true
}

remove_units() {
  systemctl disable --now jukebox-moode-guard.path >/dev/null 2>&1 || true
  systemctl disable --now jukebox-moode-guard.service >/dev/null 2>&1 || true
  rm -f "$GUARD_PATH" "$GUARD_SERVICE"
  systemctl daemon-reload
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

  if command -v aplay >/dev/null 2>&1 && aplay -L 2>/dev/null | grep -qx jukeboxSplit; then
    ok "ALSA sees the jukeboxSplit PCM"
  elif [ "$want" = "jukeboxSplit" ]; then
    fail "ALSA does not expose jukeboxSplit"; rc=$((rc+1))
  fi

  [ $rc -eq 0 ] && say "All checks passed" || say "Checks failed: $rc"
  return $rc
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
  # Hand the output config back to moOde: its own code writes the right
  # slave.pcm for the current output device / DSP selection.
  if [ -x "$APPLY_DIR/moode-sync.php" ]; then
    php "$APPLY_DIR/moode-sync.php" --restore >>"$LOG_FILE" 2>&1 || restore_audioout
  else
    restore_audioout
  fi
  if [ "$(sqlite3 "$MOODE_DB" "SELECT value FROM cfg_system WHERE param='camilladsp';" 2>/dev/null || true)" = "$TONE_NAME.yml" ]; then
    ln -sfn "$CAMILLA_CONFIGS/V4-Flat.yml" "$CAMILLA_WORKING" 2>/dev/null || true
    sqlite3 "$MOODE_DB" "UPDATE cfg_system SET value='V4-Flat.yml' WHERE param='camilladsp';" 2>/dev/null || true
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
