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
#
# Undo with ./uninstall.sh (or deploy.sh uninstall).
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
#   --power-button / --no-power-button
#                          the Arduino's power button halts the Pi on a short
#                          press (default: on); the relay is cut after the Pi
#                          is down, with --power-off-delay seconds of margin
#   --power-off-delay N    seconds the Arduino waits before cutting the relay
#                          (default: 30)
#   --power-cmd "CMD"      command used to halt the Pi (default: systemctl poweroff)
#
# Everything that lands on the host lives in files/ (readable, human) and is
# copied or rendered from there; this script only orchestrates.
#
# From a development machine use deploy.sh, which copies this directory over
# SSH and runs this script remotely.
#
set -euo pipefail

VERSION="1.4.0"

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
POWER_BUTTON="1"
POWER_OFF_DELAY="30"
POWER_CMD=""

# ------------------------------------------------------------------- helpers

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*"; }
fail() { printf '    \033[1;31mFAIL\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"; }

usage() { sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"

# render_template TEMPLATE OUT NAME=VALUE ...  -> replaces @NAME@ placeholders.
render_template() {
  local tmpl="$1" out="$2"; shift 2
  local sedargs=() kv name val
  for kv in "$@"; do
    name="${kv%%=*}"
    val="${kv#*=}"
    val="$(printf '%s' "$val" | sed -e 's/[&\\|]/\\&/g')"
    sedargs+=(-e "s|@${name}@|${val}|g")
  done
  sed "${sedargs[@]}" "$tmpl" >"$out"
}

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
  render_template "$FILES_DIR/config.env.in" "$CONFIG_ENV" \
    "DAC_CARD=$DAC_CARD" "PORT=$PORT" "PRODUCT=$PRODUCT" "BAUD=$BAUD" \
    "VOLUME_MAX=$VOLUME_MAX" "POT_MAX=$POT_MAX" \
    "BALANCE_CENTER=$BALANCE_CENTER" "BALANCE_SPAN=$BALANCE_SPAN" \
    "VOLUME_INVERT=$VOLUME_INVERT" "BALANCE_INVERT=$BALANCE_INVERT" \
    "USE_API=$USE_API" "TONE_ENABLE=$TONE_ENABLE" "TONE_MAX_DB=$TONE_MAX_DB" \
    "TONE_CENTER=$TONE_CENTER" "TONE_SPAN=$TONE_SPAN" \
    "TONE_BASS_POT=$TONE_BASS_POT" "TONE_TREBLE_POT=$TONE_TREBLE_POT" \
    "TONE_BASS_INVERT=$TONE_BASS_INVERT" "TONE_TREBLE_INVERT=$TONE_TREBLE_INVERT" \
    "POWER_BUTTON=$POWER_BUTTON" "POWER_OFF_DELAY_S=$POWER_OFF_DELAY" \
    "POWER_CMD=$POWER_CMD"
}

install_files() {
  mkdir -p "$APPLY_DIR"
  install -m 0755 "$FILES_DIR/jukebox-pots.py" "$APPLY_DIR/jukebox-pots.py"
  echo "$VERSION" >"$APPLY_DIR/VERSION"
  write_config
}

install_unit() {
  install -m 0644 "$FILES_DIR/jukebox-pots.service" "$UNIT"
  install -m 0644 "$FILES_DIR/89-jukebox-pots.rules" "$UDEV_RULE"
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
  [ -f "$FILES_DIR/jukebox-pots.py" ] || die "files/ not found next to install.sh"
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
  echo "    power button : $([ "$POWER_BUTTON" = 1 ] && echo "halts the Pi (relay off after ${POWER_OFF_DELAY}s)" || echo 'disabled')"
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
    * Revert    : sudo ./uninstall.sh
EOF
}

cmd_verify() {
  require_root
  local rc=0 port
  [ -f "$CONFIG_ENV" ] && . "$CONFIG_ENV" || true
  POWER_BUTTON="${JP_POWER_BUTTON:-$POWER_BUTTON}"
  POWER_OFF_DELAY="${JP_POWER_OFF_DELAY_S:-$POWER_OFF_DELAY}"
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

  if [ "${POWER_BUTTON:-0}" = "1" ]; then
    ok "power button: short press halts the Pi; relay cut after ${POWER_OFF_DELAY:-30}s (Arduino-side delay)"
  else
    warn "power button: disabled (--no-power-button): a short press won't halt the Pi"
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
      --power-button) POWER_BUTTON=1; shift ;;
      --no-power-button) POWER_BUTTON=0; shift ;;
      --power-off-delay) POWER_OFF_DELAY="$2"; shift 2 ;;
      --power-off-delay=*) POWER_OFF_DELAY="${1#*=}"; shift ;;
      --power-cmd) POWER_CMD="$2"; shift 2 ;;
      --power-cmd=*) POWER_CMD="${1#*=}"; shift ;;
      -h|--help) usage; exit 0 ;;
      install|verify|status) mode="$1"; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  case "$mode" in
    install)   cmd_install ;;
    verify)    cmd_verify ;;
    status)    cmd_status ;;
  esac
}

main "$@"
