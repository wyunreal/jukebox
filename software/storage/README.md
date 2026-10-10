# storage — RAID 1 music library

Two 3.5" SATA hard drives in USB enclosures, mirrored (**RAID 1**) and mounted
where Volumio expects removable storage, so the music library lives on the
disks instead of the SD card. This directory is **not a package** (no
`deploy.sh` / `install.sh`): it is the on-host script plus this doc. Run it by
hand over SSH.

## What it does

| | |
|---|---|
| Array | `/dev/md0`, `raid1`, name `<host>:music` (so `/dev/md/music`) |
| Filesystem | `ext4`, label `MUSIC` |
| Mount | `/media` — which is what Volumio's `/mnt/USB` symlinks to, so the library shows it as the **`USB`** source |
| Music goes in | `/media/Music/` (SMB share **`USB`**, or `Internal Storage` stays on the SD) |
| Boot | assembled by the `mdadm` udev rules (`/etc/mdadm/mdadm.conf`) and mounted from `/etc/fstab`; the `raid1`/`md_mod` modules are pinned in `/etc/modules-load.d/raid.conf` |

## The important hardware caveats

1. **The disks need their own power supply.** A 3.5" drive needs 12 V + 5 V and
   draws several watts; the USB bus (5 V, 0.5 A) cannot run one, let alone two.
   And a mirror **writes to both disks at once**, so a RAID 1 doubles the power
   draw. Without a proper PSU (the enclosure/dock's barrel jack, or a
   self-powered hub) the drives brown out under load: USB disconnects, I/O
   errors and a quickly-degraded array. This is the number one failure mode.
2. **These enclosures (JMicron JMS583, `152d:0583`) are unstable with UAS.**
   Under load they drop off the bus. The script pins
   `usb-storage.quirks=152d:0583:u` in `/boot/cmdline.txt` to force Bulk-Only
   Transport (`usb-storage`) instead of UAS. It's applied from the next boot.
3. **Watch the negotiated speed.** Some of these adapters report themselves as
   USB 2.0 (`bcdUSB 2.10`) and will never exceed 480 Mbps, however blue the port
   is. ~15–30 MB/s is plenty for playback; it only hurts large copies. If you
   want USB 3.0 speeds, use real USB 3.0 enclosures.

Volumio's root is an overlay on the SD card, so `/etc` changes persist across
reboots — but a **Volumio system update** can reset `/boot/cmdline.txt`, taking
the UAS quirk with it (and the cuelgues come back). Re-run `install` after an
update. The array and its data live on the physical disks and survive anything
done to the SD card.

## Usage (on the Volumio host, as root)

```sh
sudo ./raid-music.sh install                       # create (or adopt) + mount
sudo ./raid-music.sh install --disk-a /dev/sda --disk-b /dev/sdb
sudo ./raid-music.sh install --reformat            # allow wiping non-empty disks
sudo ./raid-music.sh install --resync              # force a full initial resync
sudo ./raid-music.sh install --no-quirk            # don't touch /boot/cmdline.txt
sudo ./raid-music.sh apply                         # re-assert config + mount (idempotent)
sudo ./raid-music.sh verify                        # pass/fail checks
sudo ./raid-music.sh status                        # array, mount, disks, SMART
sudo ./raid-music.sh uninstall                     # remove config, keep the data
sudo ./raid-music.sh uninstall --wipe              # DESTROY the array and its data
```

Safety model:

* If the array already exists it is **adopted** — only `mdadm.conf`, `fstab` and
  the mount are re-asserted. Never reformatted.
* With no array, it uses **two empty whole disks** (auto-detected, or given with
  `--disk-a/--disk-b`). A disk with a partition table or a filesystem is
  **refused** unless `--reformat` is passed.

### From the development machine

```sh
scp software/storage/raid-music.sh volumio@<host>:/tmp/
ssh volumio@<host> 'echo <password> | sudo -S -p "" \
  bash /tmp/raid-music.sh install --disk-a /dev/sda --disk-b /dev/sdb'
```

## Replacing a failed disk

The array keeps serving in degraded mode. To re-add a disk, find the device by
serial and add it; `mdadm` rebuilds the mirror (slow over USB 2.0):

```sh
ls -l /dev/disk/by-id/ata-*                       # find the replacement
sudo mdadm /dev/md0 --add /dev/sdX
watch -n2 cat /proc/mdstat                       # wait for [2/2] [UU]
```

## Recovery

```sh
cat /proc/mdstat
sudo mdadm --detail /dev/md0
sudo ./raid-music.sh verify
dmesg | grep -iE 'usb|uas|I/O error|reset'       # link problems live here
```

If both disks vanish, it's almost always power or the USB link, not the disks —
check the PSU and the enclosure before touching the array.
