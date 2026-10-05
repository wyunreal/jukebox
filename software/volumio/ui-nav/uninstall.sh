#!/usr/bin/env bash
#
# uninstall.sh - remove the jukebox UI command channel from the Volumio host.
#
# Run ON the host as root: sudo ./uninstall.sh
set -euo pipefail

DEST="/usr/local/jukebox-ui-nav"
UNIT="/etc/systemd/system/jukebox-ui-nav.service"
GUARD_SERVICE="/etc/systemd/system/jukebox-ui-nav-guard.service"
GUARD_PATH="/etc/systemd/system/jukebox-ui-nav-guard.path"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()  { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"

say "Uninstalling jukebox-ui-nav"
systemctl disable --now jukebox-ui-nav-guard.path >/dev/null 2>&1 || true
systemctl disable --now jukebox-ui-nav.service >/dev/null 2>&1 || true
rm -f "$UNIT" "$GUARD_SERVICE" "$GUARD_PATH"
systemctl daemon-reload

# Strip the injected loader from the UI pages (helper shipped with the install).
if [ -x "$DEST/uninject.py" ]; then
  python3 "$DEST/uninject.py" || true
fi

systemctl restart volumio-kiosk.service >/dev/null 2>&1 || true
rm -rf "$DEST"
ok "removed (server, guard, UI loader)"
