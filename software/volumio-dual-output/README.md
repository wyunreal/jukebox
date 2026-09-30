# jukebox dual output (Volumio + Raspberry Pi)

Adds a second, **constant-level** audio output on the Raspberry Pi 3.5 mm
jack while keeping the I2S DAC as the main, volume-controlled output.

What you get:

| Output | Level |
| --- | --- |
| I2S DAC (speakers) | controlled by the normal Volumio volume slider / API / MPD |
| 3.5 mm jack (spectrum analyser) | constant, full level; not affected by volume |

Both outputs always play the same stream, simultaneously.

## Install

From this directory (the script copies itself to the Pi and runs it there):

```sh
./deploy.sh install
```

Or directly on the Volumio host:

```sh
sudo ./jukebox-audio.sh install
```

The installer:

1. backs up the current ALSA / Volumio / MPD configuration to
   `/var/backups/jukebox-audio/<timestamp>/`,
2. replaces Volumio's `softvolume.postVolume.conf` ALSA contribution with a
   split chain (DAC branch with software volume, jack branch fixed),
3. writes the matching `/etc/asound.conf`,
4. points Volumio's volume settings at the DAC's `SoftMaster`,
5. disables MPD's own mixer and adds buffer settings so MPD opens the split
   chain reliably,
6. installs two systemd units that re-assert the configuration if Volumio
   rewrites it from its UI,
7. sets the jack level to `0 dB` and stores the ALSA state (so the level and
   the volume control come back after every reboot).

A reboot is recommended after installing.

## Verify / operate

```sh
./deploy.sh verify --with-playback   # checks all the moving parts
./deploy.sh status
./deploy.sh uninstall                # restores the backups
```

`verify` checks the ALSA snippet, `/etc/asound.conf`, the volume control
binding, MPD's mixer/buffer settings, the stored jack level and opens the
chain on both outputs. With `--with-playback` it also plays the current MPD
queue briefly (at low volume) to check the real playback path.

## How it works

```
volumio -> softvolume -> jukeboxRoute -> jukeboxSplit (multi)
    |- volumioSoftVol (softvol) -> postVolume -> volumioOutput -> volumioHw   (I2S DAC)
    '- jukeboxJack                                                           (3.5 mm jack)
```

* The software volume (`SoftMaster`) sits **after** the split, on the DAC
  branch only, so both the Volumio UI/API and MPD move the DAC alone.
* The jack branch has no volume control; its hardware mixer (`PCM`) is kept
  at full level.
* Volumio's ALSA config generator produces `/etc/asound.conf` from plugin
  contributions. The contribution file is replaced in place, so a normal
  regeneration yields the same split chain instead of flattening it.

## Notes and caveats

* The card names are auto-detected (`sndrpirpidac` / `Headphones`); override
  with `JB_DAC_CARD=` / `JB_JACK_CARD=` if your hardware differs.
* Jack reference level is `0 dB` (`JB_JACK_LEVEL` / `JB_JACK_LEVEL_RAW` to
  change it).
* On first boot after installing, everything needed is restored by
  `alsa-restore.service` plus the guard unit; nothing else to do.
* Uninstall restores the most recent backup (`/var/backups/jukebox-audio/latest`).
