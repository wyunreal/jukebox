---
name: jukebox
description: Operate and troubleshoot the user's homemade jukebox — a Raspberry Pi 4B running Volumio with a custom dual audio output (I2S DAC speakers, volume-controlled; a second fixed-level output, currently a USB sound card, feeding a hardware spectrum analyser) and a DSI touch screen. Use this skill whenever the user mentions "the jukebox", "la jukebox", "el jukebox", "Volumio", "la rocola", the music box, its audio/volume/spectrum analyser/touch screen, or asks to connect to it, SSH in, check/fix/change its sound setup, or run the audio installer — even when they don't explicitly say "jukebox".
---

# Jukebox (Volumio on Raspberry Pi)

## What this is

A homemade jukebox: Raspberry Pi 4B running **Volumio** (Raspbian bookworm,
kernel 6.12.y) with:

- **I2S DAC** (PCM1794A, ALSA card `sndrpirpidac`) → speakers. Volume-controlled.
- **Second fixed-level output** for a hardware spectrum analyser. Currently a
  **USB sound card** (`USB PnP Sound Device`, PCM2902). Its ALSA card number is
  dynamic — always find it by name.
- **DSI touch screen** (plugin `touch_display`, `volumio-kiosk.service`,
  Xorg on :0).
- The 3.5 mm jack and both HDMI outputs exist but are **not** in use.

The audio chain is custom ("jukebox-audio"): an ALSA `multi` split where the
software volume (`SoftMaster`) sits only on the DAC branch, so the Volumio
volume slider moves the speakers and never the analyser feed. MPD's own mixer
is disabled (`mixer_type "none"`) — `mpc volume` answering "No mixer" is
**expected**, not a bug. Control volume through Volumio (UI or API).

## Connecting

```sh
ssh volumio@<host>          # Volumio box: login user is `volumio`
```

`<host>` is whatever mDNS name or IP the user set up (Volumio's default
hostname is `volumio`). If the name doesn't resolve, ask the user or discover it:

```sh
avahi-browse -rt _ssh._tcp        # find SSH-advertising hosts on the LAN
```

No passwords are stored anywhere (deliberately). `sudo` on the box needs the
user's password — ask for it, or have them run
`JUKEBOX_PASSWORD=... ./deploy.sh ...` from their machine. Never hardcode
credentials into files.

## Install / operate everything

From the repo (development machine) a single wrapper drives every package over
SSH in dependency order — `dual-output` → `ui-boost` → `jukebox-pots` →
`pot-overlay` → `ui-nav` → `jukebox-keyboard` (reversed for uninstall):

```sh
./deploy-all.sh -H user@host install      # every package; second output fixed to usb
./deploy-all.sh -H user@host verify
./deploy-all.sh -H user@host status
./deploy-all.sh -H user@host uninstall
# password for sudo (host is required: -H or $JUKEBOX_HOST)
./deploy-all.sh -H volumio@<host> -p <pass> install
```

The host is **required**: pass `-H user@host` (or set `JUKEBOX_HOST`); there is
no built-in default. Use `-p <password>` (or `JUKEBOX_PASSWORD`) when `sudo` on
the box needs one. It just sequences each package's own `deploy.sh`, so
package-specific one-off options (`--second-output`, `--key-action`, …) still
go through the per-package `deploy.sh`. For this box `install` fixes the second
output to `usb`. The pot power button (short press halts the Pi; relay cut after
the Arduino-side delay) is on by default. Per package, for example:

```sh
software/jukebox-pots/deploy.sh -H volumio@<host> -p <pass> install
software/jukebox-pots/deploy.sh -H volumio@<host> install --no-power-button
software/jukebox-pots/deploy.sh -H volumio@<host> install --power-off-delay 45
software/jukebox-keyboard/deploy.sh -H volumio@<host> install --key-action next 1,4
```

## Expected state after login (checklist)

| Check | Command | Expected |
|---|---|---|
| Services | `systemctl is-active volumio mpd volumio-kiosk` | all `active` |
| Volumio API | `curl -s localhost:3000/api/v1/getState` | JSON with `status`, `volume` |
| Live variant | `grep variant /etc/asound.conf` | `# jukebox-audio variant: usb` |
| Volume control | `amixer -c sndrpirpidac sget SoftMaster` | readable 0–99 control |
| Guard units | `systemctl is-enabled jukebox-audio-guard.service jukebox-audio-guard.path` | both `enabled` |
| Pot service | `systemctl is-active jukebox-pots` | `active` (if installed) |
| Keyboard service | `systemctl is-active jukebox-keyboard` | `active` (if installed) |
| Pot port | `ls /dev/ttyACM*` | the PowerAndPots/Keyboard Arduino (if plugged) |
| Tone engine | `systemctl is-active jukebox-pots` + `pgrep -x camilladsp` | service active; CamillaDSP runs only while playing |
| Tone config | `ls /usr/local/jukebox-audio/cdsp/camilla.*.yml` | one template per variant (`0644`) |
| Tool | `sudo /usr/local/jukebox-audio/jukebox-audio.sh status` | `second output: usb`, `live variant: usb` |
| UI boost | `sudo /usr/local/jukebox-ui/jukebox-ui.sh verify` | all `ok`, X screen `800x480` |
| UI guard | `systemctl is-active jukebox-ui-guard.path` | `active` |
| Pot overlay | `systemctl is-active jukebox-overlay.service` | `active` (port 3210) |
| UI nav | `systemctl is-active jukebox-ui-nav.service` | `active` (port 3211) |
| Keyboard | `systemctl is-active jukebox-keyboard.service` | `active` (if installed) |

If the USB card is unplugged, the chain automatically falls back to DAC-only
(speakers keep playing); plug it back and the guard/udev re-activates the split
within seconds. That is by design.

## The jukebox-audio tool

Canonical files + helper live in `/usr/local/jukebox-audio/`; the engine is in
this repo at `software/volumio/dual-output/files/jukebox-audio.sh` (full design
docs in its README).

```sh
sudo /usr/local/jukebox-audio/jukebox-audio.sh status     # quick overview
sudo /usr/local/jukebox-audio/jukebox-audio.sh verify     # full checks (--with-playback also tests MPD playback)
sudo /usr/local/jukebox-audio/jukebox-audio.sh apply      # re-assert current config (idempotent)
sudo /usr/local/jukebox-audio/jukebox-audio.sh install --second-output usb|hdmi|jack|none
sudo /usr/local/jukebox-audio/jukebox-audio.sh uninstall  # restore the pre-install backup
```

**Analyser bass trim.** The analyser (second) branch carries a fixed low-shelf
filter so the spectrum analyser's hardware bass over-read is compensated. It is
on the second branch only; the speakers are untouched. Defaults: `60 Hz,
-6.02 dB (= half amplitude), Q 0.5`, which gives ~-6 dB below 40 Hz and flat
above ~80 Hz. Implemented with CAPS `Eq4p` via the `alsaequal` `equal` plugin
(auto-installed). Change with `--analyser-trim on|off`, `--analyser-freq HZ`,
`--analyser-gain dB`, `--analyser-q Q` (or `JB_ANALYSER_*`); the value is baked
into a deterministic `/var/lib/jukebox-audio/analyser-eq.bin`. `status` shows
it as `analyser trim :`.

- Log: `/var/log/jukebox-audio.log`; backups: `/var/backups/jukebox-audio/latest/`.
- `jukebox-audio-guard.path` watches `/etc/asound.conf`, the Volumio ALSA
  snippet and `special_cards_config.json`: if Volumio rewrites them from its
  UI, the guard restores the correct config and restarts MPD. If you hand-edit
  those files the guard will revert them — edit the canonical copies in
  `/usr/local/jukebox-audio/` and run `apply` instead (or stop the path unit
  while experimenting).
- From a dev machine: `software/volumio/dual-output/deploy.sh install
  --second-output usb` copies the installer over SSH and runs it remotely.

## The jukebox-ui tool (touch screen speed)

The touch UI was sluggish/scrolling badly because Chromium was forced into
software compositing, the `now_playing` UI used very heavy CSS blurs, and a
phantom HDMI output forced the X screen to 848px over an 800px panel. Fixed by
`software/volumio/ui-boost/` (canonical copies in `/usr/local/jukebox-ui/`).
Install/deploy with `software/volumio/ui-boost/deploy.sh install` (or its
`install.sh` on the host); a reboot makes it take effect.

```sh
sudo /usr/local/jukebox-ui/jukebox-ui.sh status   # overview + X screen
sudo /usr/local/jukebox-ui/jukebox-ui.sh verify    # pass/fail checks
sudo /usr/local/jukebox-ui/jukebox-ui.sh apply     # re-assert (used by guard)
```

- Log: `/var/log/jukebox-ui.log`.
- `jukebox-ui-guard.path` watches `/opt/volumiokiosk.sh` and
  `/etc/chromium.d/00-rpi-vars`; saving a setting on the Touch Display page
  regenerates the kiosk script, and the guard re-applies the fixes. Same
  trap as the audio guard: edit canonical copies + `apply`, don't hand-edit.
- After updating the `now_playing` plugin, its CSS is replaced: run
  `apply` manually once.
- The HDMI-off hook turns the phantom output off inside the X session; do
  **not** enable HDMI audio (see golden rules).

## Common tasks

**Change/read volume (the supported way):**
```sh
curl -s 'localhost:3000/api/v1/commands/?cmd=volume&volume=42'
curl -s localhost:3000/api/v1/getState | grep -o '"volume":"[0-9]*"'
```

**Play / pause / status:** `mpc play`, `mpc stop`, `mpc status` (MPD is
Volumio's playback engine).

**Add music over SMB:** the box runs Samba with guest shares and advertises
itself as host **`Jukebox`**, so it shows up by itself in the file manager's
Network view. Shares: `Internal Storage` (`/data/INTERNAL`), `USB`
(`/mnt/USB`), `NAS` (`/mnt/NAS`) — no password, connect as guest. Put music in
`Internal Storage/Music`. Mount from Linux with
`sudo mount -t cifs '//<host>/Internal Storage' /mnt/jukebox -o guest`.
After copying, rescan with `mpc update` (Volumio's REST API has **no**
`updateLibrary`/`rescan` command; the UI button uses MPD's socket).

**Check that both outputs are really playing:**
```sh
mpc play; sleep 5
for c in $(awk '/^ *[0-9]+ \[/ {print $1}' /proc/asound/cards); do
  echo "card$c: $(head -1 /proc/asound/card$c/pcm0p/sub0/status 2>/dev/null)"
done
# expect: sndrpirpidac RUNNING AND the USB card RUNNING
```

**Quick silent chain test (opens both branches, no UI interaction):**
`aplay -D volumio -f S16_LE -r 44100 -c 2 -d 3 /dev/zero` then check the two
states above.

**Find cards by name (numbers can shift across boots!):**
`cat /proc/asound/cards`; path symlinks exist per name, e.g.
`/proc/asound/sndrpirpidac`.

## Golden rules / traps

- **Never use an HDMI output for audio.** On this Pi it grabs the DRM display
  and kills the DSI touch screen (`touch_display` plugin). This already
  happened once; the USB second output exists because of it. The `hdmi`
  variant is still supported for other setups, but don't enable it here unless
  the user explicitly asks and accepts the touch-screen risk.
- **The analyser feed must stay at constant level.** All volume control
  belongs to `SoftMaster` on `sndrpirpidac`. If volume "stops working" on the
  DAC or starts affecting the second output, run `verify` and confirm
  `softvolume=true`, `mixer=SoftMaster`, `mixer_type=Software` in
  `/data/configuration/audio_interface/alsa_controller/config.json`.
- **Card numbers change** when devices are added/removed (boot order, USB
  hotplug). Everything is wired by *name* (`hw:CARD=...`, `/proc/asound/<name>`).
  Don't "fix" anything by writing numeric card indices into configs.
- **`mpc volume` doesn't work on purpose** (MPD mixer disabled). Don't
  "repair" that by re-enabling MPD's mixer — it would let MPD touch the jack /
  second output control.
- **Re-installing is safe**: `install` is idempotent and takes a fresh backup.
  It's the go-to fix if the audio config gets mangled. The `multi` split is
  all-or-nothing: if one branch can't open, everything is silent — the
  fail-safe avoids that by keeping only the DAC branch while the second device
  is away.
- **The active CamillaDSP config must stay writable by `mpd`.** The `cdsp`
  plugin rewrites `/var/lib/jukebox-audio/camilla-active.*.yml` on every open;
  it runs as `mpd` for playback but as root during install/verify. Never
  pre-create that file as `root:0644` (or `chmod 0644` it): playback then
  dies after ~1 s with `Error writing output config file` in `mpd.log`. The
  plugin now writes it atomically and forces `0666`, and `apply`/`install`
  re-assert the mode (`fix_active_perms`).
- **Underruns must never be fatal.** MPD runs a 3 s ALSA buffer on the split
  chain (`buffer_time "3000000"` in `special_cards_config.json`) and the
  `cdsp` plugin feeds silence when the application stalls, instead of raising
  an XRUN. Don't shrink that buffer or reintroduce the fatal path: a player
  hiccup would surface as "failed to open output device" in Volumio.
- Reboots are normal after audio changes; the guard + `alsa-restore` restore
  everything (including the `SoftMaster` element) on boot.

## Troubleshooting quick table

| Symptom | Likely cause | Fix |
|---|---|---|
| No sound at all | chain broken, or second device vanished mid-session | `status`; if variant `daconly`, replug USB; then `apply` |
| Speakers fine, no analyser feed | USB card absent or variant `daconly` | replug, wait ~10 s (udev), else `install --second-output usb` |
| Volumio volume slider does nothing | `SoftMaster` element lost | `systemctl restart alsa-restore`; `apply` |
| Volume affects the analyser too | wrong variant / mixer binding | `verify`, then `install --second-output usb` |
| Touch screen dead | something enabled HDMI audio/DRM output | check `/boot/userconfig.txt` and the touch_display plugin config; reboot; re-run `install --second-output usb` if the HDMI variant sneaked in |
| Arduino never shows as `ttyACM*`, `lsusb` clean, but LEDs on | 32U4 needs VBUS sense; a clone (Pro Micro) powers up without it | bridge the Pro Micro `J1`/`SJ1` jumper (VCC->UVCC/VBUS), or wire `5V`/`VCC` to the VBUS net. See `software/jukebox-pots/README.md` |
| Restarting `jukebox-pots` cuts the jukebox power | **DTR reset**: DTR is tied to reset on the Micro (same board runs the power state machine) | the daemon must not assert DTR (it does not); do not use `cat`/tools that raise DTR |
| Pots do nothing but `jukebox-pots` is active | board not enumerated, wrong port, or `SoftMaster` missing | `sudo /usr/local/jukebox-pots/jukebox-pots.py --probe`; `journalctl -u jukebox-pots` |
| Tone pots do nothing | tone off (`JB_TONE`), no CamillaDSP config, or the daemon can't write it | check `ls /usr/local/jukebox-audio/cdsp/`; `journalctl -u jukebox-pots \| grep tone`; reinstall `jukebox-audio` with tone on |
| No sound after installing the tone | CamillaDSP `chunksize` too large for the cdsp pipe (deadlock, XRUN) | keep `chunksize: 512` in the tone template; `apply`; reinstall |
| Power button short press does nothing | `JP_POWER_BUTTON=0` (disabled), or firmware not reflashed | install `jukebox-pots` without `--no-power-button`; reflash the PowerAndPots Arduino; check `journalctl -u jukebox-pots` |
| Pi shuts down but the relay never cuts | firmware without the `POWER: off` command, or serial port dead at shutdown | reflash the Arduino; the cut is Arduino-side (`POWER_OFF_DELAY_MS`, default 30 s) |
| Pi halts on a short press but you wanted a hard cut | long press (≥ 5 s) is the immediate cut; it also cancels a pending soft-off | hold the button ≥ 5 s |
| Music plays a while, then Volumio says "failed to open output device" | player underrun escalated to a fatal XRUN (old plugin, or buffer too small) | update the plugin + `apply` (3 s buffer, silence concealment); check `mpd.log` for `XRUN`/`Broken pipe` |
| Plays ~1 s (analyser blips) then stops; `mpd.log` shows `Error writing output config file` | active CamillaDSP config not writable by `mpd` (stale `root:0644` copy) | `chmod 0666 /var/lib/jukebox-audio/camilla-active.*.yml`, then `apply`; the plugin now writes it atomically with mode 0666 |
| Tone stops after reboot | CamillaDSP config regenerated without gains | the installer preserves gains; re-check `grep gain /usr/local/jukebox-audio/cdsp/camilla.*.yml` |
| Chain refuses to open | files hand-edited and guard reverted mid-play, or device busy | `mpc stop`; `apply`; `verify --with-playback` |
| Overlay never shows | server down, nothing connected, or UI loader gone | `systemctl status jukebox-overlay`; `curl localhost:3210/state`; `sudo /usr/local/jukebox-overlay/apply.sh`; restart `volumio-kiosk` |
| Overlay gone after a Volumio update | `index.html` rewritten | `systemctl start jukebox-overlay-guard.service` (re-injects), or re-run `apply.sh` |
| A keyboard key does nothing | key not mapped, or wrong board | `journalctl -u jukebox-keyboard` (shows `unmapped key r,c`); identify with `jukebox-keyboard.py --watch`, edit `software/jukebox-keyboard/files/keymap.conf` and re-install (or a one-off `--key-action <action> r,c`) |

## Repo map (for reference)

- `software/volumio/dual-output/` — scripts (`deploy.sh`, `uninstall.sh`) plus
  `files/` with the engine (`jukebox-audio.sh`), the guard units/udev rule, the
  armv7 `camilladsp` binary and the armhf `cdsp` plugin + source. Full design doc
  in its README (the ALSA split, the CamillaDSP tone step, variants, the `multi`
  fail-safe).
- `software/jukebox-pots/` — `jukebox-pots.service`: reads `POT volume` /
  `POT balance` / `POT single` / `POT multi second` from the PowerAndPots
  Arduino over USB serial and drives the DAC volume (Volumio API), balance
  (per-channel `SoftMaster`) and bass/treble (CamillaDSP config + `SIGHUP`, live).
  Install with `software/jukebox-pots/deploy.sh install`; check with `... status`.
  It only touches the DAC branch, never the analyser feed. It also watches the
  Arduino's `POWER:` lines: a short power-button press halts the Pi and the
  Arduino cuts the relay ~30 s later (delay lives on the board, powered from
  5VSB); the long press stays the immediate hard cut. On by default; disable
  with `--no-power-button`.
- `software/volumio/pot-overlay/` — on-screen circular indicator for balance /
  bass / treble (Volumio's own volume indicator covers volume only). The daemon
  POSTs each change to a tiny stdlib HTTP/SSE server (`/usr/local/jukebox-overlay`,
  port 3210) and the UI loads `overlay.js` (injected into `/volumio/http/www*/index.html`
  by `apply.sh`, kept in place by `jukebox-overlay-guard.path`). The client reuses
  the UI's bundled jQuery-knob so it looks like the volume indicator. Install with
  `software/volumio/pot-overlay/deploy.sh install` (after jukebox-pots).
- `software/volumio/ui-nav/` — daemon → UI navigation channel (port 3211): a small
  stdlib HTTP/SSE server plus an injected `ui-nav.js` that drives the UI's
  ui-router `$state`. A daemon POSTs `{"type":"nav","view":"toggle"|"home"|"queue"}`
  to switch between the now-playing home and the play queue. Used by the
  keyboard's open/close key; separate from `pot-overlay` on purpose.
  Install with `software/volumio/ui-nav/deploy.sh install`.
- `software/jukebox-keyboard/` — `jukebox-keyboard.service`: reads the
  KeyboardArduino's key events (`DOWN`/`UP`/`PRESS`/`LONG_PRESS`/`PRESSED`) and on
  key **press** runs the mapped Volumio command (play/pause/stop/prev/next/mute/
  clear, favourite toggle, save queue as playlist, or open/close the queue view).
  The key map is **versioned in the repo** at
  `software/jukebox-keyboard/files/keymap.conf` (`ACTION=ROW,COL`) and installed
  as-is, so a fresh/re-installed box gets the same keys; a one-off
  `--key-action ACTION ROW,COL` overrides single entries. The installed copy is
  `/usr/local/jukebox-keyboard/config.env` (`JK_KEY_<action>=row,col`);
  identify a key with `.../jukebox-keyboard.py --watch`. Selects the board by the
  `Jukebox Keyboard` USB product string. Install with
  `software/jukebox-keyboard/deploy.sh install`.
- `deploy-all.sh` (repo root) — install/uninstall/verify/status for all packages
  in dependency order.
- This skill lives in `skills/jukebox/`.

When the user asks for jukebox work and anything looks different from this
file, trust the live box: `jukebox-audio.sh status` + `verify` +
`/var/log/jukebox-audio.log` tell the real story.
