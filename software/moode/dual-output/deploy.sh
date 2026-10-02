#!/usr/bin/env bash
#
# deploy.sh - copy the jukebox-moode package to a moOde host and run it there.
#
# The installer must run ON the moOde host (it edits ALSA conf.d files, moOde's
# SQLite database and systemd units). This wrapper just ships the directory
# and runs jukebox-moode.sh over SSH.
#
# Usage:
#   ./deploy.sh [options] [command]
#
# Options:
#   -H, --host HOST     SSH host (default: moode@<host>)
#   -p, --password PASS SSH password (or use SSH keys)
#
# Commands (default: install):
#   install [--second-output usb|none]   install / re-assert
#   verify                               check the live box
#   status                               show current state
#   uninstall                            remove and restore moOde files
#
set -euo pipefail

HOST="${DEPLOY_HOST:-moode@<host>}"
SSH_PASS="${JB_PASSWORD:-}"
REMOTE_DIR="/tmp/jukebox-moode-deploy"
SCRIPT_NAME="jukebox-moode.sh"
LOCAL_DIR="$(cd "$(dirname "$0")" && pwd)"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
[ -n "$SSH_PASS" ] && SSH_OPTS=(-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)

run_ssh() {
  if [ -n "$SSH_PASS" ]; then
    command -v sshpass >/dev/null 2>&1 || { echo "sshpass is required for password auth (or use SSH keys)"; exit 1; }
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

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

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

  say "Copying the jukebox-moode package to $HOST:$REMOTE_DIR"
  run_ssh "$HOST" "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR'"
  run_scp "$LOCAL_DIR/$SCRIPT_NAME" "$LOCAL_DIR/moode-sync.php" "$LOCAL_DIR/README.md" "$HOST:$REMOTE_DIR/" 2>/dev/null || true
  if [ -d "$LOCAL_DIR/cdsp" ]; then
    run_ssh "$HOST" "mkdir -p '$REMOTE_DIR/cdsp'"
    run_scp "$LOCAL_DIR/cdsp/"* "$HOST:$REMOTE_DIR/cdsp/" 2>/dev/null || true
  fi
  ok "copied"

  say "Running: sudo $SCRIPT_NAME $command ${args[*]:-}"
  sudo_cmd "bash '$REMOTE_DIR/$SCRIPT_NAME' $command ${args[*]:-}"
}

main "$@"
