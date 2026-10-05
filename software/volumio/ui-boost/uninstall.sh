#!/bin/bash
# uninstall.sh - remove the jukebox-ui guard and helper from the Volumio host.
#
# Run ON the host as root: sudo ./uninstall.sh
set -euo pipefail

DEST=/usr/local/jukebox-ui
UNITS=/etc/systemd/system

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()  { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"

say "Uninstalling jukebox-ui"
systemctl disable --now jukebox-ui-guard.path >/dev/null 2>&1 || true
systemctl disable --now jukebox-ui-guard.service >/dev/null 2>&1 || true
rm -f "$UNITS/jukebox-ui-guard.path" "$UNITS/jukebox-ui-guard.service"
systemctl daemon-reload
rm -rf "$DEST"
ok "guard, unit and helper removed"
