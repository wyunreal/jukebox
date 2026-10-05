#!/usr/bin/env bash
#
# install.sh - wire the KeyboardArduino to the jukebox playback transport.
#
# Install a small always-on daemon that reads key events from the keyboard
# board's USB serial port and runs the matching Volumio command on key press
# (play, pause, stop, previous track, next track).
#
# The map is versioned in files/keymap.conf and installed as-is, so a fresh box
# (or a re-install) gets exactly the same keys. The install is idempotent.
#
# Usage (on the Volumio host, as root):
#   sudo ./install.sh                 # install / re-assert
#   sudo ./install.sh status
#   sudo ./install.sh verify
#
# Undo with ./uninstall.sh (or deploy.sh uninstall).
#
# Options:
#   --key-action ROW,COL    override one action for this run; repeatable. Actions:
#                           play|pause|stop|prev|next|mute|openclose|favourite|clear|savequeue
#   --port DEV              serial device (default: auto-detect by product)
#   --product STR           USB product string of the keyboard board
#                           (default: "Jukebox Keyboard")
#
# Everything that lands on the host lives in files/ (readable, human) and is
# copied or rendered from there; the key map lives in files/keymap.conf and this
# script only orchestrates.
#
# From a development machine use deploy.sh, which copies this directory over
# SSH and runs this script remotely.
#
set -euo pipefail

VERSION="1.7.0"

APPLY_DIR="/usr/local/jukebox-keyboard"
CONFIG_ENV="$APPLY_DIR/config.env"
UNIT="/etc/systemd/system/jukebox-keyboard.service"
UDEV_RULE="/etc/udev/rules.d/89-jukebox-keyboard.rules"

PORT=""
PRODUCT="Jukebox Keyboard"
BAUD="9600"

# Key assignments, as "row,col". Defaults come from files/keymap.conf (the repo
# is the source of truth); --key-action overrides individual entries.
KEY_PLAY=""
KEY_PAUSE=""
KEY_STOP=""
KEY_PREV=""
KEY_NEXT=""
KEY_MUTE=""
KEY_OPENCLOSE=""
KEY_FAVOURITE=""
KEY_CLEAR=""
KEY_SAVEQUEUE=""

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*"; }
fail() { printf '    \033[1;31mFAIL\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"; }

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; }

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

# Read the versioned key map (files/keymap.conf: ACTION=ROW,COL per line). It is
# the source of truth, so a fresh box gets exactly the map in the repo. Any
# --key-action given on the command line is applied afterwards and wins.
load_keymap() {
  local f="$FILES_DIR/keymap.conf" line action value
  [ -f "$f" ] || return 0
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -n "$line" ] || continue
    action="${line%%=*}"
    value="${line#*=}"
    case "$action" in
      play)      KEY_PLAY="$value" ;;
      pause)     KEY_PAUSE="$value" ;;
      stop)      KEY_STOP="$value" ;;
      prev)      KEY_PREV="$value" ;;
      next)      KEY_NEXT="$value" ;;
      mute)      KEY_MUTE="$value" ;;
      openclose|open/close)  KEY_OPENCLOSE="$value" ;;
      favourite|favorite)    KEY_FAVOURITE="$value" ;;
      clear|clearqueue)      KEY_CLEAR="$value" ;;
      savequeue|saveplaylist|save)  KEY_SAVEQUEUE="$value" ;;
    esac
  done <"$f"
}

write_config() {
  mkdir -p "$APPLY_DIR"
  render_template "$FILES_DIR/config.env.in" "$CONFIG_ENV" \
    "PORT=$PORT" "PRODUCT=$PRODUCT" "BAUD=$BAUD" \
    "KEY_PLAY=$KEY_PLAY" "KEY_PAUSE=$KEY_PAUSE" "KEY_STOP=$KEY_STOP" \
    "KEY_PREV=$KEY_PREV" "KEY_NEXT=$KEY_NEXT" "KEY_MUTE=$KEY_MUTE" \
    "KEY_OPENCLOSE=$KEY_OPENCLOSE" "KEY_FAVOURITE=$KEY_FAVOURITE" \
    "KEY_CLEAR=$KEY_CLEAR" "KEY_SAVEQUEUE=$KEY_SAVEQUEUE"
}

install_files() {
  mkdir -p "$APPLY_DIR"
  install -m 0755 "$FILES_DIR/jukebox-keyboard.py" "$APPLY_DIR/jukebox-keyboard.py"
  echo "$VERSION" >"$APPLY_DIR/VERSION"
  write_config
}

install_unit() {
  install -m 0644 "$FILES_DIR/jukebox-keyboard.service" "$UNIT"
  install -m 0644 "$FILES_DIR/89-jukebox-keyboard.rules" "$UDEV_RULE"
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
  [ -n "$KEY_MUTE" ] && echo "mute=$KEY_MUTE"
  [ -n "$KEY_OPENCLOSE" ] && echo "openclose=$KEY_OPENCLOSE"
  [ -n "$KEY_FAVOURITE" ] && echo "favourite=$KEY_FAVOURITE"
  [ -n "$KEY_CLEAR" ] && echo "clear=$KEY_CLEAR"
  [ -n "$KEY_SAVEQUEUE" ] && echo "savequeue=$KEY_SAVEQUEUE"
  true
}

cmd_install() {
  require_root
  [ -f "$FILES_DIR/jukebox-keyboard.py" ] || die "files/ not found next to install.sh"

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
    Press a key and the matching playback command runs immediately. The key map
    is versioned in files/keymap.conf; edit it there and re-run the installer
    (or use --key-action ROW,COL for a one-off override).

    * Identify keys : sudo $APPLY_DIR/jukebox-keyboard.py --watch
    * Logs          : journalctl -u jukebox-keyboard -f
    * Revert        : sudo ./uninstall.sh
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

set_key() {
  case "$1" in
    play)  KEY_PLAY="$2" ;;
    pause) KEY_PAUSE="$2" ;;
    stop)  KEY_STOP="$2" ;;
    prev)  KEY_PREV="$2" ;;
    next)  KEY_NEXT="$2" ;;
    mute)  KEY_MUTE="$2" ;;
    openclose|open/close)  KEY_OPENCLOSE="$2" ;;
    favourite|favorite)  KEY_FAVOURITE="$2" ;;
    clear|clearqueue)  KEY_CLEAR="$2" ;;
    savequeue|saveplaylist|save)  KEY_SAVEQUEUE="$2" ;;
    *) die "unknown action for --key-action: $1 (use play|pause|stop|prev|next|mute|openclose|favourite|clear|savequeue)" ;;
  esac
}

main() {
  local mode="install"
  # Seed the key map from the repo; any --key-action then overrides it.
  load_keymap
  while [ $# -gt 0 ]; do
    case "$1" in
      --key-action)  set_key "$2" "$3"; shift 3 ;;
      --key-action=*) v="${1#*=}"; set_key "${v%%,*}" "${v#*,}"; shift ;;
      --port) PORT="$2"; shift 2 ;;
      --port=*) PORT="${1#*=}"; shift ;;
      --product) PRODUCT="$2"; shift 2 ;;
      --product=*) PRODUCT="${1#*=}"; shift ;;
      install|verify|status) mode="$1"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  case "$mode" in
    install) cmd_install ;;
    verify) cmd_verify ;;
    status) cmd_status ;;
  esac
}

main "$@"
