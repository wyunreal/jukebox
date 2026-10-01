#!/usr/bin/env bash
#
# deploy.sh - copy the jukebox-audio installer to a Volumio host and run it
# there over SSH.
#
# The installer must run ON the Volumio host (it edits systemd units, Volumio
# configuration and ALSA state). This wrapper just ships it and runs it.
#
# Usage:
#   ./deploy.sh [options] [command]
#
# Options:
#   -H, --host HOST     SSH host (default: volumio@volumio.local)
#   -p, --password PASS SSH/sudo password (default: $JUKEBOX_PASSWORD or prompt)
#   -i, --identity FILE SSH private key
#   -n, --dry-run       show what would be done, do not change anything
#   -h, --help          this help
#
# Commands (default: install):
#   install [--second-output usb|hdmi|jack|none] [--with-playback]
#   verify  [--with-playback]   run the verification checks only
#   apply                       re-assert configuration (used by guard units)
#   status                      show current state
#   uninstall                   remove the feature and restore backups
#
# Examples:
#   ./deploy.sh install
#   ./deploy.sh install --second-output usb
#   ./deploy.sh --host volumio@volumio.local verify --with-playback
#   ./deploy.sh uninstall
#
set -euo pipefail

HOST="volumio@volumio.local"
SSH_PASS="${JUKEBOX_PASSWORD:-}"
IDENTITY=""
DRY_RUN=0
SCRIPT_NAME="jukebox-audio.sh"
REMOTE_DIR="/tmp/jukebox-audio-deploy"
LOCAL_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Build the ssh/scp command lines. Password use requires sshpass; otherwise
# fall back to key/agent authentication.
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
if [ -n "$IDENTITY" ]; then
  SSH_OPTS+=(-i "$IDENTITY")
fi
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

# Run a command on the host with root privileges. Volumio's image uses the
# host password for sudo (from --password or JUKEBOX_PASSWORD); it is piped to sudo -S over stdin.
run_ssh_root() {
  local cmd="$1"
  if [ "$have_sshpass" = 1 ] && [ -n "$SSH_PASS" ]; then
    SSHPASS="$SSH_PASS" sshpass -e ssh "${SSH_OPTS[@]}" "$HOST" \
      "printf '%s\n' '$SSH_PASS' | sudo -S -p '' bash -c $(printf '%q' "$cmd")"
  else
    run_ssh "printf '%s\n' '$SSH_PASS' | sudo -S -p '' bash -c $(printf '%q' "$cmd")"
  fi
}

main() {
  local command="install" with_playback="" second_output=""
  local positional=()

  while [ $# -gt 0 ]; do
    case "$1" in
      -H|--host) HOST="$2"; shift 2 ;;
      -p|--password) SSH_PASS="$2"; shift 2 ;;
      -i|--identity) IDENTITY="$2"; shift 2 ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      --with-playback) with_playback="--with-playback"; shift ;;
      --second-output=*) second_output="$1"; shift ;;
      --second-output)
        second_output="$1 $2"; shift 2 ;;
      -*) die "unknown option: $1 (see --help)" ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  [ "${#positional[@]}" -gt 0 ] && command="${positional[0]}"

  case "$command" in
    install|verify|apply|status|uninstall) ;;
    *) die "unknown command: $command (see --help)" ;;
  esac

  [ -f "$LOCAL_DIR/$SCRIPT_NAME" ] || die "$SCRIPT_NAME not found next to deploy.sh"
  command -v ssh >/dev/null 2>&1 || die "ssh is not installed on this machine"
  if [ "$have_sshpass" = 0 ] && [ -n "$SSH_PASS" ]; then
    echo "note: sshpass not found; will use SSH keys/agent for the connection" >&2
  fi

  say "Target: $HOST"
  say "Checking SSH connectivity"
  run_ssh "echo connected as \$(whoami)@\$(hostname); uname -sr" || die "cannot reach $HOST over SSH"
  ok "connected"

  say "Copying $SCRIPT_NAME to $HOST:$REMOTE_DIR"
  if [ "$DRY_RUN" = 1 ]; then
    ok "dry-run: skipping copy"
  else
    run_ssh "mkdir -p $REMOTE_DIR"
    run_scp "$LOCAL_DIR/$SCRIPT_NAME" "$HOST:$REMOTE_DIR/$SCRIPT_NAME"
    run_scp "$LOCAL_DIR/README.md" "$HOST:$REMOTE_DIR/README.md" 2>/dev/null || true
    ok "copied"
  fi

  remote_cmd="$REMOTE_DIR/$SCRIPT_NAME $command"
  [ -n "$second_output" ] && remote_cmd="$remote_cmd $second_output"
  [ -n "$with_playback" ] && remote_cmd="$remote_cmd $with_playback"

  if [ "$command" = "status" ]; then
    say "Running: $command"
    run_ssh "bash $remote_cmd"
    return
  fi

  say "Running: sudo $remote_cmd"
  if [ "$DRY_RUN" = 1 ]; then
    ok "dry-run: not executing"
    return
  fi
  run_ssh_root "bash $remote_cmd"
  ok "done"
}

main "$@"
