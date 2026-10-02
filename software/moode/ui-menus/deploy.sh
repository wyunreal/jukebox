#!/usr/bin/env bash
#
# deploy.sh - copy the jukebox-menu-font package to a moOde host and run it.
#
# Usage:
#   ./deploy.sh [options] [command]
#
# Options:
#   -H, --host HOST     SSH host (default: moode@jukebox.local)
#   -p, --password PASS SSH password (or use SSH keys)
#
# Commands (default: install):
#   install [--scale N]   install / re-assert (default scale 1.35)
#   verify                check the live stylesheet
#   status                show current state
#   uninstall             restore the pristine stylesheet
#
set -euo pipefail

HOST="${DEPLOY_HOST:-moode@jukebox.local}"
SSH_PASS="${JB_PASSWORD:-}"
REMOTE_DIR="/tmp/jukebox-menu-font-deploy"
SCRIPT_NAME="jukebox-menu-font.sh"
LOCAL_DIR="$(cd "$(dirname "$0")" && pwd)"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
[ -n "$SSH_PASS" ] && SSH_OPTS=(-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)

run_ssh() {
  if [ -n "$SSH_PASS" ]; then
    command -v sshpass >/dev/null 2>&1 || { echo "sshpass is required for password auth"; exit 1; }
    SSHPASS="$SSH_PASS" sshpass -e ssh "${SSH_OPTS[@]}" "$@"
  else
    ssh "${SSH_OPTS[@]}" "$@"
  fi
}

run_scp() {
  if [ -n "$SSH_PASS" ]; then
    SSHPASS="$SSH_PASS" sshpass -e scp "${SSH_OPTS[@]}" "$@"
  else
    scp "${SSH_OPTS[@]}" "$@"
  fi
}

sudo_cmd() {
  if [ -n "$SSH_PASS" ]; then
    printf '%s\n' "$SSH_PASS" | run_ssh "$HOST" "sudo -S -p '' $*"
  else
    run_ssh "$HOST" "sudo -n $*"
  fi
}

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  local command="install" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -H|--host) HOST="$2"; shift 2 ;;
      --host=*) HOST="${1#*=}"; shift ;;
      -p|--password) SSH_PASS="$2"; shift 2 ;;
      --password=*) SSH_PASS="${1#*=}"; shift ;;
      -h|--help) usage; exit 0 ;;
      install|verify|status|uninstall) command="$1"; shift ;;
      -*) args+=("$1"); shift ;;
      *) args+=("$1"); shift ;;
    esac
  done

  say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
  ok()  { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }

  say "Checking SSH connectivity"
  run_ssh "$HOST" 'echo connected' >/dev/null || { echo "Cannot connect to $HOST"; exit 1; }
  ok "connected"

  say "Copying the package to $HOST:$REMOTE_DIR"
  run_ssh "$HOST" "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR'"
  run_scp "$LOCAL_DIR/$SCRIPT_NAME" "$LOCAL_DIR/README.md" "$HOST:$REMOTE_DIR/" 2>/dev/null || true
  ok "copied"

  say "Running: sudo $SCRIPT_NAME $command ${args[*]:-}"
  sudo_cmd "bash '$REMOTE_DIR/$SCRIPT_NAME' $command ${args[*]:-}"
}

main "$@"
