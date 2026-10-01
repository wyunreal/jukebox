# jukebox dual output (Volumio + Raspberry Pi)

Adds a second, **constant-level** audio output while keeping the I2S DAC as
the main, volume-controlled output.

What you get:

| Output | Level |
| --- | --- |
| I2S DAC (speakers) | controlled by the normal Volumio volume slider / API / MPD |
| Second output (spectrum analyser) | constant level; not affected by volume |

Both outputs always play the same stream, simultaneously.

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
   split chain (DAC branch with software volume, second branch fixed level),
3. writes the matching `/etc/asound.conf`,
4. points Volumio's volume settings at the DAC's `SoftMaster`,
5. disables MPD's own mixer and adds buffer settings so MPD opens the split
   chain reliably,
6. installs systemd units (boot guard + path watcher) and a udev rule that
   re-assert the configuration if Volumio rewrites it or the second device
   is plugged/unplugged,
7. keeps only the DAC branch active whenever the second device is missing.

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
    |- volumioSoftVol (softvol, SoftMaster) -> postVolume -> volumioOutput -> volumioHw   (I2S DAC)
    '- jukeboxEq (analyser bass trim) -> jukeboxUsb | jukeboxHdmi | jukeboxJack            (fixed level)
```

* The software volume (`SoftMaster`) sits **after** the split, on the DAC
  branch only, so both the Volumio UI/API and MPD move the DAC alone.
* The second branch has no volume control at all: its level is inherently
  constant (USB/HDMI) or pinned by keeping the jack mixer at full level.
* Volumio's ALSA config generator produces `/etc/asound.conf` from plugin
  contributions. The contribution file is replaced in place, so a normal
  regeneration yields the same split chain instead of flattening it.

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
* The `multi` chain needs `buffer_time`/`period_time` in MPD (installed via
  Volumio's `special_cards_config.json`); without them MPD may refuse to
  open the chain.
* **HDMI caveat:** on this Pi, activating an HDMI output can take over the
  DRM/KMS display configuration and stop the DSI touch screen
  (`touch_display` plugin). Use `--second-output usb` if you need the touch
  screen.
* Uninstall restores the most recent backup
  (`/var/backups/jukebox-audio/latest`).
