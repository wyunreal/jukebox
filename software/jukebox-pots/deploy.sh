#!/usr/bin/env bash
#
# deploy.sh - copy the jukebox-pots installer to a Volumio host and run it there.
#
# The installer must run ON the Volumio host (it installs a systemd unit and a
# udev rule). This wrapper just ships the directory and runs install.sh.
#
# Usage:
#   ./deploy.sh [options] [command]
#
# Options:
#   -H, --host HOST     SSH host (default: volumio@<host>)
#   -p, --password PASS SSH/sudo password (default: $JUKEBOX_PASSWORD, or prompt)
#   -i, --identity FILE SSH private key
#   -n, --dry-run       show what would be done, do not change anything
#   -h, --help          this help
#
# Commands (default: install):
#   install [--dac-card NAME] [--port DEV] [...]   install / re-assert
#   verify                                         run the verification checks
#   status                                         show current state
#   uninstall                                      remove the service
#
# Examples:
#   ./deploy.sh install
#   ./deploy.sh --host volumio@<host> status
#   ./deploy.sh uninstall
#
set -euo pipefail

HOST="volumio@<host>"
SSH_PASS="${JUKEBOX_PASSWORD:-}"
IDENTITY=""
DRY_RUN=0
SCRIPT_NAME="install.sh"
REMOTE_DIR="/tmp/jukebox-pots-deploy"
LOCAL_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES=(install.sh uninstall.sh README.md)
FILES_DIR="files"

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
[ -n "$IDENTITY" ] && SSH_OPTS+=(-i "$IDENTITY")
have_sshpass=0
command -v sshpass >/dev/null 2>&1 && have_sshpass=1

run_ssh() {
  if [ "$have_sshpass" = 1 ] && [ -n "$SSH_PASS" ]; then
    SSHPASS="$SSH_PASS" sshpass -e ssh "${SSH_OPTS[@]}" "$HOST" "$@"
  else
    ssh "${SSH_OPTS[@]}" "$HOST" "$@"
  fi
}

run_scp() {
  if [ "$have_sshpass" = 1 ] && [ -n "$SSH_PASS" ]; then
    SSHPASS="$SSH_PASS" sshpass -e scp "${SSH_OPTS[@]}" "$@"
  else
    scp "${SSH_OPTS[@]}" "$@"
  fi
}

run_ssh_root() {
  local cmd="$1"
  if [ -n "$SSH_PASS" ]; then
    if [ "$have_sshpass" = 1 ]; then
      SSHPASS="$SSH_PASS" sshpass -e ssh "${SSH_OPTS[@]}" "$HOST" \
        "printf '%s\n' '$SSH_PASS' | sudo -S -p '' bash -c $(printf '%q' "$cmd")"
    else
      run_ssh "printf '%s\n' '$SSH_PASS' | sudo -S -p '' bash -c $(printf '%q' "$cmd")"
    fi
  else
    run_ssh "sudo -n true" 2>/dev/null \
      || die "sudo on the host needs a password: pass --password, set JUKEBOX_PASSWORD, or enable passwordless sudo"
    # let the real command's exit status propagate (do not mask it as a sudo error)
    run_ssh "sudo -n bash -c $(printf '%q' "$cmd")"
  fi
}

main() {
  local command="install"
  local remote_args=()

  # deploy.sh's own options are consumed here; everything else is forwarded to
  # install.sh on the host, in order, so options with values keep working.
  while [ $# -gt 0 ]; do
    case "$1" in
      -H|--host) HOST="$2"; shift 2 ;;
      -p|--password) SSH_PASS="$2"; shift 2 ;;
      -i|--identity) IDENTITY="$2"; shift 2 ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) remote_args+=("$1"); shift ;;
    esac
  done
  if [ "${#remote_args[@]}" -gt 0 ]; then
    case "${remote_args[0]}" in
      install|verify|status|uninstall)
        command="${remote_args[0]}"
        remote_args=("${remote_args[@]:1}")
        ;;
      -*) ;;  # no command given, default to install and forward the option
      *) die "unknown command: ${remote_args[0]} (see --help)" ;;
    esac
  fi

  [ -f "$LOCAL_DIR/$SCRIPT_NAME" ] || die "$SCRIPT_NAME not found next to deploy.sh"
  command -v ssh >/dev/null 2>&1 || die "ssh is not installed on this machine"
  if [ "$have_sshpass" = 0 ] && [ -n "$SSH_PASS" ]; then
    echo "note: sshpass not found; will use SSH keys/agent for the connection" >&2
  fi

  say "Target: $HOST"
  say "Checking SSH connectivity"
  run_ssh "echo connected as \$(whoami)@\$(hostname); uname -sr" || die "cannot reach $HOST over SSH"
  ok "connected"

  say "Copying the jukebox-pots package to $HOST:$REMOTE_DIR"
  if [ "$DRY_RUN" = 1 ]; then
    ok "dry-run: skipping copy"
  else
    run_ssh "mkdir -p $REMOTE_DIR/$FILES_DIR"
    local f
    for f in "${FILES[@]}"; do
      [ -f "$LOCAL_DIR/$f" ] && run_scp "$LOCAL_DIR/$f" "$HOST:$REMOTE_DIR/$f"
    done
    if [ -d "$LOCAL_DIR/$FILES_DIR" ]; then
      run_scp "$LOCAL_DIR/$FILES_DIR/"* "$HOST:$REMOTE_DIR/$FILES_DIR/"
    fi
    ok "copied"
  fi

  local runner="$SCRIPT_NAME"
  [ "$command" = "uninstall" ] && runner="uninstall.sh"
  local remote_cmd="bash $REMOTE_DIR/$runner $command"
  [ "$command" = "uninstall" ] && remote_cmd="bash $REMOTE_DIR/$runner"
  if [ "${#remote_args[@]}" -gt 0 ]; then
    local a
    for a in "${remote_args[@]}"; do remote_cmd="$remote_cmd $(printf '%q' "$a")"; done
  fi

  if [ "$command" = "status" ]; then
    say "Running: $command"
    run_ssh "$remote_cmd"
    return
  fi

  say "Running: sudo $remote_cmd"
  if [ "$DRY_RUN" = 1 ]; then
    ok "dry-run: not executing"
    return
  fi
  run_ssh_root "$remote_cmd"
  ok "done"
}

main "$@"
