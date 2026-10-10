#!/usr/bin/env bash
#
# raid-music.sh - set up (or adopt) a RAID 1 mirrored music library for the
#                 jukebox, and mount it where Volumio expects removable storage.
#
# Run ON the Volumio host, as root:
#
#   sudo ./raid-music.sh install [--disk-a /dev/sdX --disk-b /dev/sdY]
#                                [--name music] [--label MUSIC] [--mount /media]
#                                [--reformat] [--resync] [--no-quirk]
#   sudo ./raid-music.sh apply       # re-assert config + mount (idempotent)
#   sudo ./raid-music.sh verify      # pass/fail checks
#   sudo ./raid-music.sh status      # human overview
#   sudo ./raid-music.sh uninstall [--wipe]   # --wipe destroys the array
#
# Idempotent and safe by design:
#   * If the array already exists it is ADOPTED: only mdadm.conf / fstab / the
#     mount are re-asserted. Existing data is never touched.
#   * Otherwise two empty whole disks are used to create the array. A disk that
#     already has a partition table or a filesystem is REFUSED, unless you pass
#     --reformat (which wipes it).
#
# Why a mirror here: two 3.5" SATA disks in USB enclosures. Note that the USB
# link, not the disks, is usually the fragile part (see README): these JMicron
# JMS583 bridges are unreliable with the UAS driver, so `install` also pins the
# `usb-storage.quirks=152d:0583:u` kernel option to force Bulk-Only Transport.
# The disks must have their own power supply: two 3.5" drives cannot run off
# the bus, and a mirror writes to both at once.
#
set -euo pipefail

MD_NAME="music"          # -> array name "<host>:music", /dev/md/music
LABEL="MUSIC"            # ext4 label
MNT="/media"             # /mnt/USB -> /media (Volumio's "USB" library root)
QUIRK="usb-storage.quirks=152d:0583:u"
QUIRK_VIDPID="152d:0583" # JMicron JMS583 USB-SATA bridge
MDADM_CONF=/etc/mdadm/mdadm.conf
FSTAB=/etc/fstab
CMDLINE=/boot/cmdline.txt
MODULES=/etc/modules-load.d/raid.conf

DISK_A=""; DISK_B=""
REFORMAT=0; RESYNC=0; USE_QUIRK=1; WIPE=0

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()  { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
warn(){ printf '    \033[1;33m!!\033[0m   %s\n' "$*" >&2; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

ensure_mdadm() {
  command -v mdadm >/dev/null 2>&1 && return 0
  say "mdadm not found: installing"
  local tmp; tmp="$(mktemp -d)"
  ( cd "$tmp" && apt-get download mdadm >/dev/null 2>&1 ) \
    || die "could not download mdadm (no network?)"
  DEBIAN_FRONTEND=noninteractive dpkg -i "$tmp"/mdadm_*.deb >/dev/null \
    || die "could not install mdadm"
  rm -rf "$tmp"
  command -v mdadm >/dev/null 2>&1 || die "mdadm still missing"
  ok "mdadm installed"
}

# Print the device node of our array if it is assembled, else nothing.
find_array() {
  local dev
  dev="$(mdadm --detail --scan 2>/dev/null | awk -v n=":$MD_NAME" '
    { for (i=1;i<=NF;i++) if ($i ~ /^name=/ && index($i, n)) { print $2; exit } }')"
  if [ -n "$dev" ] && [ -b "$dev" ]; then echo "$dev"; return; fi
  # fall back: any /dev/md* whose members' homehost is us and name matches
  for m in /dev/md/*; do
    [ -b "$m" ] || continue
    mdadm --detail "$m" 2>/dev/null | grep -q "name=.*:$MD_NAME" && { readlink -f "$m"; return; }
  done
  return 0
}

# Devices that are whole disks, not the boot medium, with no partitions and no
# filesystem signature.
find_candidates() {
  local name
  for name in $(lsblk -dpno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
    case "$name" in /dev/mmcblk*|/dev/loop*|/dev/zram*) continue ;; esac
    # no partitions (only the device itself) ...
    [ -z "$(lsblk -nro NAME "$name" 2>/dev/null | tail -n +2)" ] || continue
    # ... and no filesystem/raid-member signature
    [ -z "$(blkid -o value -s TYPE "$name" 2>/dev/null)" ] || continue
    echo "$name"
  done
}

# True if the device carries a partition table or a filesystem.
disk_has_data() {
  local d="$1"
  [ -n "$(lsblk -nro NAME "$d" 2>/dev/null | tail -n +2)" ] && return 0
  [ -n "$(blkid -o value -s TYPE "$d" 2>/dev/null)" ] && return 0
  # partition table without partitions (e.g. an old/wiped MBR)
  if sfdisk -d "$d" 2>/dev/null | grep -q '^/dev'; then return 0; fi
  return 1
}

ensure_mdadm_conf() {
  mkdir -p "$(dirname "$MDADM_CONF")"
  [ -f "$MDADM_CONF.bak" ] || { cp -n "$MDADM_CONF" "$MDADM_CONF.bak" 2>/dev/null || true; }
  # drop our previous entries, then re-add from the live array
  sed -i "/name=.*:$MD_NAME/d; \#^ARRAY /dev/md0 #d" "$MDADM_CONF" 2>/dev/null || true
  mdadm --detail --scan 2>/dev/null | grep "name=.*:$MD_NAME" >> "$MDADM_CONF" || true
}

ensure_fstab() {
  local uuid="$1"
  sed -i "\%^UUID=.*[[:space:]]$MNT[[:space:]]%d; \%^# RAID1 jukebox%d" "$FSTAB"
  {
    echo "# RAID1 jukebox (${MD_NAME}) - music library"
    echo "UUID=$uuid  $MNT  ext4  defaults,nofail,noatime,x-systemd.device-timeout=30  0  2"
  } >> "$FSTAB"
  systemctl daemon-reload 2>/dev/null || true
}

ensure_modules() {
  printf 'raid1\nmd_mod\n' > "$MODULES"
}

ensure_quirk() {
  [ "$USE_QUIRK" = 1 ] || { warn "skipping the UAS quirk (--no-quirk)"; return 0; }
  lsusb 2>/dev/null | grep -qi "$QUIRK_VIDPID" || return 0
  grep -q "$QUIRK" "$CMDLINE" 2>/dev/null && { ok "usb-storage quirk already present"; return 0; }
  [ -f "$CMDLINE.bak-uas" ] || cp "$CMDLINE" "$CMDLINE.bak-uas"
  sed -i "s|\$| $QUIRK|" "$CMDLINE"
  sync
  NEED_REBOOT_QUIRK=1
  warn "added '$QUIRK' to $CMDLINE (reboot needed for it to take effect)"
}

mount_library() {
  mkdir -p "$MNT"
  if ! mountpoint -q "$MNT"; then
    mount "$MNT" || die "could not mount $MNT"
  fi
  chown volumio:volumio "$MNT" 2>/dev/null || true
  mkdir -p "$MNT/Music"
  chown volumio:volumio "$MNT/Music" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

cmd_install() {
  NEED_REBOOT_QUIRK=0
  ensure_mdadm
  ensure_quirk

  local md; md="$(find_array)"
  if [ -n "$md" ]; then
    say "Existing array found at $md: adopting (no data touched)"
  else
    say "Creating a new RAID 1 array"
    local d1="$DISK_A" d2="$DISK_B"
    if [ -z "$d1" ] || [ -z "$d2" ]; then
      mapfile -t cands < <(find_candidates)
      [ "${#cands[@]}" -eq 2 ] || die "expected exactly 2 empty disks to build the mirror, found ${#cands[@]}: ${cands[*]:-none}.
    Pass them explicitly: --disk-a /dev/sdX --disk-b /dev/sdY (or --reformat to wipe non-empty disks)."
      d1="${cands[0]}"; d2="${cands[1]}"
    fi
    [ -b "$d1" ] && [ -b "$d2" ] || die "disk not found ($d1 / $d2)"
    [ "$d1" != "$d2" ] || die "both disks are the same device"
    local d
    for d in "$d1" "$d2"; do
      if disk_has_data "$d"; then
        [ "$REFORMAT" = 1 ] || die "$d already has data (partitions/filesystem). Refusing. Use --reformat to wipe it."
        warn "--reformat: wiping $d"
        wipefs -a "$d"
      fi
      mdadm --zero-superblock "$d" 2>/dev/null || true
      wipefs -a "$d" >/dev/null 2>&1 || true
    done
    local create=(mdadm --create /dev/md0 --level=1 --raid-devices=2
                  --name="$MD_NAME" --homehost="$(hostname)" --force --run)
    # --assume-clean avoids a multi-hour initial resync; the disks are blank
    # (or wiped) and mkfs writes the whole mirror below. Use --resync, or
    # --reformat (which can leave differing stale blocks), for a full rebuild.
    [ "$RESYNC" = 1 ] || [ "$REFORMAT" = 1 ] || create+=(--assume-clean)
    "${create[@]}" "$d1" "$d2" || die "mdadm --create failed"
    md="$(find_array)"; [ -n "$md" ] || md=/dev/md0
  fi

  say "Filesystem"
  if ! blkid -o value -s TYPE "$md" >/dev/null 2>&1; then
    mkfs.ext4 -F -L "$LABEL" -m 0 "$md"
  else
    ok "$md already has a filesystem ($(blkid -o value -s TYPE "$md")): left as is"
  fi
  local uuid; uuid="$(blkid -s UUID -o value "$md")"
  [ -n "$uuid" ] || die "could not read the filesystem UUID of $md"

  ensure_mdadm_conf
  ensure_fstab "$uuid"
  ensure_modules
  mount_library

  if [ "$RESYNC" = 1 ]; then
    say "Starting a full initial resync"
    echo resync > "/sys/block/$(basename "$(readlink -f "$md")")/md/sync_action" 2>/dev/null \
      || warn "could not trigger resync; check /proc/mdstat"
  fi

  cmd_status
  echo
  if [ "$NEED_REBOOT_QUIRK" = 1 ]; then
    warn "Reboot once so the USB quirk takes effect."
  fi
  ok "done. Put music in $MNT/Music (SMB share 'USB')."
}

cmd_apply() { USE_QUIRK="${USE_QUIRK:-1}"; NEED_REBOOT_QUIRK=0; run_assert; }
run_assert() {
  ensure_mdadm
  ensure_quirk
  local md; md="$(find_array)"
  if [ -z "$md" ]; then
    # not assembled: try to assemble from mdadm.conf, else report
    mdadm --assemble --scan >/dev/null 2>&1 || true
    md="$(find_array)"
  fi
  [ -n "$md" ] || die "array '$MD_NAME' not assembled (are both disks plugged and powered?)"
  local uuid; uuid="$(blkid -s UUID -o value "$md")"
  ensure_mdadm_conf
  ensure_fstab "$uuid"
  ensure_modules
  mount_library
  ok "config re-asserted and mounted"
}

cmd_verify() {
  local rc=0
  chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else warn "FAIL: $1"; rc=1; fi; }

  local md; md="$(find_array)"
  chk "array assembled"                 "[ -n '$md' ]"
  chk "array healthy ([2/2] or [UU])"    "grep -qE '\[2/2\]|\[UU\]' /proc/mdstat"
  chk "mounted at $MNT"                 "mountpoint -q '$MNT'"
  chk "ARRAY line in $MDADM_CONF"       "grep -q 'name=.*:$MD_NAME' $MDADM_CONF"
  chk "fstab entry for $MNT"            "grep -q \"[[:space:]]$MNT[[:space:]]\" $FSTAB"
  chk "writable by volumio"             "sudo -u volumio test -w $MNT"
  if [ "$USE_QUIRK" = 1 ] && lsusb 2>/dev/null | grep -qi "$QUIRK_VIDPID"; then
    chk "UAS quirk in $CMDLINE"         "grep -q '$QUIRK' $CMDLINE"
  fi
  echo
  [ "$rc" = 0 ] && ok "verify: all good" || warn "verify: some checks failed"
  return "$rc"
}

cmd_status() {
  say "array"
  grep -E "md[0-9]|raid1|\[" /proc/mdstat 2>/dev/null || echo "  (no array)"
  local md; md="$(find_array)"
  [ -n "$md" ] && mdadm --detail "$md" 2>/dev/null | grep -E 'State|Level|Raid Devices|Name|/dev/sd' | sed 's/^/  /'
  say "mount"
  findmnt "$MNT" 2>/dev/null || echo "  not mounted"
  say "disks"
  lsblk -o NAME,SIZE,TYPE,TRAN,FSTYPE,MOUNTPOINT 2>/dev/null | grep -E 'NAME|sd|md'
  if command -v smartctl >/dev/null 2>&1; then
    say "SMART"
    local d
    for d in $(lsblk -dpno NAME 2>/dev/null | grep -E '^/dev/sd'); do
      printf '  %s: %s\n' "$d" "$(smartctl -H -d sat "$d" 2>/dev/null | grep -i 'overall-health' | sed 's/.*: //')"
    done
  fi
}

cmd_uninstall() {
  local md; md="$(find_array)"
  say "Removing RAID configuration (data is preserved)"
  umount "$MNT" 2>/dev/null || true
  sed -i "\%^UUID=.*[[:space:]]$MNT[[:space:]]%d; \%^# RAID1 jukebox%d" "$FSTAB" || true
  sed -i "/name=.*:$MD_NAME/d" "$MDADM_CONF" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  rm -f "$MODULES" || true
  if [ "$WIPE" = 1 ]; then
    warn "--wipe: destroying the array and the data on both disks"
    local members=""
    [ -n "$md" ] && members="$(mdadm --detail "$md" 2>/dev/null | awk '/\/dev\/sd/{print $NF}')"
    [ -n "$md" ] && mdadm --stop "$md" 2>/dev/null || true
    local d
    for d in $members; do
      mdadm --zero-superblock "$d" 2>/dev/null || true
      wipefs -a "$d" 2>/dev/null || true
    done
    ok "array destroyed"
  else
    [ -n "$md" ] && mdadm --stop "$md" 2>/dev/null || true
    ok "array stopped and config removed; disks and data intact"
  fi
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------

cmd="install"
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    install|apply|verify|status|uninstall) cmd="$1"; shift ;;
    --disk-a) DISK_A="$2"; shift 2 ;;
    --disk-b) DISK_B="$2"; shift 2 ;;
    --name) MD_NAME="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --mount) MNT="$2"; shift 2 ;;
    --reformat) REFORMAT=1; shift ;;
    --resync) RESYNC=1; shift ;;
    --no-quirk) USE_QUIRK=0; shift ;;
    --wipe) WIPE=1; shift ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

case "$cmd" in
  install)   cmd_install ;;
  apply)     cmd_apply ;;
  verify)    cmd_verify ;;
  status)    cmd_status ;;
  uninstall) cmd_uninstall ;;
esac
