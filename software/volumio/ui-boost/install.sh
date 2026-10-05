#!/bin/bash
# install.sh - install the jukebox-ui guard on the Volumio host.
# Run ON the host as root, e.g. "sudo bash install.sh".
#
# Installs the jukebox-ui helper plus the systemd guard that re-applies it
# whenever Volumio rewrites the touch-UI files. Idempotent.
#
# Everything that lands on the host lives in files/ (readable, human) and is
# copied verbatim from there; this script only orchestrates.
#
# Undo with ./uninstall.sh (or deploy.sh uninstall).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"
DEST=/usr/local/jukebox-ui
UNITS=/etc/systemd/system

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
[ -f "$FILES_DIR/jukebox-ui.sh" ] || { echo "files/ not found next to install.sh" >&2; exit 1; }

echo "==> installing helper to $DEST"
mkdir -p "$DEST"
install -m 0755 "$FILES_DIR/jukebox-ui.sh" "$DEST/jukebox-ui.sh"

echo "==> installing systemd units"
install -m 0644 "$FILES_DIR/jukebox-ui-guard.service" "$UNITS/jukebox-ui-guard.service"
install -m 0644 "$FILES_DIR/jukebox-ui-guard.path" "$UNITS/jukebox-ui-guard.path"

systemctl daemon-reload
systemctl enable --now jukebox-ui-guard.path
systemctl enable jukebox-ui-guard.service

echo "==> applying now"
"$DEST/jukebox-ui.sh" apply || true

echo
echo "==> verify"
"$DEST/jukebox-ui.sh" verify || true

cat <<EOF

Installed. To make the kiosk restart take effect from a clean boot, reboot:
    sudo reboot

    * Status : sudo $DEST/jukebox-ui.sh status
    * Revert : sudo ./uninstall.sh
EOF
