#!/usr/bin/env bash
#
# install.sh - wire the jukebox's PowerAndPots Arduino to the DAC volume/balance.
#
# Installs a small always-on daemon that reads "POT volume" and "POT balance"
# from the Arduino's USB serial port and maps them onto the I2S DAC software
# volume (SoftMaster): the volume pot drives the Volumio volume, the balance
# pot pans the DAC left/right.  The second, constant-level output that feeds
# the spectrum analyser is never touched.
#
# The install is idempotent: running it again just re-asserts the same files
# and restarts the service.
#
# Usage (on the Volumio host, as root):
#   sudo ./install.sh                 # install / re-assert
#   sudo ./install.sh install
#   sudo ./install.sh status
#   sudo ./install.sh uninstall
#
# Options:
#   --dac-card NAME        ALSA card id of the DAC (default: auto-detect)
#   --port DEV             serial device (default: auto-detect by USB product)
#   --product STR          USB product string of the PowerAndPots board
#                          (default: "Jukebox Pots"; must match the string
#                          compiled into the firmware via -DUSB_PRODUCT)
#   --baud N               serial baud rate (default: 9600)
#   --volume-max N         Volumio volume scale (default: 100)
#   --pot-max N            firmware pot range (default: 20)
#   --balance-center N     pot value that means "centered" (default: 10)
#   --balance-span N       pot steps from center to hard pan (default: 10)
#   --volume-invert / --no-volume-invert
#   --balance-invert / --no-balance-invert
#   --no-api               write the mixer directly instead of the player API
#   --tone / --no-tone     enable/disable the bass+treble pots (default: on)
#   --tone-max-db N        shelf range at the pot extremes (default: 8)
#   --tone-center N        pot value that means flat (default: 10)
#   --tone-span N          pot steps from center to full shelf (default: 10)
#   --tone-bass-pot NAME   firmware line for bass: single|multisecond
#   --tone-treble-pot NAME firmware line for treble: single|multisecond
#   --tone-bass-invert / --no-tone-bass-invert
#   --tone-treble-invert / --no-tone-treble-invert
#
# From a development machine use deploy.sh, which copies this directory over
# SSH and runs this script remotely.
#
set -euo pipefail

VERSION="1.2.0"

APPLY_DIR="/usr/local/jukebox-pots"
CONFIG_ENV="$APPLY_DIR/config.env"
UNIT="/etc/systemd/system/jukebox-pots.service"
UDEV_RULE="/etc/udev/rules.d/89-jukebox-pots.rules"

DAC_CARD=""
PORT=""
PRODUCT="Jukebox Pots"
BAUD="9600"
VOLUME_MAX="100"
POT_MAX="20"
BALANCE_CENTER="10"
BALANCE_SPAN="10"
VOLUME_INVERT="0"
BALANCE_INVERT="0"
USE_API="1"
TONE_ENABLE="1"
TONE_MAX_DB="8"
TONE_CENTER="10"
TONE_SPAN="10"
TONE_BASS_POT="single"
TONE_TREBLE_POT="multisecond"
TONE_BASS_INVERT="0"
TONE_TREBLE_INVERT="0"

# ------------------------------------------------------------------- helpers

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*"; }
fail() { printf '    \033[1;31mFAIL\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"; }

usage() { sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

detect_dac_card() {
  local f id
  for f in /proc/asound/card*/id; do
    [ -r "$f" ] || continue
    id="$(cat "$f" 2>/dev/null)" || continue
    case "$id" in
      *sndrpirpidac*|*pcm1794a*|*rpi-dac*|*RPiDAC*) echo "$id"; return 0 ;;
    esac
  done
  return 1
}

# The jukebox runs on a Volumio box; this detection only tells a plain
# Raspberry Pi OS apart from the player for friendlier messages (the unit is
# the same either way).
detect_platform() {
  if [ -e /volumio ]; then
    echo volumio
  else
    echo generic
  fi
}

# ------------------------------------------------------------------- install

write_config() {
  mkdir -p "$APPLY_DIR"
  cat >"$CONFIG_ENV" <<EOF
# jukebox-pots settings (edited by install.sh; read by the service)
JP_DAC_CARD=$DAC_CARD
JP_PORT=$PORT
JP_PRODUCT=$PRODUCT
JP_BAUD=$BAUD
JP_OVERLAY=1
JP_OVERLAY_URL=http://localhost:3210/update
JP_VOLUME_MAX=$VOLUME_MAX
JP_POT_MAX=$POT_MAX
JP_BALANCE_CENTER=$BALANCE_CENTER
JP_BALANCE_SPAN=$BALANCE_SPAN
JP_VOLUME_INVERT=$VOLUME_INVERT
JP_BALANCE_INVERT=$BALANCE_INVERT
JP_USE_API=$USE_API
JP_TONE=$TONE_ENABLE
JP_TONE_MAX_DB=$TONE_MAX_DB
JP_TONE_CENTER=$TONE_CENTER
JP_TONE_SPAN=$TONE_SPAN
JP_TONE_BASS_POT=$TONE_BASS_POT
JP_TONE_TREBLE_POT=$TONE_TREBLE_POT
JP_TONE_BASS_INVERT=$TONE_BASS_INVERT
JP_TONE_TREBLE_INVERT=$TONE_TREBLE_INVERT
EOF
}

install_files() {
  mkdir -p "$APPLY_DIR"
  install -m 0755 "$SCRIPT_DIR/jukebox-pots.py" "$APPLY_DIR/jukebox-pots.py"
  echo "$VERSION" >"$APPLY_DIR/VERSION"
  write_config
}

install_unit() {
  cat >"$UNIT" <<EOF
[Unit]
Description=Jukebox pot volume/balance (PowerAndPots Arduino)
After=volumio.service sound.target
Wants=volumio.service

[Service]
Type=simple
EnvironmentFile=-$CONFIG_ENV
ExecStart=$APPLY_DIR/jukebox-pots.py
Restart=always
RestartSec=3
Nice=5

[Install]
WantedBy=multi-user.target
EOF
  cat >"$UDEV_RULE" <<'EOF'
# Rescan for the PowerAndPots Arduino as soon as its serial port appears.
ACTION=="add", SUBSYSTEM=="tty", KERNEL=="ttyACM*|ttyUSB*", RUN+="/usr/bin/systemctl --no-block restart jukebox-pots.service"
EOF
  systemctl daemon-reload
  udevadm control --reload-rules >/dev/null 2>&1 || true
}

enable_service() {
  # The tone control rewrites CamillaDSP's active config, so the directory
  # must stay writable for both this service and MPD's cdsp plugin.
  install -d -m 0777 /var/lib/jukebox-audio 2>/dev/null || true
  chmod 0777 /var/lib/jukebox-audio 2>/dev/null || true
  systemctl enable jukebox-pots.service >/dev/null 2>&1 || true
  systemctl restart jukebox-pots.service
}

cmd_install() {
  require_root
  if [ -z "$DAC_CARD" ]; then
    DAC_CARD="$(detect_dac_card)" \
      || die "could not detect the I2S DAC in /proc/asound (pass --dac-card)"
  fi
  [ -e "/proc/asound/$DAC_CARD" ] || die "ALSA card '$DAC_CARD' does not exist"

  say "Installing jukebox-pots (v$VERSION)"
  echo "    DAC card     : $DAC_CARD"
  echo "    serial port  : ${PORT:-auto-detect by USB product}"
  echo "    USB product  : $PRODUCT"
  echo "    volume       : pot 0..$POT_MAX -> 0..$VOLUME_MAX$([ "$VOLUME_INVERT" = 1 ] && echo ' (inverted)')"
  echo "    balance      : pot center $BALANCE_CENTER, span $BALANCE_SPAN$([ "$BALANCE_INVERT" = 1 ] && echo ' (inverted)')"
  local platform backend_desc
  platform="$(detect_platform)"
  if [ "$USE_API" = "1" ]; then
    backend_desc="Volumio API + SoftMaster balance"
  else
    backend_desc="direct ALSA mixer"
  fi
  echo "    platform     : $platform ($backend_desc)"

  say "Installing files in $APPLY_DIR"
  install_files
  ok "daemon + config written"

  say "Installing systemd unit and udev rule"
  install_unit
  ok "$UNIT"

  say "Starting service"
  enable_service
  sleep 1
  if systemctl is-active --quiet jukebox-pots.service; then
    ok "jukebox-pots.service is running"
  else
    fail "jukebox-pots.service failed to start"
  fi

  cmd_verify || true

  say "Done"
  cat <<EOF
    The service starts at boot and stays up; it re-scans for the Arduino if it
    is unplugged. Only the DAC branch is affected — the analyser feed is fixed.

    * Logs      : journalctl -u jukebox-pots -f
    * Status    : sudo $0 status
    * Revert    : sudo $0 uninstall
EOF
}

cmd_verify() {
  require_root
  local rc=0 port
  say "Verification"

  if [ -x "$APPLY_DIR/jukebox-pots.py" ]; then
    ok "daemon installed ($APPLY_DIR/jukebox-pots.py)"
  else
    fail "daemon missing"; rc=$((rc + 1))
  fi

  if python3 "$APPLY_DIR/jukebox-pots.py" --selftest >/dev/null 2>&1; then
    ok "mapping self-tests pass"
  else
    fail "mapping self-tests failed"; rc=$((rc + 1))
  fi

  if systemctl is-enabled --quiet jukebox-pots.service; then
    ok "service is enabled at boot"
  else
    fail "service is not enabled"; rc=$((rc + 1))
  fi
  if systemctl is-active --quiet jukebox-pots.service; then
    ok "service is running"
  else
    fail "service is not running"; rc=$((rc + 1))
  fi

  port="$(JP_DAC_CARD="$DAC_CARD" JP_PORT="$PORT" JP_PRODUCT="$PRODUCT" python3 "$APPLY_DIR/jukebox-pots.py" --probe 2>/dev/null | sed -n 's/^serial port   : //p')"
  case "$port" in
    ""|"<not found>")
      warn "Arduino serial port not detected right now (plug it in; the service will pick it up)"
      ;;
    *)
      ok "Arduino serial port: $port"
      ;;
  esac

  if [ "${TONE_ENABLE:-1}" = "1" ]; then
    local tone_ok=0
    if ls /usr/local/jukebox-audio/cdsp/camilla.*.yml >/dev/null 2>&1; then
      ok "tone control config present (CamillaDSP shelves)"
      tone_ok=1
    fi
    [ "$tone_ok" = 1 ] || warn "tone control enabled but no CamillaDSP config found (install the dual-output package)"
    if [ -x /usr/local/bin/camilladsp ]; then
      ok "CamillaDSP present"
    else
      warn "CamillaDSP binary missing; the tone pots will have no effect"
    fi
  fi

  if amixer -c "$DAC_CARD" sget SoftMaster >/dev/null 2>&1; then
    ok "SoftMaster volume control present on $DAC_CARD (DAC branch only)"
  else
    warn "SoftMaster not materialized yet (appears on first playback)"
  fi

  [ "$rc" = 0 ] && say "All checks passed" || say "$rc check(s) failed"
  return "$rc"
}

cmd_status() {
  [ -f "$CONFIG_ENV" ] && . "$CONFIG_ENV" || true
  DAC_CARD="${JP_DAC_CARD:-$DAC_CARD}"
  echo "jukebox-pots v$(cat "$APPLY_DIR/VERSION" 2>/dev/null || echo '?')"
  echo "installed    : $([ -d "$APPLY_DIR" ] && echo "yes ($APPLY_DIR)" || echo no)"
  echo "service      : $(systemctl is-enabled jukebox-pots.service 2>/dev/null || echo -) / $(systemctl is-active jukebox-pots.service 2>/dev/null || echo -)"
  if [ -x "$APPLY_DIR/jukebox-pots.py" ]; then
    JP_DAC_CARD="$DAC_CARD" JP_PORT="${JP_PORT:-}" JP_PRODUCT="${JP_PRODUCT:-Jukebox Pots}" python3 "$APPLY_DIR/jukebox-pots.py" --probe 2>/dev/null || true
  fi
  if amixer -c "$DAC_CARD" sget SoftMaster >/dev/null 2>&1; then
    amixer -c "$DAC_CARD" sget SoftMaster | grep -E "Front (Left|Right)"
  fi
}

cmd_uninstall() {
  require_root
  say "Uninstalling jukebox-pots"
  systemctl disable --now jukebox-pots.service >/dev/null 2>&1 || true
  rm -f "$UNIT" "$UDEV_RULE"
  systemctl daemon-reload
  udevadm control --reload-rules >/dev/null 2>&1 || true
  rm -rf "$APPLY_DIR"
  ok "service, unit, udev rule and files removed"
}

main() {
  local mode="install"
  while [ $# -gt 0 ]; do
    case "$1" in
      --dac-card) DAC_CARD="$2"; shift 2 ;;
      --dac-card=*) DAC_CARD="${1#*=}"; shift ;;
      --port) PORT="$2"; shift 2 ;;
      --port=*) PORT="${1#*=}"; shift ;;
      --product) PRODUCT="$2"; shift 2 ;;
      --product=*) PRODUCT="${1#*=}"; shift ;;
      --baud) BAUD="$2"; shift 2 ;;
      --volume-max) VOLUME_MAX="$2"; shift 2 ;;
      --pot-max) POT_MAX="$2"; shift 2 ;;
      --balance-center) BALANCE_CENTER="$2"; shift 2 ;;
      --balance-span) BALANCE_SPAN="$2"; shift 2 ;;
      --volume-invert) VOLUME_INVERT=1; shift ;;
      --no-volume-invert) VOLUME_INVERT=0; shift ;;
      --balance-invert) BALANCE_INVERT=1; shift ;;
      --no-balance-invert) BALANCE_INVERT=0; shift ;;
      --no-api) USE_API=0; shift ;;
      --tone) TONE_ENABLE=1; shift ;;
      --no-tone) TONE_ENABLE=0; shift ;;
      --tone-max-db) TONE_MAX_DB="$2"; shift 2 ;;
      --tone-center) TONE_CENTER="$2"; shift 2 ;;
      --tone-span) TONE_SPAN="$2"; shift 2 ;;
      --tone-bass-pot) TONE_BASS_POT="$2"; shift 2 ;;
      --tone-treble-pot) TONE_TREBLE_POT="$2"; shift 2 ;;
      --tone-max-db=*) TONE_MAX_DB="${1#*=}"; shift ;;
      --tone-center=*) TONE_CENTER="${1#*=}"; shift ;;
      --tone-span=*) TONE_SPAN="${1#*=}"; shift ;;
      --tone-bass-pot=*) TONE_BASS_POT="${1#*=}"; shift ;;
      --tone-treble-pot=*) TONE_TREBLE_POT="${1#*=}"; shift ;;
      --tone-bass-invert) TONE_BASS_INVERT=1; shift ;;
      --no-tone-bass-invert) TONE_BASS_INVERT=0; shift ;;
      --tone-treble-invert) TONE_TREBLE_INVERT=1; shift ;;
      --no-tone-treble-invert) TONE_TREBLE_INVERT=0; shift ;;
      -h|--help) usage; exit 0 ;;
      install|verify|status|uninstall) mode="$1"; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  case "$mode" in
    install)   cmd_install ;;
    verify)    cmd_verify ;;
    status)    cmd_status ;;
    uninstall) cmd_uninstall ;;
  esac
}

main "$@"
