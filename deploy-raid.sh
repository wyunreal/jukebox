#!/usr/bin/env bash
#
# deploy-raid.sh - set up (or adopt) the RAID 1 music library on the Volumio
#                 host. This is the STORAGE counterpart of deploy-all.sh: the
#                 box is assembled from two top-level installers, side by side:
#
#                   ./deploy-all.sh   -> every software package (audio, UI, pots,
#                                        overlay, nav, keyboard)
#                   ./deploy-raid.sh  -> the RAID 1 music library (this file)
#
# It just ships software/storage/raid-music.sh to the host and runs it as root.
# That script is idempotent and safe: an existing array is only ADOPTED (never
# reformatted); with no array it uses two empty whole disks and REFUSES a disk
# that already has data unless --reformat is passed.
#
# Usage:
#   ./deploy-raid.sh [options] [command]
#
# Commands (default: install):
#   install      create (or adopt) the mirror, fix the boot config and mount it
#   apply        re-assert the config + mount (idempotent; used after an update)
#   verify       pass/fail checks
#   status       human overview (array, mount, disks, SMART)
#   uninstall    remove the config, keep the data (--wipe destroys the array)
#
# Options:
#   -H, --host HOST       SSH host, user@host (or set JUKEBOX_HOST); required
#   -p, --password PASS   SSH/sudo password (default: $JUKEBOX_PASSWORD)
#   -i, --identity FILE   SSH private key
#   -n, --dry-run         show what would be done, do not change anything
#   -h, --help            this help
#
# Any raid-music.sh option is forwarded verbatim:
#   --disk-a /dev/sdX --disk-b /dev/sdY   pick the two disks (default: the two
#                                         empty whole disks found automatically)
#   --name N --label L --mount DIR        array name / ext4 label / mount point
#   --reformat                            allow wiping a disk that has data
#   --resync                              force a full initial resync
#   --no-quirk                            don't touch /boot/cmdline.txt
#   --wipe                                (uninstall) destroy the array + data
#
# Examples:
#   ./deploy-raid.sh -H user@host install
#   ./deploy-raid.sh -H user@host -p <password> install --disk-a /dev/sda --disk-b /dev/sdb
#   ./deploy-raid.sh -H user@host status
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_DIR="$REPO_DIR/software/storage"
SCRIPT_NAME="raid-music.sh"
REMOTE_DIR="/tmp/jukebox-raid-deploy"

HOST="${JUKEBOX_HOST:-}"
SSH_PASS="${JUKEBOX_PASSWORD:-}"
DRY_RUN=0
command="install"

usage() { sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; }
say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Build the ssh/scp command lines. Password use requires sshpass; otherwise fall
# back to key/agent authentication.
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
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

# Run a command on the host with root privileges (raid-music.sh needs root for
# mdadm / mount / fstab). With a password: piped to sudo -S over stdin.
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
    run_ssh "sudo -n bash -c $(printf '%q' "$cmd")" \
      || die "sudo on the host needs a password: pass --password, set JUKEBOX_PASSWORD, or enable passwordless sudo"
  fi
}

main() {
  local -a raid_args=()

  while [ $# -gt 0 ]; do
    case "$1" in
      -H|--host) HOST="$2"; shift 2 ;;
      -p|--password) SSH_PASS="$2"; shift 2 ;;
      -i|--identity) SSH_OPTS+=(-i "$2"); shift 2 ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      # options with a separate value
      --disk-a|--disk-b|--name|--label|--mount)
        [ $# -ge 2 ] || die "$1 needs a value"
        raid_args+=("$1" "$2"); shift 2 ;;
      # options with an inline value, and value-less flags
      --disk-a=*|--disk-b=*|--name=*|--label=*|--mount=*|--reformat|--resync|--no-quirk|--wipe)
        raid_args+=("$1"); shift ;;
      -*) die "unknown option: $1 (see --help)" ;;
      *) command="$1"; shift ;;
    esac
  done

  case "$command" in
    install|apply|verify|status|uninstall) ;;
    *) die "unknown command: $command (see --help)" ;;
  esac

  [ -n "$HOST" ] || die "no host given: use -H/--host user@host (or set JUKEBOX_HOST)"
  [ -f "$LOCAL_DIR/$SCRIPT_NAME" ] || die "$SCRIPT_NAME not found in $LOCAL_DIR"
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
    run_ssh "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR"
    run_scp "$LOCAL_DIR/$SCRIPT_NAME" "$HOST:$REMOTE_DIR/$SCRIPT_NAME"
    ok "copied"
  fi

  local remote_cmd="$REMOTE_DIR/$SCRIPT_NAME $command"
  local a
  for a in "${raid_args[@]}"; do remote_cmd="$remote_cmd $(printf '%q' "$a")"; done

  say "Running: sudo $remote_cmd"
  if [ "$DRY_RUN" = 1 ]; then
    ok "dry-run: not executing"
    return
  fi
  run_ssh_root "bash $remote_cmd"
  ok "done"
}

main "$@"
