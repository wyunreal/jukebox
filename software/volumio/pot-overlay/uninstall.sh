#!/usr/bin/env bash
#
# uninstall.sh - remove the jukebox pot overlay from the Volumio host.
#
# Run ON the host as root: sudo ./uninstall.sh
set -euo pipefail

DEST="/usr/local/jukebox-overlay"
UNIT="/etc/systemd/system/jukebox-overlay.service"
GUARD_SERVICE="/etc/systemd/system/jukebox-overlay-guard.service"
GUARD_PATH="/etc/systemd/system/jukebox-overlay-guard.path"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()  { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"

say "Uninstalling jukebox-overlay"
systemctl disable --now jukebox-overlay-guard.path >/dev/null 2>&1 || true
systemctl disable --now jukebox-overlay.service >/dev/null 2>&1 || true
rm -f "$UNIT" "$GUARD_SERVICE" "$GUARD_PATH"
systemctl daemon-reload

# Strip the injected loader from the UI pages (helper shipped with the install).
if [ -x "$DEST/uninject.py" ]; then
  python3 "$DEST/uninject.py" || true
fi

systemctl restart volumio-kiosk.service >/dev/null 2>&1 || true
rm -rf "$DEST"
ok "removed (server, guard, UI loader)"
