# jukebox dual output (Volumio + Raspberry Pi)

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
fallback** and switches to the full dual chain automatically when the device
appears (udev handles hotplug).

## Install

From this directory (the script copies itself to the Pi and runs it there):

```sh
./deploy.sh install --second-output usb     # or: hdmi / jack / none
```

Or directly on the Volumio host:

```sh
sudo ./jukebox-audio.sh install --second-output usb
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
the second output state (USB card / HDMI EDID / jack level) and opens the
chain on both outputs. With `--with-playback` it also plays the current MPD
queue briefly (at low volume) to check the real playback path.

## How it works

```
volumio -> softvolume -> jukeboxRoute -> jukeboxSplit (multi)
    |- volumioSoftVol (softvol, SoftMaster) -> jukeboxTone -> postVolume -> volumioOutput -> volumioHw (I2S DAC)
    '- jukeboxEq (analyser bass trim) -> jukeboxUsb | jukeboxHdmi | jukeboxJack             (fixed level)
```

* The software volume (`SoftMaster`) sits **after** the split, on the DAC
  branch only, so both the Volumio UI/API and MPD move the DAC alone.
* `jukeboxTone` (the `cdsp` -> CamillaDSP tone step) sits **after** the
  software volume, so the bass/treble shelves act on the DAC signal only.
  Without the tone (`--no-tone`) it is absent and the chain is the original one.
* The second branch has no volume control at all: its level is inherently
  constant (USB/HDMI) or pinned by keeping the jack mixer at full level.
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
  `arm-linux-gnueabihf-gcc -DPIC -std=gnu11 -O2 -fPIC -shared`.
  Two fixes over upstream are included: exec argument lifetime (the `-f/-r/-n`
  flags used to arrive empty) and CamillaDSP v4 sample-format names.
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
* second device present -> full dual-output variant.

The decision runs at boot, on device hotplug (udev) and whenever the watched
files change. All variants are kept in `/usr/local/jukebox-audio/` and the
live one is selected automatically. `JB_USB_OVERRIDE=on|off` (or
`JB_HDMI_OVERRIDE`) force the verdict for testing.

## Notes and caveats

* Cards are auto-detected (`sndrpirpidac` as DAC, the extra USB card as the
  second output). Override with `JB_DAC_CARD=`, `JB_JACK_CARD=`,
  `JB_HDMI_CARD=`, `JB_USB_CARD=`.
* USB/HDMI sample rate is `48000` by default (`JB_USB_RATE` / `JB_HDMI_RATE`).
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
  open the chain.
* `/var/lib/jukebox-audio` is kept world-writable (`0777`): MPD's `cdsp`
  plugin (unprivileged) rewrites CamillaDSP's active config there on every
  open, and `jukebox-pots` edits it too. The tone templates under
  `/usr/local/jukebox-audio/cdsp/` are `0644`.
* **Analysers:** the tone acts on the DAC branch only. The spectrum analyser
  feed keeps the fixed-level signal (and its own bass trim).
* **HDMI caveat:** on this Pi, activating an HDMI output can take over the
  DRM/KMS display configuration and stop the DSI touch screen
  (`touch_display` plugin). Use `--second-output usb` if you need the touch
  screen.
* Uninstall restores the most recent backup
  (`/var/backups/jukebox-audio/latest`).

## Layout

```
jukebox-audio.sh                # installer / verify / status / apply (runs on the Pi)
deploy.sh                       # ship and run it over SSH (with the binaries)
camilladsp                      # CamillaDSP v4.1.3, armv7 build (precompiled)
libasound_module_pcm_cdsp.so    # cdsp ALSA plugin, armhf (precompiled)
cdsp/
  libasound_module_pcm_cdsp.c   # plugin source (patched: see "Tone control")
  strrep.h                      # substring-replace helper used by the plugin
README.md                       # this file
```
