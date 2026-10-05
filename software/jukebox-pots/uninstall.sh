#!/usr/bin/env bash
#
# uninstall.sh - remove the jukebox-pots daemon from the Volumio host.
#
# Run ON the host as root: sudo ./uninstall.sh
set -euo pipefail

APPLY_DIR="/usr/local/jukebox-pots"
UNIT="/etc/systemd/system/jukebox-pots.service"
UDEV_RULE="/etc/udev/rules.d/89-jukebox-pots.rules"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()  { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"

say "Uninstalling jukebox-pots"
systemctl disable --now jukebox-pots.service >/dev/null 2>&1 || true
rm -f "$UNIT" "$UDEV_RULE"
systemctl daemon-reload
udevadm control --reload-rules >/dev/null 2>&1 || true
rm -rf "$APPLY_DIR"
ok "service, unit, udev rule and files removed"
