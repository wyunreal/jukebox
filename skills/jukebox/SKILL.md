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
ssh moode@<host>            # moOde box: login user is `moode`
```

The live daily-driver box is the **Volumio** one; the **moOde** box is the
port on the second SD (`software/moode/dual-output/`). Ask the user which one
to work on.

`<host>` is whatever mDNS name or IP the user set up (Volumio's default
hostname is `volumio`; the moOde box was named `jukebox`). If the name doesn't
resolve, ask the user or discover it:

```sh
avahi-browse -rt _ssh._tcp        # find SSH-advertising hosts on the LAN
```

No passwords are stored anywhere (deliberately). `sudo` on the box needs the
user's password — ask for it, or have them run
`JUKEBOX_PASSWORD=... ./deploy.sh ...` from their machine. Never hardcode
credentials into files.

## Expected state after login (checklist)

**Volumio box:**

| Check | Command | Expected |
|---|---|---|
| Services | `systemctl is-active volumio mpd volumio-kiosk` | all `active` |
| Volumio API | `curl -s localhost:3000/api/v1/getState` | JSON with `status`, `volume` |
| Live variant | `grep variant /etc/asound.conf` | `# jukebox-audio variant: usb` |
| Volume control | `amixer -c sndrpirpidac sget SoftMaster` | readable 0–99 control |
| Guard units | `systemctl is-enabled jukebox-audio-guard.service jukebox-audio-guard.path` | both `enabled` |
| Pot service | `systemctl is-active jukebox-pots` | `active` (if installed) |
| Pot port | `ls /dev/ttyACM*` | the PowerAndPots/Keyboard Arduino (if plugged) |
| Tone engine | `systemctl is-active jukebox-pots` + `pgrep -x camilladsp` | service active; CamillaDSP runs only while playing |
| Tone config | `ls /usr/local/jukebox-audio/cdsp/camilla.*.yml` | one template per variant (`0644`) |
| Tool | `sudo /usr/local/jukebox-audio/jukebox-audio.sh status` | `second output: usb`, `live variant: usb` |
| UI boost | `sudo /usr/local/jukebox-ui/jukebox-ui.sh verify` | all `ok`, X screen `800x480` |
| UI guard | `systemctl is-active jukebox-ui-guard.path` | `active` |

**moOde box:**

| Check | Command | Expected |
|---|---|---|
| Services | `systemctl is-active mpd jukebox-pots jukebox-moode-guard.path` | all `active` |
| I2S DAC | `cat /proc/asound/cards` | `sndrpirpidac` present (overlay `i2s-dac`) |
| Split | `grep slave.pcm /etc/alsa/conf.d/_audioout.conf` | `"jukeboxSplit"` |
| Tone state | `readlink -f /usr/share/camilladsp/working_config.yml` | `.../configs/jukebox-tone.yml` |
| Volume type | `grep mixer_type /etc/mpd.conf \| head -1` | `null` (CamillaDSP fader) |
| Tool | `sudo /usr/local/jukebox-moode/jukebox-moode.sh status` | split + tone + guard active |
| Pot service | `systemctl is-active jukebox-pots` + `journalctl -u jukebox-pots \| tail` | `active`; says `platform moode` |

If the USB card is unplugged, the chain automatically falls back to DAC-only
(speakers keep playing) on both platforms; plug it back and the guard/udev
re-activates the split within seconds. That is by design.

## The jukebox-audio tool

Canonical files + helper live in `/usr/local/jukebox-audio/`; the same script
is in this repo at `software/volumio/dual-output/` (full design docs in its
README).

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

## The jukebox-moode tool

Canonical files + helper live in `/usr/local/jukebox-moode/`; the same script
is in this repo at `software/moode/dual-output/` (design docs in its README,
full plan in `docs/moode-port-plan.md`).

```sh
sudo /usr/local/jukebox-moode/jukebox-moode.sh status     # quick overview
sudo /usr/local/jukebox-moode/jukebox-moode.sh verify     # full checks
sudo /usr/local/jukebox-moode/jukebox-moode.sh apply      # re-assert (guard runs this)
sudo /usr/local/jukebox-moode/jukebox-moode.sh install --second-output usb|none
sudo /usr/local/jukebox-moode/jukebox-moode.sh uninstall  # restore moOde files
```

Differences from Volumio worth remembering:

* The split lives in `/etc/alsa/conf.d/90-jukebox-split.conf` and `_audioout.conf`
  is pointed at `pcm.jukeboxSplit`; moOde rewrites `_audioout.conf` on output
  changes, so `jukebox-moode-guard.path` watches it and re-asserts.
* Tone+balance live in **one** CamillaDSP config,
  `/usr/share/camilladsp/configs/jukebox-tone.yml`, selected through moOde's
  `working_config.yml` symlink. `jukebox-pots` rewrites its gains and sends
  `SIGHUP`.
* Volume type must be **CamillaDSP** (moOde UI: Audio Config → Volume type).
  It turns the knob into the CamillaDSP fader; only the DAC branch passes
  through it, so the analyser feed stays at a fixed level.
* The first playback after `pkill camilladsp` (or a reboot) is slower: the
  `cdsp` plugin starts CamillaDSP per open. That is normal.
* The DAC overlay on this Pi is `i2s-dac` (PCM1794A), not a HiFiBerry one;
  moOde Audio Config lists it as **"Generic-I2S (i2s-dac)"**.

## The jukebox-ui tool (touch screen speed)

The touch UI was sluggish/scrolling badly because Chromium was forced into
software compositing, the `now_playing` UI used very heavy CSS blurs, and a
phantom HDMI output forced the X screen to 848px over an 800px panel. Fixed by
`software/volumio/ui-boost/` (canonical copies in `/usr/local/jukebox-ui/`).

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
| Music plays a while, then Volumio says "failed to open output device" | player underrun escalated to a fatal XRUN (old plugin, or buffer too small) | update the plugin + `apply` (3 s buffer, silence concealment); check `mpd.log` for `XRUN`/`Broken pipe` |
| moOde: DAC missing in Audio Config despite selecting it | wrong overlay (e.g. HiFiBerry PCM5122) for this PCM1794A board | `dtoverlay=i2s-dac` in `/boot/firmware/config.txt`, select "Generic-I2S (i2s-dac)", reboot |
| moOde: split/tone reverted after touching Audio Config | moOde rewrote `_audioout.conf` / the CamillaDSP selection | `sudo /usr/local/jukebox-moode/jukebox-moode.sh apply`; check the guard is active |
| moOde: volume doesn't reach the speakers | Volume type is not CamillaDSP | Audio Config → Volume type → CamillaDSP, or `cdsp` isn't selected as working config |
| moOde: DAC plays but the USB analyser gets no signal | split missing the `route` stage, or the card mixer at a low level | `grep jukeboxRoute /etc/alsa/conf.d/90-jukebox-split.conf` (must exist); `amixer -c <usb> sset PCM 100%`; `apply` fixes both |
| Plays ~1 s (analyser blips) then stops; `mpd.log` shows `Error writing output config file` | active CamillaDSP config not writable by `mpd` (stale `root:0644` copy) | `chmod 0666 /var/lib/jukebox-audio/camilla-active.*.yml`, then `apply`; the plugin now writes it atomically with mode 0666 |
| Tone stops after reboot | CamillaDSP config regenerated without gains | the installer preserves gains; re-check `grep gain /usr/local/jukebox-audio/cdsp/camilla.*.yml` |
| Chain refuses to open | files hand-edited and guard reverted mid-play, or device busy | `mpc stop`; `apply`; `verify --with-playback` |

## Repo map (for reference)

- `software/volumio/dual-output/` — installer, deploy helper, README (the full
  design doc: the ALSA split, the CamillaDSP tone step, variants, the `multi`
  fail-safe). Ships the armv7 `camilladsp` binary and the armhf `cdsp` plugin.
- `software/jukebox-pots/` — `jukebox-pots.service`: reads `POT volume` /
  `POT balance` / `POT single` / `POT multi second` from the PowerAndPots
  Arduino over USB serial and drives the DAC volume (Volumio API), balance
  (per-channel `SoftMaster`) and bass/treble (CamillaDSP config + `SIGHUP`, live).
  Install with `software/jukebox-pots/deploy.sh install`; check with `... status`.
  It only touches the DAC branch, never the analyser feed.
- This skill lives in `skills/jukebox/`.

When the user asks for jukebox work and anything looks different from this
file, trust the live box: `jukebox-audio.sh status` + `verify` +
`/var/log/jukebox-audio.log` tell the real story.
