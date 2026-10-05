#!/usr/bin/env bash
#
# install.sh - install the jukebox UI command channel on a Volumio host.
#
# Lets a local daemon ask the Volumio UI to change screen or toggle favourite
# (used by the keyboard's open/close and favourite keys). A small local
# HTTP/SSE server carries the command and a loader injected into the UI pages
# calls the UI's router/services.
#
# Run ON the Volumio host as root:
#   sudo ./install.sh            # install / re-assert
#   sudo ./install.sh status
#   sudo ./install.sh verify
#
# Undo with ./uninstall.sh (or deploy.sh uninstall).
#
# Everything that lands on the host lives in files/ (readable, human) and is
# copied or rendered from there; this script only orchestrates.
#
# From a development machine use deploy.sh.
#
set -euo pipefail

VERSION="1.4.0"

DEST="/usr/local/jukebox-ui-nav"
CONFIG_ENV="$DEST/config.env"
UNIT="/etc/systemd/system/jukebox-ui-nav.service"
GUARD_SERVICE="/etc/systemd/system/jukebox-ui-nav-guard.service"
GUARD_PATH="/etc/systemd/system/jukebox-ui-nav-guard.path"

PORT="3211"

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*"; }
fail() { printf '    \033[1;31mFAIL\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"; }

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

install_files() {
  mkdir -p "$DEST"
  install -m 0755 "$FILES_DIR/ui-nav.py" "$DEST/ui-nav.py"
  install -m 0755 "$FILES_DIR/apply.sh" "$DEST/apply.sh"
  install -m 0644 "$FILES_DIR/ui-nav.js" "$DEST/ui-nav.js"
  install -m 0755 "$FILES_DIR/uninject.py" "$DEST/uninject.py"
  echo "$VERSION" >"$DEST/VERSION"
  render_template "$FILES_DIR/config.env.in" "$CONFIG_ENV" "PORT=$PORT"
}

install_units() {
  install -m 0644 "$FILES_DIR/jukebox-ui-nav.service" "$UNIT"
  install -m 0644 "$FILES_DIR/jukebox-ui-nav-guard.path" "$GUARD_PATH"
  install -m 0644 "$FILES_DIR/jukebox-ui-nav-guard.service" "$GUARD_SERVICE"
  systemctl daemon-reload
}

cmd_install() {
  require_root
  say "Installing jukebox-ui-nav (v$VERSION)"
  echo "    port         : $PORT"

  install_files
  ok "server + assets written to $DEST"

  say "Installing services"
  install_units
  systemctl enable jukebox-ui-nav.service >/dev/null 2>&1 || true
  systemctl restart jukebox-ui-nav.service
  systemctl enable jukebox-ui-nav-guard.path >/dev/null 2>&1 || true
  systemctl enable jukebox-ui-nav-guard.service >/dev/null 2>&1 || true
  systemctl restart jukebox-ui-nav-guard.path >/dev/null 2>&1 || true
  sleep 1
  systemctl is-active --quiet jukebox-ui-nav.service \
    && ok "ui-nav server running" \
    || fail "ui-nav server failed to start"

  say "Injecting into the Volumio UI pages"
  "$DEST/apply.sh" || true
  systemctl restart volumio-kiosk.service >/dev/null 2>&1 || true

  cmd_verify || true

  say "Done"
  cat <<EOF
    A daemon can now ask the UI to switch screens or toggle a favourite:
      curl -sX POST -d '{"type":"nav","view":"toggle"}' http://localhost:$PORT/update

    * Logs    : journalctl -u jukebox-ui-nav -f
    * Revert  : sudo ./uninstall.sh
EOF
}

cmd_verify() {
  require_root
  local rc=0 f
  say "Verification"

  [ -x "$DEST/ui-nav.py" ] && ok "server installed" || { fail "server missing"; rc=$((rc+1)); }
  systemctl is-enabled --quiet jukebox-ui-nav.service && ok "service enabled at boot" || { fail "service not enabled"; rc=$((rc+1)); }
  systemctl is-active --quiet jukebox-ui-nav.service && ok "service running" || { fail "service not running"; rc=$((rc+1)); }
  systemctl is-enabled --quiet jukebox-ui-nav-guard.path && ok "guard enabled" || { fail "guard not enabled"; rc=$((rc+1)); }

  if curl -sf "http://localhost:$PORT/ui-nav.js" >/dev/null 2>&1; then
    ok "client endpoint reachable (http://localhost:$PORT/ui-nav.js)"
  else
    fail "client endpoint not reachable on port $PORT"; rc=$((rc+1))
  fi

  for f in /volumio/http/www*/index.html; do
    [ -f "$f" ] || continue
    if grep -q "jk-ui-nav-loader" "$f"; then
      ok "injected in $f"
    else
      warn "loader not present in $f"
    fi
  done

  [ "$rc" = 0 ] && say "All checks passed" || say "$rc check(s) failed"
  return "$rc"
}

cmd_status() {
  echo "jukebox-ui-nav v$(cat "$DEST/VERSION" 2>/dev/null || echo '?')"
  echo "installed    : $([ -d "$DEST" ] && echo "yes ($DEST)" || echo no)"
  echo "service      : $(systemctl is-enabled jukebox-ui-nav.service 2>/dev/null || echo -) / $(systemctl is-active jukebox-ui-nav.service 2>/dev/null || echo -)"
  echo "guard        : $(systemctl is-enabled jukebox-ui-nav-guard.path 2>/dev/null || echo -) / $(systemctl is-active jukebox-ui-nav-guard.path 2>/dev/null || echo -)"
  echo "port         : ${JK_NAV_PORT:-3211}"
  echo "endpoint     : $(curl -sf "http://localhost:${JK_NAV_PORT:-3211}/ui-nav.js" >/dev/null 2>&1 && echo ok || echo DOWN)"
  local f
  for f in /volumio/http/www*/index.html; do
    [ -f "$f" ] || continue
    echo "injected($f): $(grep -q jk-ui-nav-loader "$f" && echo yes || echo no)"
  done
}

main() {
  local mode="install"
  while [ $# -gt 0 ]; do
    case "$1" in
      --port) PORT="$2"; shift 2 ;;
      --port=*) PORT="${1#*=}"; shift ;;
      install|verify|status) mode="$1"; shift ;;
      -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
