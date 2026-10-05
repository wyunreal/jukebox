#!/usr/bin/env bash
#
# install.sh - install the jukebox pot overlay on a Volumio host.
#
# Shows a circular indicator (like Volumio's own volume scrim) when the
# balance, bass or treble pot moves.  A small local HTTP/SSE server serves the
# overlay and receives pot changes from the jukebox-pots daemon; a loader is
# injected into the Volumio UI pages, with a guard that re-injects it after
# Volumio rewrites them.
#
# Run ON the Volumio host as root:
#   sudo ./install.sh            # install / re-assert
#   sudo ./install.sh status
#   sudo ./install.sh verify
#   sudo ./install.sh uninstall
#
# Options:
#   --port N     overlay server port (default: 3210)
#
# From a development machine use deploy.sh, which copies this directory over
# SSH and runs this script remotely.
#
set -euo pipefail

VERSION="1.4.0"

DEST="/usr/local/jukebox-overlay"
CONFIG_ENV="$DEST/config.env"
UNIT="/etc/systemd/system/jukebox-overlay.service"
GUARD_SERVICE="/etc/systemd/system/jukebox-overlay-guard.service"
GUARD_PATH="/etc/systemd/system/jukebox-overlay-guard.path"

PORT="3210"

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*"; }
fail() { printf '    \033[1;31mFAIL\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

install_files() {
  mkdir -p "$DEST"
  install -m 0755 "$SCRIPT_DIR/jukebox-overlay.py" "$DEST/jukebox-overlay.py"
  install -m 0755 "$SCRIPT_DIR/apply.sh" "$DEST/apply.sh"
  install -m 0644 "$SCRIPT_DIR/overlay.js" "$DEST/overlay.js"
  install -m 0644 "$SCRIPT_DIR/overlay.css" "$DEST/overlay.css"
  echo "$VERSION" >"$DEST/VERSION"
  cat >"$CONFIG_ENV" <<EOF
# jukebox-overlay settings (edited by install.sh; read by the service)
JK_OVERLAY_PORT=$PORT
JK_OVERLAY_ROOT=$DEST
EOF
}

install_units() {
  install -m 0644 "$SCRIPT_DIR/jukebox-overlay.service" "$UNIT"
  cat >"$GUARD_PATH" <<EOF
[Unit]
Description=Watch Volumio UI pages (re-inject the jukebox pot overlay)

[Path]
PathChanged=/volumio/http/www/index.html
PathChanged=/volumio/http/www3/index.html
PathChanged=/volumio/http/www4/index.html

[Install]
WantedBy=multi-user.target
EOF
  cat >"$GUARD_SERVICE" <<EOF
[Unit]
Description=Re-inject the jukebox pot overlay into the Volumio UI

[Service]
Type=oneshot
ExecStart=$DEST/apply.sh
EOF
  systemctl daemon-reload
}

cmd_install() {
  require_root
  say "Installing jukebox-overlay (v$VERSION)"
  echo "    port         : $PORT"

  install_files
  ok "server + assets written to $DEST"

  say "Installing services"
  install_units
  systemctl enable jukebox-overlay.service >/dev/null 2>&1 || true
  systemctl restart jukebox-overlay.service
  systemctl enable jukebox-overlay-guard.path >/dev/null 2>&1 || true
  systemctl enable jukebox-overlay-guard.service >/dev/null 2>&1 || true
  systemctl restart jukebox-overlay-guard.path >/dev/null 2>&1 || true
  sleep 1
  systemctl is-active --quiet jukebox-overlay.service \
    && ok "overlay server running" \
    || fail "overlay server failed to start"

  say "Injecting into the Volumio UI pages"
  "$DEST/apply.sh" || true

  # Reload the kiosk so the injected loader is picked up right away.
  systemctl restart volumio-kiosk.service >/dev/null 2>&1 || true

  cmd_verify || true

  say "Done"
  cat <<EOF
    The overlay shows whenever the balance/bass/treble pot moves. It needs the
    jukebox-pots daemon to POST changes (install/update it too).

    * Server logs : journalctl -u jukebox-overlay -f
    * Test        : curl -s localhost:$PORT/overlay.js | head
    * Revert      : sudo $0 uninstall
EOF
}

cmd_verify() {
  require_root
  local rc=0
  say "Verification"

  [ -x "$DEST/jukebox-overlay.py" ] && ok "server installed" || { fail "server missing"; rc=$((rc+1)); }
  systemctl is-enabled --quiet jukebox-overlay.service && ok "service enabled at boot" || { fail "service not enabled"; rc=$((rc+1)); }
  systemctl is-active --quiet jukebox-overlay.service && ok "service running" || { fail "service not running"; rc=$((rc+1)); }
  systemctl is-enabled --quiet jukebox-overlay-guard.path && ok "guard enabled" || { fail "guard not enabled"; rc=$((rc+1)); }

  if curl -sf "http://localhost:$PORT/overlay.js" >/dev/null 2>&1; then
    ok "overlay endpoint reachable (http://localhost:$PORT/overlay.js)"
  else
    fail "overlay endpoint not reachable on port $PORT"; rc=$((rc+1))
  fi

  local f injected=0
  for f in /volumio/http/www*/index.html; do
    [ -f "$f" ] || continue
    if grep -q "jk-overlay-loader" "$f"; then
      ok "injected in $f"; injected=1
    else
      warn "loader not present in $f"
    fi
  done

  [ "$rc" = 0 ] && say "All checks passed" || say "$rc check(s) failed"
  return "$rc"
}

cmd_status() {
  echo "jukebox-overlay v$(cat "$DEST/VERSION" 2>/dev/null || echo '?')"
  echo "installed    : $([ -d "$DEST" ] && echo "yes ($DEST)" || echo no)"
  echo "service      : $(systemctl is-enabled jukebox-overlay.service 2>/dev/null || echo -) / $(systemctl is-active jukebox-overlay.service 2>/dev/null || echo -)"
  echo "guard        : $(systemctl is-enabled jukebox-overlay-guard.path 2>/dev/null || echo -) / $(systemctl is-active jukebox-overlay-guard.path 2>/dev/null || echo -)"
  echo "port         : ${JK_OVERLAY_PORT:-3210}"
  echo "endpoint     : $(curl -sf "http://localhost:${JK_OVERLAY_PORT:-3210}/overlay.js" >/dev/null 2>&1 && echo ok || echo DOWN)"
  local f
  for f in /volumio/http/www*/index.html; do
    [ -f "$f" ] || continue
    echo "injected($f): $(grep -q jk-overlay-loader "$f" && echo yes || echo no)"
  done
}

cmd_uninstall() {
  require_root
  say "Uninstalling jukebox-overlay"
  systemctl disable --now jukebox-overlay-guard.path >/dev/null 2>&1 || true
  systemctl disable --now jukebox-overlay.service >/dev/null 2>&1 || true
  rm -f "$UNIT" "$GUARD_SERVICE" "$GUARD_PATH"
  systemctl daemon-reload

  # Strip the injected loader from the UI pages.
  python3 - <<'PY'
import glob
import re
pat = re.compile(r'<script id="jk-overlay-loader">.*?</script>')
for f in glob.glob("/volumio/http/www*/index.html"):
    try:
        s = open(f, encoding="utf-8").read()
    except OSError:
        continue
    n = pat.sub("", s)
    if n != s:
        open(f, "w", encoding="utf-8").write(n)
        print("cleaned " + f)
PY

  systemctl restart volumio-kiosk.service >/dev/null 2>&1 || true
  rm -rf "$DEST"
  ok "removed (server, guard, UI loader)"
}

main() {
  local mode="install"
  while [ $# -gt 0 ]; do
    case "$1" in
      --port) PORT="$2"; shift 2 ;;
      --port=*) PORT="${1#*=}"; shift ;;
      install|verify|status|uninstall) mode="$1"; shift ;;
      -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
