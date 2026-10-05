#!/usr/bin/env bash
#
# uninstall.sh - remove the jukebox-keyboard daemon from the Volumio host.
#
# Run ON the host as root: sudo ./uninstall.sh
set -euo pipefail

APPLY_DIR="/usr/local/jukebox-keyboard"
UNIT="/etc/systemd/system/jukebox-keyboard.service"
UDEV_RULE="/etc/udev/rules.d/89-jukebox-keyboard.rules"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()  { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"

say "Uninstalling jukebox-keyboard"
systemctl disable --now jukebox-keyboard.service >/dev/null 2>&1 || true
rm -f "$UNIT" "$UDEV_RULE"
systemctl daemon-reload
udevadm control --reload-rules >/dev/null 2>&1 || true
rm -rf "$APPLY_DIR"
ok "service, unit, udev rule and files removed"
