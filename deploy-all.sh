#!/usr/bin/env bash
#
# deploy-all.sh - drive every jukebox software package on the Volumio host
#                 (install / uninstall / verify / status) in dependency order.
#
# Each package keeps its own deploy.sh; this wrapper only sequences them so you
# don't have to run six commands by hand. It runs from a development machine and
# drives the Pi over SSH.
#
# Usage:
#   ./deploy-all.sh [options] [command]
#
# Commands (default: install):
#   install      install / re-assert every package (second output: usb)
#   uninstall    remove every package (reverse order)
#   verify       run each package's verification
#   status       show each package's status
#
# Options:
#   -H, --host HOST       SSH host, user@host (or set JUKEBOX_HOST); required
#   -p, --password PASS   SSH/sudo password (default: $JUKEBOX_PASSWORD)
#   -h, --help            this help
#
# Examples (host is required: -H/--host or $JUKEBOX_HOST):
#   ./deploy-all.sh -H user@host install
#   ./deploy-all.sh -H user@host status
#   ./deploy-all.sh -H user@host -p <password> install
#   JUKEBOX_HOST=user@host ./deploy-all.sh verify
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# Dependency order: player/audio chain first, then the accessories.
PACKAGES=(
  software/volumio/dual-output
  software/volumio/ui-boost
  software/jukebox-pots
  software/volumio/pot-overlay
  software/volumio/ui-nav
  software/jukebox-keyboard
)

HOST="${JUKEBOX_HOST:-}"
SSH_PASS="${JUKEBOX_PASSWORD:-}"
command="install"

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; }
say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -H|--host) HOST="$2"; shift 2 ;;
    -p|--password) SSH_PASS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    install|uninstall|verify|status) command="$1"; shift ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[ -n "$HOST" ] || die "no host given: use -H/--host user@host (or set JUKEBOX_HOST)"

common=(-H "$HOST")
[ -n "$SSH_PASS" ] && common+=(-p "$SSH_PASS")

# Order to run: as listed for install/verify/status, reversed for uninstall.
order=("${PACKAGES[@]}")
if [ "$command" = uninstall ]; then
  order=()
  for ((i = ${#PACKAGES[@]} - 1; i >= 0; i--)); do order+=("${PACKAGES[$i]}"); done
fi

for pkg in "${order[@]}"; do
  [ -f "$REPO_DIR/$pkg/deploy.sh" ] || die "missing $pkg/deploy.sh"

  extras=()
  # This jukebox's second output is the USB sound card.
  [ "$pkg" = software/volumio/dual-output ] && [ "$command" = install ] \
    && extras=(--second-output usb)

  say "$command: $pkg"
  "$REPO_DIR/$pkg/deploy.sh" "${common[@]}" "$command" "${extras[@]}" \
    || die "$command did not complete for $pkg"
  ok "$pkg: $command done"
done

say "All packages: $command complete"
