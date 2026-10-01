#!/bin/bash
# install.sh - install the jukebox-ui guard on the Volumio host.
# Run ON the host as root, e.g. "sudo bash install.sh".
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST=/usr/local/jukebox-ui
UNITS=/etc/systemd/system

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

echo "==> installing helper to $DEST"
mkdir -p "$DEST"
install -m 0755 "$SRC/jukebox-ui.sh" "$DEST/jukebox-ui.sh"

echo "==> installing systemd units"
install -m 0644 "$SRC/jukebox-ui-guard.service" "$UNITS/jukebox-ui-guard.service"
install -m 0644 "$SRC/jukebox-ui-guard.path" "$UNITS/jukebox-ui-guard.path"

systemctl daemon-reload
systemctl enable --now jukebox-ui-guard.path
systemctl enable jukebox-ui-guard.service

echo "==> applying now"
"$DEST/jukebox-ui.sh" apply || true

echo
echo "==> verify"
"$DEST/jukebox-ui.sh" verify || true

cat <<'EOF'

Installed. To make the kiosk restart take effect from a clean boot, reboot:
    sudo reboot
EOF
