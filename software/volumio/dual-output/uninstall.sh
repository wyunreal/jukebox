#!/usr/bin/env bash
#
# uninstall.sh - remove the jukebox dual-output feature from the Volumio host.
#
# Thin wrapper so the package keeps the usual layout (scripts in the root, the
# engine + everything that lands on the host under files/). It just delegates to
# the engine's own `uninstall` mode.
#
# Run ON the host as root: sudo ./uninstall.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

exec "$HERE/files/jukebox-audio.sh" uninstall "$@"
