#!/usr/bin/env bash
#
# install.sh - wire the KeyboardArduino to the jukebox playback transport.
#
# Installs a small always-on daemon that reads key events from the keyboard
# board's USB serial port and runs the matching Volumio command on key press
# (play, pause, stop, previous track, next track).
#
# The install is idempotent: running it again just re-asserts the same files,
# keeps the existing key map and restarts the service.
#
# Usage (on the Volumio host, as root):
#   sudo ./install.sh                 # install / re-assert
#   sudo ./install.sh status
#   sudo ./install.sh verify
#   sudo ./install.sh uninstall
#
# Options:
#   --key-action ROW,COL    assign a key to an action; repeatable. Actions:
#                           play|pause|stop|prev|next
#   --port DEV              serial device (default: auto-detect by product)
#   --product STR           USB product string of the keyboard board
#                           (default: "Jukebox Keyboard")
#
# From a development machine use deploy.sh, which copies this directory over
# SSH and runs this script remotely.
#
set -euo pipefail

VERSION="1.0.0"

APPLY_DIR="/usr/local/jukebox-keyboard"
CONFIG_ENV="$APPLY_DIR/config.env"
UNIT="/etc/systemd/system/jukebox-keyboard.service"
UDEV_RULE="/etc/udev/rules.d/89-jukebox-keyboard.rules"

PORT=""
PRODUCT="Jukebox Keyboard"
BAUD="9600"

# Key assignments, as "row,col"; kept in config.env so a re-run does not lose
# the identified keys.
KEY_PLAY=""
KEY_PAUSE=""
KEY_STOP=""
KEY_PREV=""
KEY_NEXT=""

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*"; }
fail() { printf '    \033[1;31mFAIL\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"; }

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load a previous key map so re-running install keeps it unless overridden.
load_existing_config() {
  [ -f "$CONFIG_ENV" ] || return 0
  # shellcheck disable=SC1090
  . "$CONFIG_ENV" 2>/dev/null || return 0
  PORT="${JK_PORT:-$PORT}"
  PRODUCT="${JK_PRODUCT:-$PRODUCT}"
  BAUD="${JK_BAUD:-$BAUD}"
  KEY_PLAY="${JK_KEY_PLAY:-$KEY_PLAY}"
  KEY_PAUSE="${JK_KEY_PAUSE:-$KEY_PAUSE}"
  KEY_STOP="${JK_KEY_STOP:-$KEY_STOP}"
  KEY_PREV="${JK_KEY_PREV:-$KEY_PREV}"
  KEY_NEXT="${JK_KEY_NEXT:-$KEY_NEXT}"
}

write_config() {
  mkdir -p "$APPLY_DIR"
  cat >"$CONFIG_ENV" <<EOF
# jukebox-keyboard settings (edited by install.sh; read by the service)
JK_PORT=$PORT
JK_PRODUCT=$PRODUCT
JK_BAUD=$BAUD
JK_KEY_PLAY=$KEY_PLAY
JK_KEY_PAUSE=$KEY_PAUSE
JK_KEY_STOP=$KEY_STOP
JK_KEY_PREV=$KEY_PREV
JK_KEY_NEXT=$KEY_NEXT
EOF
}

install_files() {
  mkdir -p "$APPLY_DIR"
  install -m 0755 "$SCRIPT_DIR/jukebox-keyboard.py" "$APPLY_DIR/jukebox-keyboard.py"
  echo "$VERSION" >"$APPLY_DIR/VERSION"
  write_config
}

install_unit() {
  cat >"$UNIT" <<EOF
[Unit]
Description=Jukebox keyboard playback keys (KeyboardArduino)
After=volumio.service sound.target
Wants=volumio.service

[Service]
Type=simple
EnvironmentFile=-$CONFIG_ENV
ExecStart=$APPLY_DIR/jukebox-keyboard.py
Restart=always
RestartSec=3
Nice=5

[Install]
WantedBy=multi-user.target
EOF
  cat >"$UDEV_RULE" <<'EOF'
# Rescan for the KeyboardArduino as soon as its serial port appears.
ACTION=="add", SUBSYSTEM=="tty", KERNEL=="ttyACM*|ttyUSB*", RUN+="/usr/bin/systemctl --no-block restart jukebox-keyboard.service"
EOF
  systemctl daemon-reload
  udevadm control --reload-rules >/dev/null 2>&1 || true
}

enable_service() {
  systemctl enable jukebox-keyboard.service >/dev/null 2>&1 || true
  systemctl restart jukebox-keyboard.service
}

keys_to_assign() {
  [ -n "$KEY_PLAY" ] && echo "play=$KEY_PLAY"
  [ -n "$KEY_PAUSE" ] && echo "pause=$KEY_PAUSE"
  [ -n "$KEY_STOP" ] && echo "stop=$KEY_STOP"
  [ -n "$KEY_PREV" ] && echo "prev=$KEY_PREV"
  [ -n "$KEY_NEXT" ] && echo "next=$KEY_NEXT"
  true
}

cmd_install() {
  require_root
  load_existing_config

  say "Installing jukebox-keyboard (v$VERSION)"
  echo "    keyboard     : ${PORT:-auto-detect by USB product}"
  echo "    USB product  : $PRODUCT"
  local assigned
  assigned="$(keys_to_assign || true)"
  if [ -n "$assigned" ]; then
    echo "    keys         : $(echo "$assigned" | tr '\n' ' ')"
  else
    warn "no keys assigned yet; run the daemon with --watch to identify them"
  fi

  say "Installing files in $APPLY_DIR"
  install_files
  ok "daemon + config written"

  say "Installing systemd unit and udev rule"
  install_unit
  ok "$UNIT"

  say "Starting service"
  enable_service
  sleep 1
  systemctl is-active --quiet jukebox-keyboard.service \
    && ok "jukebox-keyboard.service is running" \
    || fail "jukebox-keyboard.service failed to start"

  cmd_verify || true

  say "Done"
  cat <<EOF
    Press a key and the matching playback command runs immediately. Assign or
    change keys with --key-action ROW,COL (or edit $CONFIG_ENV and re-run).

    * Identify keys : sudo $APPLY_DIR/jukebox-keyboard.py --watch
    * Logs          : journalctl -u jukebox-keyboard -f
    * Revert        : sudo $0 uninstall
EOF
}

cmd_verify() {
  require_root
  local rc=0 assigned
  say "Verification"

  [ -x "$APPLY_DIR/jukebox-keyboard.py" ] && ok "daemon installed" || { fail "daemon missing"; rc=$((rc+1)); }
  systemctl is-enabled --quiet jukebox-keyboard.service && ok "service is enabled at boot" || { fail "service is not enabled"; rc=$((rc+1)); }
  systemctl is-active --quiet jukebox-keyboard.service && ok "service is running" || { fail "service is not running"; rc=$((rc+1)); }

  if python3 "$APPLY_DIR/jukebox-keyboard.py" --probe >/dev/null 2>&1; then
    ok "board detected"
  else
    warn "keyboard board not detected right now (plug it in; the service will pick it up)"
  fi

  assigned="$(keys_to_assign || true)"
  if [ -n "$assigned" ]; then
    ok "keys assigned: $(echo "$assigned" | tr '\n' ' ')"
  else
    warn "no keys assigned yet"
  fi

  [ "$rc" = 0 ] && say "All checks passed" || say "$rc check(s) failed"
  return "$rc"
}

cmd_status() {
  [ -f "$CONFIG_ENV" ] && . "$CONFIG_ENV" || true
  echo "jukebox-keyboard v$(cat "$APPLY_DIR/VERSION" 2>/dev/null || echo '?')"
  echo "installed    : $([ -d "$APPLY_DIR" ] && echo "yes ($APPLY_DIR)" || echo no)"
  echo "service      : $(systemctl is-enabled jukebox-keyboard.service 2>/dev/null || echo -) / $(systemctl is-active jukebox-keyboard.service 2>/dev/null || echo -)"
  if [ -x "$APPLY_DIR/jukebox-keyboard.py" ]; then
    JK_PORT="${JK_PORT:-}" JK_PRODUCT="${JK_PRODUCT:-Jukebox Keyboard}" python3 "$APPLY_DIR/jukebox-keyboard.py" --probe 2>/dev/null || true
  fi
}

cmd_uninstall() {
  require_root
  say "Uninstalling jukebox-keyboard"
  systemctl disable --now jukebox-keyboard.service >/dev/null 2>&1 || true
  rm -f "$UNIT" "$UDEV_RULE"
  systemctl daemon-reload
  udevadm control --reload-rules >/dev/null 2>&1 || true
  rm -rf "$APPLY_DIR"
  ok "service, unit, udev rule and files removed"
}

set_key() {
  case "$1" in
    play)  KEY_PLAY="$2" ;;
    pause) KEY_PAUSE="$2" ;;
    stop)  KEY_STOP="$2" ;;
    prev)  KEY_PREV="$2" ;;
    next)  KEY_NEXT="$2" ;;
    *) die "unknown action for --key-action: $1 (use play|pause|stop|prev|next)" ;;
  esac
}

main() {
  local mode="install"
  while [ $# -gt 0 ]; do
    case "$1" in
      --key-action)  set_key "$2" "$3"; shift 3 ;;
      --key-action=*) v="${1#*=}"; set_key "${v%%,*}" "${v#*,}"; shift ;;
      --port) PORT="$2"; shift 2 ;;
      --port=*) PORT="${1#*=}"; shift ;;
      --product) PRODUCT="$2"; shift 2 ;;
      --product=*) PRODUCT="${1#*=}"; shift ;;
      install|verify|status|uninstall) mode="$1"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  case "$mode" in
    install) cmd_install ;;
    verify) cmd_verify ;;
    status) cmd_status ;;
    uninstall) cmd_uninstall ;;
  esac
}

main "$@"
