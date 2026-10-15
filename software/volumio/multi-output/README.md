# jukebox multi-output (Volumio + Raspberry Pi)

Adds a second, **constant-level** audio output while keeping the I2S DAC as
the main, volume-controlled output, plus a **bass/treble tone control** on the
speaker path.

What you get:

| Output | Level | Tone control |
| --- | --- | --- |
| I2S DAC (speakers) | controlled by the normal Volumio volume slider / API / MPD | **bass + treble** (CamillaDSP) |
| Second output (spectrum analyser) | constant level; not affected by volume | none (stays untouched) |

Both outputs always play the same stream, simultaneously.

## Tone control (bass / treble)

The DAC branch carries a low-shelf and a high-shelf biquad, applied by
[CamillaDSP](https://github.com/HEnquist/camilladsp) through the ALSA `cdsp`
plugin (shipped precompiled in this directory, source + `strrep.h` in `cdsp/`).

```
volumio -> softvolume -> jukeboxRoute -> jukeboxSplit (multi)
    |- volumioSoftVol (SoftMaster: volume/balance)
    |      '- jukeboxTone (cdsp -> CamillaDSP: Lowshelf + Highshelf) -> DAC
    '- jukeboxEq (analyser bass trim) -> USB/HDMI/jack  (analyser)
```

* Both shelves default to **0.0 dB**, which is bit-for-bit transparent.
* `jukebox-pots` rewrites the two gains in the CamillaDSP config and sends it
  a `SIGHUP`, so the tone changes **live**, without stopping playback.
* The tone applies to the **DAC branch only**; the analyser feed is not
  affected by the tone (by design).
* CamillaDSP runs at the file's native rate (the `cdsp` plugin substitutes
  `$samplerate$`/`$format$`/`$channels$` on every open), so hi-res files are
  not resampled.
* `chunksize` is **512** on purpose: a larger chunk than the plugin's pipe
  buffer deadlocks the stream (the player waits forever in `poll()`); 512
  matches it.
* Tone options: `--no-tone` (`JB_TONE=off`), `--tone-bass HZ`,
  `--tone-treble HZ`, `--tone-q Q`. Rebuild the plugin on the host with
  `JB_TONE_BUILD_CDSP=1` (needs `gcc` + `libasound2-dev`).

## Choosing the second output

| `--second-output` | Device | Notes |
| --- | --- | --- |
| `usb` | a **USB sound card / DAC** (any extra ALSA card) | **Recommended.** Independent device, no interference with display or jack. |
| `hdmi` | an **HDMI audio extractor** | Digital end-to-end (no PWM noise), but on this Pi it can grab the DSI touch screen as a DRM output and disable the touch_display plugin. Test before adopting. |
| `jack` | the Pi **3.5 mm jack** | Simple, but the jack is a PWM output prone to conducted noise (fixed pattern visible in an analyser). |
| `none` | — | Only the DAC plays (no second output). |

The installer auto-detects the cards; if the chosen second output is not
present at install time (e.g. USB unplugged), it installs a **DAC-only
fallback** and switches to the full multi-output chain automatically when the device
appears (udev handles hotplug).

### Several USB cards: pinning the analyser card

A USB sound card's ALSA *id* is generic (`Device`, `Device_1`, ...) and the
kernel assigns it by enumeration order, so **plugging a second USB card can
steal the name of the first one**. When that happens the analyser feed silently
moves to the new card (and, since the `multi` split is all-or-nothing, the whole
chain can break if that card cannot open at the requested rate).

To avoid it, pin the analyser card by name **and** by a substring of its long
name (shown by `status` as the second line next to `usb card`):

```sh
sudo ./files/jukebox-audio.sh install --second-output usb \
     --usb-card Device_1 --usb-card-match "USB PnP"
# or via env: JB_USB_CARD=Device_1 JB_USB_CARD_MATCH="USB PnP"
```

`detect_usb_card` then:

* keeps working if the kernel renames the cards (it re-finds the card whose
  long name matches, wherever it moved), and
* falls back to **daconly** — never to the other USB card — if the pinned card
  is unplugged.

Without `JB_USB_CARD_MATCH` the old behaviour remains: the first non-DAC USB
card found wins. This is the exact setup on the jukebox: `Device_1` is the
C-Media `USB PnP Sound Device` (analyser feed, `08bb:2902`) and `Device` is a
second `DSD TECH USB Audio Device` (`0d8c:0247`) used as the clean S/PDIF feed
(see below).

### Optional third output: a processed S/PDIF feed

With `--second-output usb`, a **third output** can be added to the same split:
a second USB card used as a **S/PDIF** feed for an external DAC or receiver. It
gets the **same volume/balance as the DAC** (a second `softvol` reading the
shared `SoftMaster` control) and its own **bass/treble tone** via the ALSA
`equal` plugin (CAPS Eq4p: band a = low shelf = bass, band d = high shelf =
treble). The analyser branch is left untouched:

```sh
sudo ./files/jukebox-audio.sh install --second-output usb \
     --usb-card Device_1 --usb-card-match "USB PnP" \
     --third-output spdif --spdif-card-match "DSD TECH"
```

This produces the `usbspdif` variant: `jukeboxRoute` fans out to 6 channels
(a = DAC, b = analyser, c = S/PDIF) and `jukeboxSplit`'s third slave is
`volumioSpdifVol` (`softvol` -> `jukeboxSpdifEq` Eq4p -> `jukeboxSpdif` ->
`hw:CARD=<spdif>,DEV=0`). Options: `--third-output none|spdif`,
`--spdif-card NAME`, `--spdif-card-match SUBSTR`, `--spdif-rate HZ`,
`--spdif-gain 0..1`, `--spdif-format FMT` (`JB_THIRD_OUTPUT`, `JB_SPDIF_CARD`,
`JB_SPDIF_CARD_MATCH`, `JB_SPDIF_RATE`, `JB_SPDIF_GAIN`, `JB_SPDIF_FORMAT`).

* The S/PDIF's tone is a **separate stage** (CAPS Eq4p) from the DAC's
  CamillaDSP, so its curve is close to — but not bit-identical to — the DAC's.
  `jukebox-pots` rewrites its Eq4p controls file
  (`/var/lib/jukebox-audio/spdif-eq.bin`) **live** when the tone pots move.
* **Pure direct** (SoftMaster at max, both tone stages at 0 dB) leaves the DAC
  and the S/PDIF at full level and flat.
* The S/PDIF leg is rate-pinned to `--spdif-rate` (default 48000).
* Why not simply fan a single CamillaDSP out to both outputs? The ALSA `multi`
  plugin writes two devices in lockstep; with independent clocks (the Pi's I2S
  clock vs the USB card's crystal) one leg's buffer stops draining and
  CamillaDSP aborts after 100 failed writes (`giving up after 100 write
  attempts`). And two `cdsp` slaves in one `multi` deadlock. So each output
  keeps its own processing stage.

* The third card is pinned the same way as the analyser card (name + long-name
  match), so a kernel rename does not break it. It must resolve to a card
  *different* from the analyser's (otherwise the branch is dropped).
* Fail-safe: if the S/PDIF card is missing the chain simply falls back to the
  two-branch `usb` variant; it never takes down the whole split.
* On the jukebox this is the `DSD TECH USB Audio Device` (`0d8c:0247`), which
  exposes `iec958:CARD=Device` (IEC958 / S/PDIF output), PCM 16/24-bit at
  44.1–96 kHz. It does **not** do native DSD over ALSA.
* **The two USB sound cards must be on different USB hubs.** On a Pi 4 the VL805
  controller plus a single-TT hub cannot run two full-speed isochronous streams
  at once: with both cards open the controller disables an endpoint
  (`xhci_hcd: ERROR Transfer event for disabled endpoint`) and the second card
  goes silent, even though each works alone. Put one card directly in a Pi USB
  port and the other on the external hub (different Transaction Translators);
  `lsusb -t` must show the two `Class=Audio ... 12M` entries under different
  `Hub` nodes. This is a documented Pi4 limitation (raspberrypi/linux#3962), not
  a chain bug.

## Install

From this directory (the deploy wrapper copies the package — scripts, the
engine and its binaries under `files/` — to the Pi and runs it there):

```sh
./deploy.sh install --second-output usb     # or: hdmi / jack / none
```

Or directly on the Volumio host (run the engine inside `files/`):

```sh
sudo ./files/jukebox-audio.sh install --second-output usb
```

The installer:

1. backs up the current ALSA / Volumio / MPD configuration to
   `/var/backups/jukebox-audio/<timestamp>/`,
2. replaces Volumio's `softvolume.postVolume.conf` ALSA contribution with a
   split chain (DAC branch with software volume + tone, second branch fixed
   level),
3. writes the matching `/etc/asound.conf`,
4. installs CamillaDSP and the `cdsp` ALSA plugin and writes the tone-control
   config for every variant (skipped with `--no-tone`),
5. points Volumio's volume settings at the DAC's `SoftMaster`,
6. disables MPD's own mixer and adds buffer settings so MPD opens the split
   chain reliably,
7. installs systemd units (boot guard + path watcher) and a udev rule that
   re-assert the configuration if Volumio rewrites it or the second device
   is plugged/unplugged,
8. keeps only the DAC branch active whenever the second device is missing.

A reboot is recommended after installing.

## Verify / operate

```sh
./deploy.sh verify --with-playback   # checks all the moving parts
./deploy.sh status
./deploy.sh uninstall                # restores the backups
```

`verify` checks the ALSA chain, the volume-control binding, MPD settings,
the second output state (USB card / HDMI EDID / jack level), the optional
third (S/PDIF) card, and opens the chain on every branch. With
`--with-playback` it also plays the MPD queue
briefly (at low volume) to check the real playback path; if the queue is empty
(e.g. right after a reboot) it pulls a track from the library so there is
something to play, then cleans it up — the test only fails if the audio path is
really broken, not because the queue happened to be empty.

## How it works

```
volumio -> softvolume -> jukeboxRoute -> jukeboxSplit (multi)
    |- volumioSoftVol (softvol, SoftMaster) -> jukeboxTone -> postVolume -> volumioOutput -> volumioHw (I2S DAC)
    |- jukeboxEq (analyser bass trim) -> jukeboxUsb | jukeboxHdmi | jukeboxJack             (fixed level)
    '- jukeboxSpdif                    -> jukeboxSpdif (USB S/PDIF)   [usbspdif only]
```

* The software volume (`SoftMaster`) sits **after** the split, on the DAC
  branch only, so both the Volumio UI/API and MPD move the DAC alone.
* The `softvol` is calibrated so its **top value is exactly 0 dB**, not the
  usual −0.5 dB a plain −50..0 range gives: `max_dB 0.5`, `min_dB -49.5`,
  `resolution 100` (`JB_SOFTVOL_MAX_DB` / `JB_SOFTVOL_MIN_DB` /
  `JB_SOFTVOL_RESOLUTION`). The DAC can then reach true unity gain, which the
  *pure direct* mode relies on for a bit-perfect path.
* `jukeboxTone` (the `cdsp` -> CamillaDSP tone step) sits **after** the
  software volume, so the bass/treble shelves act on the DAC signal only.
  Without the tone (`--no-tone`) it is absent and the chain is the original one.
* The second branch has no volume control at all: its level is inherently
  constant (USB/HDMI) or pinned by keeping the jack mixer at full level.
* The optional third output (`usbspdif`) is **not** a plain copy: it has its own
  `softvol` (reading the shared `SoftMaster`, so volume and balance follow the
  DAC) and its own tone stage (ALSA `equal`/CAPS Eq4p, low+high shelf). The
  analyser branch keeps no volume and no tone.
* Volumio's ALSA config generator produces `/etc/asound.conf` from plugin
  contributions. The contribution file is replaced in place, so a normal
  regeneration yields the same split chain instead of flattening it.

### Tone control (CamillaDSP + cdsp)

The DAC branch runs a low-shelf + high-shelf biquad in CamillaDSP, inserted
with the ALSA `cdsp` plugin:

* **Live changes**: `jukebox-pots` edits the two `gain:` values in the
  CamillaDSP config and sends the running process a `SIGHUP`; CamillaDSP
  reloads the config without interrupting playback (filters are rebuilt
  in place).
* **Native rate**: the plugin substitutes `$samplerate$`, `$format$` and
  `$channels$` on every open, so CamillaDSP always runs at the file's rate
  (44.1k/48k/96k/192k...). Nothing is resampled.
* **Transparent by default**: both shelves default to `0.0 dB`.
* **`chunksize: 512` is deliberate.** The `cdsp` plugin hands audio to
  CamillaDSP through a pipe; if CamillaDSP's chunk is larger than a full pipe
  the reader waits for more data than the writer will send and the player
  blocks forever in `poll()` (XRUN). 512 matches the plugin's buffer.
* The plugin source is in `cdsp/` (`libasound_module_pcm_cdsp.c` +
  `strrep.h`). It is shipped precompiled for armhf; rebuild it on the host
  with `JB_TONE_BUILD_CDSP=1 ./jukebox-audio.sh install` (needs `gcc` and
  `libasound2-dev`), or cross-compile with
  `arm-linux-gnueabihf-gcc -DPIC -std=gnu11 -O2 -fPIC -shared` (a
  `debian:bookworm` container with `gcc-arm-linux-gnueabihf` plus
  `libasound2-dev:armhf` via multiarch works too).
  Four fixes over upstream are included: exec argument lifetime (the `-f/-r/-n`
  flags used to arrive empty), CamillaDSP v4 sample-format names, an atomic
  active-config write (temp file + `rename`, forced mode `0666`) so the file
  stays writable whichever user opened the chain last (root at install time,
  `mpd` during playback), and underrun concealment: when the application stops
  feeding for more than a period the plugin feeds CamillaDSP silence instead
  of reporting a fatal XRUN, so a temporary player stall (slow storage, system
  load) cannot kill the output.
* `CamillaDSP` (v4.1.3, `camilladsp-linux-armv7.tar.gz`) is shipped as
  `camilladsp` and installed to `/usr/local/bin/`.

### Analyser bass trim

Spectrum analysers commonly over-read the deep bass because of their hardware,
so the **analyser branch only** can be trimmed with a fixed low-shelf filter.
It is off the speaker path entirely.

* Implemented with the CAPS `Eq4p` LADSPA plugin through the `alsaequal`
  `equal` ALSA plugin (`caps` + `libasound2-plugin-equal`, installed
  automatically).
* Bands `b`/`c`/`d` are disabled; band `a` is a low shelf at the corner
  frequency. `50 %` amplitude is **-6.02 dB**.
* Defaults: **60 Hz, -6.02 dB, Q 0.5**. Measured response on the live chain:

  | Hz | 20 | 30 | 40 | 50 | 60 | 80 | 100+ |
  |----|----|----|----|----|----|----|------|
  | dB | -6.3 | -6.4 | -6.1 | -4.8 | -3.0 | -0.5 | ~0 |

* The parameters are baked into a **deterministic controls file**
  (`/usr/local/jukebox-audio/analyser-eq.bin`, copied to
  `/var/lib/jukebox-audio/analyser-eq.bin`), so the filter is byte-identical
  on every install.
* Options: `--analyser-trim on|off` (`--no-analyser-trim`), `--analyser-freq HZ`,
  `--analyser-gain dB`, `--analyser-q Q`; or the matching `JB_ANALYSER_*`
  environment variables.
* The wrapper `plug` must pin `rate` + `FLOAT_LE` around `equal` (it only
  accepts float); without that the ALSA `multi` plugin fails to negotiate and
  the whole chain refuses to open.

### Fail-safe

The ALSA `multi` plugin is all-or-nothing: if one branch cannot open, the
whole chain fails (no sound at all, speakers included). Since the second
device can disappear (USB unplugged, extractor off, ...), the chain is
managed dynamically:

* second device absent -> **daconly** variant: only the DAC plays;
* second device present -> **usb** (or **hdmi**/**jack**) multi-output variant;
* second present and `--third-output spdif` with the S/PDIF card present ->
  **usbspdif** (three branches). If the S/PDIF card is missing the chain drops
  back to **usb**, never to daconly.

The decision runs at boot, on device hotplug (udev) and whenever the watched
files change. All variants are kept in `/usr/local/jukebox-audio/` and the
live one is selected automatically. `apply` re-resolves the pinned card names
each run and regenerates the canonical snippets if a card was renamed.
`JB_USB_OVERRIDE=on|off`, `JB_HDMI_OVERRIDE` or `JB_SPDIF_OVERRIDE` force the
verdict for testing.

### The config guard

Volumio regenerates `/etc/asound.conf` and the ALSA snippet from its own
templates whenever you touch its audio pages, and the device set changes on
hotplug; either would flatten the split chain (losing the analyser/S/PDIF
branches and the DAC-only volume binding). Three pieces keep it in place:

| Piece | Installed at | Role |
| --- | --- | --- |
| `jukebox-audio-guard.path` | `/etc/systemd/system/` | `PathChanged` watcher |
| `jukebox-audio-guard.service` | `/etc/systemd/system/` | `oneshot` → `jukebox-audio.sh apply --boot` |
| `89-jukebox-audio.rules` | `/etc/udev/rules.d/` | hotplug trigger |

**What it watches** (`PathChanged`, i.e. content changes, not mere reads):
`/etc/asound.conf`, the Volumio snippet `softvolume.postVolume.conf` and
`special_cards_config.json`. **udev** additionally restarts the guard service on
an HDMI DRM change (`card*-HDMI-A-*`, the phantom HDMI output) and on any sound
card add/remove (analyser / S/PDIF replug). The `.service` is `enabled`, so the
chain is also re-asserted at every boot, after `alsa-restore.service`.

**What `apply` does**, each run:

1. waits 2 s, loads `config.env`, detects the cards;
2. re-resolves the pinned card names and **regenerates the canonical snippets**
   if the kernel renamed a USB card (`Device` <-> `Device_1`);
3. refreshes the analyser controls file (`analyser-eq.bin`) if it changed;
4. computes the **desired** variant (`variant_for_now`: usbspdif/usb/daconly…)
   against the **live** one and, if they differ, rewrites `/etc/asound.conf` and
   the snippet from the canonical copies in `/usr/local/jukebox-audio/`;
5. re-asserts `mpd.conf`, `special_cards_config.json`, Volumio's `config.json`,
   the jack level and the `SoftMaster` elements, and cleans stale kernel
   controls;
6. restarts MPD — and Volumio only if its config changed — **only if something
   changed**, non-blocking, throttled to at most one Volumio restart every
   `VOLUMIO_RESTART_MIN_INTERVAL` (300 s) via a stamp in
   `/run/jukebox-audio-volumio-restart`.

**What it does *not* touch** (so it never fights the accessories):

* the CamillaDSP configs — the **tone** and **pure direct** changes from
  `jukebox-pots` persist across guard runs;
* the analyser card's hardware `PCM` control — the **spectrum** switch;
* the *value* of `SoftMaster` — the guard only ensures the element exists;
  `alsa-restore` and `jukebox-pots` set the value.

It *does* own the `softvol` calibration (the exact-0 dB top), since that lives in
the canonical snippet.

> **Don't hand-edit** `/etc/asound.conf` or the snippet: the guard reverts them.
> Edit the canonical copy in `/usr/local/jukebox-audio/` and run `apply`, or
> reinstall. To experiment, stop the watcher first:
>
> ```sh
> sudo systemctl stop jukebox-audio-guard.path    # ... then start it again
> ```

**Debugging:**

```sh
systemctl status jukebox-audio-guard.path
journalctl -u jukebox-audio-guard -n 50
tail -n 50 /var/log/jukebox-audio.log   # apply leaves a trace here
```

The other packages repeat the same pattern (`jukebox-ui-guard`,
`jukebox-overlay-guard`, the `ui-nav` guard), each restoring from its own
canonical copy under `/usr/local/jukebox-*/`.

## Notes and caveats

* Cards are auto-detected (`sndrpirpidac` as DAC, the extra USB card as the
  second output). Override with `JB_DAC_CARD=`, `JB_JACK_CARD=`,
  `JB_HDMI_CARD=`, `JB_USB_CARD=`. With more than one USB card, also set
  `JB_USB_CARD_MATCH="<substring of the long name>"` (or `--usb-card-match`) so
  the analyser branch cannot be stolen by a newly added card.
* The optional third output is `JB_THIRD_OUTPUT=none|spdif` with
  `JB_SPDIF_CARD`, `JB_SPDIF_CARD_MATCH`, `JB_SPDIF_RATE`, `JB_SPDIF_GAIN`,
  `JB_SPDIF_FORMAT` (or the `--third-output` / `--spdif-card` /
  `--spdif-card-match` / `--spdif-rate` / `--spdif-gain` / `--spdif-format`
  flags). It requires `--second-output usb`. Its tone (CAPS Eq4p) is driven by
  `jukebox-pots` via `/var/lib/jukebox-audio/spdif-eq.bin`.
* USB/HDMI/S-PDIF sample rate is `48000` by default (`JB_USB_RATE`,
  `JB_HDMI_RATE`, `JB_SPDIF_RATE`).
* Jack reference level is `0 dB` (`JB_JACK_LEVEL` / `JB_JACK_LEVEL_RAW`).
* Analyser bass trim defaults to `on` at `60 Hz / -6.02 dB / Q 0.5`
  (`JB_ANALYSER_TRIM`, `JB_ANALYSER_FREQ_HZ`, `JB_ANALYSER_GAIN_DB`,
  `JB_ANALYSER_Q`). Set `--no-analyser-trim` for a transparent second branch.
* Tone control defaults to `on` at `120 Hz` (bass) / `6000 Hz` (treble),
  `Q 0.7` (`JB_TONE`, `JB_TONE_BASS_FREQ`, `JB_TONE_TREBLE_FREQ`,
  `JB_TONE_Q`). `--no-tone` removes the CamillaDSP step entirely. The gains
  themselves are owned by `jukebox-pots` (see that package).
* The `multi` chain needs `buffer_time`/`period_time` in MPD (installed via
  Volumio's `special_cards_config.json`); without them MPD may refuse to
  open the chain. The buffer is deliberately large (`3000000` us = 3 s,
  period `50000` us): it absorbs player stalls (slow SD card, load spikes)
  so the DAC branch never starves. Even longer stalls are concealed by the
  plugin's silence feed (see above).
* `/var/lib/jukebox-audio` is kept world-writable (`0777`): MPD's `cdsp`
  plugin (unprivileged) rewrites CamillaDSP's active config there on every
  open, and `jukebox-pots` edits it too. The active config itself is written
  atomically (temp file + `rename`) and forced to `0666`, so a root-created
  copy (install/verify opens the chain as root) can never block `mpd`; the
  installer/guard also re-asserts `0666` with `fix_active_perms`. The tone
  templates under `/usr/local/jukebox-audio/cdsp/` are `0644`.
* **Analysers:** the tone acts on the DAC branch only. The spectrum analyser
  feed keeps the fixed-level signal (and its own bass trim).
* **HDMI caveat:** on this Pi, activating an HDMI output can take over the
  DRM/KMS display configuration and stop the DSI touch screen
  (`touch_display` plugin). Use `--second-output usb` if you need the touch
  screen.
* Uninstall restores the most recent backup
  (`/var/backups/jukebox-audio/latest`).
* **Re-running `install` does not poison the backup.** The restore point is
  captured only from a *clean* (not yet jukebox-managed) configuration: once the
  live ALSA files carry the jukebox markers, a re-install keeps the existing
  backup instead of overwriting it with an already-managed state. If a backup
  file is itself a managed state (from an old installer version) `uninstall`
  does not restore it; it removes the managed file and lets Volumio regenerate
  its own configuration.

## Layout

```
deploy.sh                   # scripts (repo root): ship the package + run it over SSH
uninstall.sh                # thin wrapper around the engine's uninstall mode
README.md                   # this file
files/                      # everything that lands on the host
  jukebox-audio.sh          # installer / verify / status / apply / uninstall (engine)
  jukebox-audio-guard.service / .path  # systemd guard units
  89-jukebox-audio.rules    # udev rule (HDMI/USB hotplug)
  camilladsp                # CamillaDSP v4.1.3, armv7 build (precompiled)
  libasound_module_pcm_cdsp.so  # cdsp ALSA plugin, armhf (precompiled)
  cdsp/
    libasound_module_pcm_cdsp.c  # plugin source (patched: see "Tone control")
    strrep.h                # substring-replace helper used by the plugin
```
