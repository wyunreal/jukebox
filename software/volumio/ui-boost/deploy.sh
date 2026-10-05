#!/usr/bin/env bash
#
# deploy.sh - copy the jukebox-ui (touch UI boost) installer to a Volumio host
# and run it there over SSH.
#
# Usage:
#   ./deploy.sh [options] [command]
#
# Options:
#   -H, --host HOST     SSH host (default: volumio@<host>)
#   -p, --password PASS SSH/sudo password (default: $JUKEBOX_PASSWORD)
#   -i, --identity FILE SSH private key
#   -n, --dry-run       show what would be done, do not change anything
#   -h, --help          this help
#
# Commands (default: install):
#   install    install / re-assert the touch UI boost + guard
#   verify     run the helper's verify
#   status     show the helper's status
#
# Examples:
#   ./deploy.sh --host volumio@<host> install
#   ./deploy.sh status
#
# The install takes effect from a clean boot (the kiosk is restarted); reboot
# the host afterwards if you want the change to apply immediately.
#
set -euo pipefail

HOST="volumio@<host>"
SSH_PASS="${JUKEBOX_PASSWORD:-}"
IDENTITY=""
DRY_RUN=0
REMOTE_DIR="/tmp/jukebox-ui-deploy"
LOCAL_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES=(install.sh jukebox-ui.sh jukebox-ui-guard.service jukebox-ui-guard.path)

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; }

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
    run_ssh "printf '%s\n' '$SSH_PASS' | sudo -S -p '' bash -c $(printf '%q' "$cmd")"
  else
    run_ssh "sudo -n true" 2>/dev/null \
      || die "sudo on the host needs a password: pass --password, set JUKEBOX_PASSWORD, or enable passwordless sudo"
    run_ssh "sudo -n bash -c $(printf '%q' "$cmd")"
  fi
}

main() {
  local command="install"
  local positional=()

  while [ $# -gt 0 ]; do
    case "$1" in
      -H|--host) HOST="$2"; shift 2 ;;
      -p|--password) SSH_PASS="$2"; shift 2 ;;
      -i|--identity) IDENTITY="$2"; shift 2 ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) die "unknown option: $1 (see --help)" ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  [ "${#positional[@]}" -gt 0 ] && command="${positional[0]}"

  case "$command" in
    install|verify|status) ;;
    *) die "unknown command: $command (see --help)" ;;
  esac

  command -v ssh >/dev/null 2>&1 || die "ssh is not installed on this machine"

  say "Target: $HOST"
  say "Checking SSH connectivity"
  run_ssh "echo connected as \$(whoami)@\$(hostname); uname -sr" || die "cannot reach $HOST over SSH"
  ok "connected"

  if [ "$command" = "status" ] || [ "$command" = "verify" ]; then
    say "Running: $command"
    run_ssh_root "/usr/local/jukebox-ui/jukebox-ui.sh $command" \
      || die "jukebox-ui is not installed on the host (run: ./deploy.sh install)"
    return
  fi

  say "Copying the jukebox-ui package to $HOST:$REMOTE_DIR"
  if [ "$DRY_RUN" = 1 ]; then
    ok "dry-run: skipping copy"
  else
    run_ssh "mkdir -p $REMOTE_DIR"
    local f
    for f in "${FILES[@]}"; do
      [ -f "$LOCAL_DIR/$f" ] && run_scp "$LOCAL_DIR/$f" "$HOST:$REMOTE_DIR/$f"
    done
    ok "copied"
  fi

  say "Running: sudo bash install.sh $command"
  if [ "$DRY_RUN" = 1 ]; then
    ok "dry-run: not executing"
    return
  fi
  run_ssh_root "bash $REMOTE_DIR/install.sh"
  ok "done"
}

main "$@"
