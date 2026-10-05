# jukebox

A homemade jukebox built around a **Raspberry Pi 4B** running
[Volumio](https://volumio.com/): firmware
for power control and input reading (potentiometers, switches and a 4x4 button
matrix) on **Arduino Micro (ATmega32U4)** boards, FreeCAD 3D models of the
hardware (screen, Raspberry Pi, HDD and electronics supports), the audio
software that gives the Pi a custom dual output, and the operations skill used
to run and troubleshoot the box.

## Status

The repository currently contains:

```
firmware/PowerAndPotsArduino/   # PlatformIO project (Arduino Micro)
├── src/main.cpp                # pot/switch reading and serial reporting
├── src/power-state-machine.hpp # relay + short/long press power switch logic
├── platformio.ini
└── README.md                   # detailed firmware documentation

firmware/KeyboardArduino/       # PlatformIO project (Arduino Micro)
├── src/main.cpp                # 4x4 button matrix scan and event reporting
├── platformio.ini
└── README.md                   # detailed firmware documentation

hardware/3d-models/             # FreeCAD models, grouped by part
├── Electronic support/         # PowerAndPots controller board, box, fuse case
├── hdd/                        # hard drive wall support
├── Pi support/                 # Raspberry Pi support
├── screen/                     # screen supports, cover and joints
└── Spectrum/                   # spectrum display frame

software/volumio/              # Volumio flavour (the live box)
├── dual-output/                # custom dual audio output for Volumio
│   ├── deploy.sh / uninstall.sh  # scripts: ship+run over SSH, thin uninstall
│   ├── files/                  # everything that lands on the Pi
│   │   ├── jukebox-audio.sh    # installer / verify / status (engine)
│   │   ├── camilladsp          # CamillaDSP v4.1.3 (armv7), tone-control engine
│   │   ├── libasound_module_pcm_cdsp.so  # cdsp ALSA plugin (armhf, patched)
│   │   ├── cdsp/               # plugin source (patched) + strrep.h
│   │   └── jukebox-audio-guard.* / 89-jukebox-audio.rules  # units + udev rule
│   └── README.md               # design doc: ALSA split, tone, variants, fail-safe
├── pot-overlay/                # on-screen indicator for balance/bass/treble
│   ├── install.sh / uninstall.sh / deploy.sh  # scripts
│   └── files/                  # everything that lands on the Pi
│       ├── jukebox-overlay.py  # dependency-free HTTP/SSE server (port 3210)
│       ├── overlay.js / overlay.css  # UI overlay (reuses Volumio's knob)
│       ├── apply.sh            # (re)inject the loader into the UI pages
│       └── uninject.py         # strip the loader on uninstall
├── ui-nav/                     # daemon -> UI screen navigation channel
│   ├── install.sh / uninstall.sh / deploy.sh  # scripts
│   └── files/                  # everything that lands on the Pi
│       ├── ui-nav.py           # dependency-free HTTP/SSE server (port 3211)
│       ├── ui-nav.js           # injected client; drives the UI's $state
│       ├── apply.sh            # (re)inject the loader into the UI pages
│       └── uninject.py         # strip the loader on uninstall
└── ui-boost/                   # touch UI performance kit for Volumio
    ├── install.sh / uninstall.sh / deploy.sh  # scripts
    └── files/                  # everything that lands on the Pi
        └── jukebox-ui.sh / jukebox-ui-guard.*  # helper + guard units

software/jukebox-pots/          # pot volume/balance/tone from the Arduino
├── install.sh / uninstall.sh / deploy.sh  # scripts
├── files/                      # everything that lands on the Pi
│   ├── jukebox-pots.py         # daemon: USB serial -> DAC volume/balance/tone
│   └── jukebox-pots.service / 89-jukebox-pots.rules / config.env.in
└── README.md                   # design doc: mapping, detection, analyser safety

software/jukebox-keyboard/      # playback keys from the KeyboardArduino
├── install.sh / uninstall.sh / deploy.sh  # scripts
├── files/                      # everything that lands on the Pi
│   ├── jukebox-keyboard.py     # daemon: USB serial -> play/pause/stop/prev/next
│   └── jukebox-keyboard.service / 89-jukebox-keyboard.rules / config.env.in
└── README.md                   # design doc: key map, detection

skills/jukebox/SKILL.md         # agent skill to operate and troubleshoot the box
```

The audio setup splits playback into the I2S DAC (speakers, volume-controlled
by Volumio) and a second constant-level output feeding a hardware spectrum
analyser, with an automatic DAC-only fallback when the second device is absent.
The DAC branch also carries a live **bass/treble tone control** (CamillaDSP),
driven by two of the Arduino's potentiometers — see
[Installing from scratch](#installing-from-scratch).

## Physical controls

Four potentiometers of the PowerAndPots Arduino drive the DAC (speakers) only:

| Pot | Function |
| --- | --- |
| `POT volume` | Volumio volume (0–100 %) |
| `POT balance` | left/right balance of the DAC |
| `POT single` | bass shelf (±8 dB, center = flat) |
| `POT multi second` | treble shelf (±8 dB, center = flat) |

The spectrum analyser feed keeps its constant level and is not affected by any
of them (including the tone). See
[software/jukebox-pots/README.md](software/jukebox-pots/README.md).

## Firmware

- **Power relay** driven by a state machine: short press turns it on, short
  press while on asks the host to shut down (`POWER: soft off`), long press
  (≥ 5 s) performs an immediate hard off; the button acts on release. The relay
  is cut by the Arduino after the Pi has halted (see
  [Power button](software/jukebox-pots/README.md#power-button-soft-power-off)).
- **Serial reporting** (9600 baud, only on change): volume/single/balance/
  multi second pots (with per-segment calibration tables), power tristate,
  power switch, multi push and rotary switch.
- **Button matrix** (4x4, rows on 2-5, columns on 6-9): `DOWN`/`UP` on
  press/release, `PRESS` vs `LONG_PRESS` (1 s threshold) on release and a
  `PRESSED` repeat every 500 ms while held.

Pin map, output format, calibration and flashing: see
[firmware/PowerAndPotsArduino/README.md](firmware/PowerAndPotsArduino/README.md);
button matrix wiring and events: see
[firmware/KeyboardArduino/README.md](firmware/KeyboardArduino/README.md).

## 3D models

FreeCAD (`.FCStd`) models, grouped by part: see
[hardware/3d-models/README.md](hardware/3d-models/README.md).
No STL/STEP exports are committed yet — export from FreeCAD as needed.

## Audio software

Custom dual audio output (I2S DAC + constant-level second output for the
spectrum analyser) with a live bass/treble tone control, for **Volumio**.
Step-by-step, from scratch: see
[Installing from scratch](#installing-from-scratch).

See the full design doc:
[software/volumio/dual-output/README.md](software/volumio/dual-output/README.md)
(engine `files/jukebox-audio.sh`, shipped over SSH by `deploy.sh`).

Physical volume and balance from the PowerAndPots Arduino's potentiometers are
handled by `software/jukebox-pots/` (`jukebox-pots.service`): it reads `POT
volume` / `POT balance` / `POT single` / `POT multi second` over USB serial and
drives the DAC volume, balance and tone, leaving the analyser output untouched.
Install with `software/jukebox-pots/deploy.sh install`; see its
[README](software/jukebox-pots/README.md).

Moving a pot shows an on-screen indicator (a circular knob identical to
Volumio's own volume indicator) for **balance**, **bass** and **treble** — the
latter two are not part of Volumio's state, so `software/volumio/pot-overlay`
adds a small local SSE server that the daemon feeds and the UI renders; see its
[README](software/volumio/pot-overlay/README.md).

## Keyboard (playback keys)

The KeyboardArduino's 4x4 button matrix drives playback. `software/jukebox-keyboard/`
(`jukebox-keyboard.service`) reads its key events over USB serial and runs the
matching Volumio command on key **press**: play, pause, stop, previous track,
next track, mute, clear the queue and save the queue as a playlist. One key
toggles the current track/station in **favourites**, and one can **toggle the
screen** between the now-playing home and the play queue (those two ask the UI,
so they need `software/volumio/ui-nav`). The key → action map is **versioned in
the repo** at `software/jukebox-keyboard/files/keymap.conf` (`ACTION=row,col`) and
installed as-is, so a fresh or re-installed box gets the same keys (a one-off
`--key-action ACTION ROW,COL` overrides single entries). Identify a key with
`--watch`. Install with `software/jukebox-keyboard/deploy.sh install`; see its
[README](software/jukebox-keyboard/README.md).

## Adding music over the network (SMB)

Volumio already runs Samba (`smbd`/`nmbd`) with **guest** shares, so you don't
need to touch the box at all — just drag files onto it from your computer. The
Pi advertises itself on the LAN under **its own hostname**, so it shows up on its
own under the network neighbourhood / "Network" in your file manager.

### From the file manager (no password)

- **Windows / File Explorer** — open **Network**; the box appears there by
  itself (if it doesn't, type `\\<host>` — or `\\<pi-ip>` — in the address bar).
- **macOS / Finder** — **Go ▸ Connect to Server…** (`⌘K`) and enter
  `smb://<host>` (or `smb://<pi-ip>`).
- **Linux / GNOME Files (Nautilus)** — **Other Locations ▸ smb://<host>**.

| Share | What it is | Where it lands on the Pi |
|---|---|---|
| `Internal Storage` | the built-in disk: this is where music normally goes | `/data/INTERNAL` → `Music/` |
| `USB` | whatever USB drive is plugged into the Pi | `/mnt/USB` |
| `NAS` | a staging area for files destined for a NAS | `/mnt/NAS` |

There is **no username or password** (the shares are `guest ok = yes`); connect
as guest/anonymous and open the share you want. For permanent music on this box
use **`Internal Storage`** and drop the files in the **`Music`** folder, i.e.
`Internal Storage\Music\...`. The library shows every folder under the MPD music
root, so anything you place in there is indexed.

### From the command line

```sh
# Linux (mount at /mnt/jukebox; the share name has a space)
sudo mkdir -p /mnt/jukebox
sudo mount -t cifs '//<host>/Internal Storage' /mnt/jukebox \
  -o guest,iocharset=utf8,file_mode=0777,dir_mode=0777
cp -r ~/Music/* /mnt/jukebox/Music/
sudo umount /mnt/jukebox

# macOS
open 'smb://<host>/Internal%20Storage'

# smbclient (guest, one-off copy)
smbclient '//<host>/Internal Storage' -N -c 'cd Music; lcd ~/Music; mput *'
```

### After copying: re-scan the library

Volumio's MPD watches its folders but a full (re)scan is the reliable way to
make new files appear. In the web UI: **Browse ▸ My Music ▸ Update** (or
Settings ▸ Sources). The button posts MPD's database update, and from the
command line `mpc` talks to the same daemon:

```sh
mpc update      # incremental: pick up new/changed files
mpc rescan      # full re-read of the whole library
```

> Volumio's REST API does **not** expose `updateLibrary`/`rescan` (the UI uses a
> socket), so `curl '.../api/v1/commands/?cmd=updateLibrary'` answers *command
> not recognized* — use `mpc`, the UI button, or just wait for MPD to notice.
> A file only becomes playable once MPD has it in its database, so if the UI
> lists the file but playback fails or it's missing, run `mpc update`.

## Installing from scratch

Everything below runs from a **development machine** (this repo) and drives the
Pi over SSH. Nothing is hardcoded: pass the host (and a password if you don't
use SSH keys) per command.

Requirements:

* A Raspberry Pi with the I2S DAC (PCM1794A, `sndrpirpidac`) and, for the
  analyser, a USB sound card (`Device`).
* The **PowerAndPots Arduino** flashed
  ([firmware/PowerAndPotsArduino](firmware/PowerAndPotsArduino/README.md)) and
  plugged in (it appears as `/dev/ttyACM0`).
* SSH enabled on the Pi. Either an SSH key or the `-p/--password` option (the
  password is also needed for `sudo` unless it is passwordless).

The order matters: **player first, then the audio chain, then the pots.**

There is also a top-level wrapper that drives all six packages in that order:

```sh
./deploy-all.sh -H user@host install     # every package; second output = usb
./deploy-all.sh -H user@host verify      # run every package's checks
./deploy-all.sh -H user@host status      # show every package's state
./deploy-all.sh -H user@host uninstall   # remove every package (reverse order)
```

The host is **required**: pass `-H/--host user@host` or set `JUKEBOX_HOST`
(there is no built-in default). Use `-p <password>` (or `$JUKEBOX_PASSWORD`) when
`sudo` on the box needs one:

```sh
./deploy-all.sh -H volumio@<host> -p <pass> install
./deploy-all.sh -H volumio@<host> status
```

It just sequences each package's own `deploy.sh`, so the per-package steps below
are the same thing done by hand (and are still the way to pass package-specific
options such as `--key-action`). For this box, `install` fixes the second output
to `usb`. The pot power button (short press halts the Pi) is on by default;
disable it per package with `--no-power-button`:

```sh
# one package at a time (same effect as the orchestrator, with its own flags)
software/volumio/dual-output/deploy.sh  -H volumio@<host> -p <pass> install --second-output usb
software/volumio/ui-boost/deploy.sh     -H volumio@<host> -p <pass> install
software/jukebox-pots/deploy.sh         -H volumio@<host> -p <pass> install --power-off-delay 45
software/volumio/pot-overlay/deploy.sh  -H volumio@<host> -p <pass> install
software/volumio/ui-nav/deploy.sh       -H volumio@<host> -p <pass> install
software/jukebox-keyboard/deploy.sh     -H volumio@<host> -p <pass> install --key-action next 1,4
```

### Volumio (the live box)

1. Flash Volumio and finish its first-run wizard (network, audio output).
   Note the host and the `volumio` user's password.

2. Install the dual output + tone (DAC branch + constant-level USB analyser;
   the tone engine CamillaDSP and the patched `cdsp` plugin are shipped by this
   repo):

   ```sh
   cd software/volumio/dual-output
   ./deploy.sh --host volumio@<host> install --second-output usb
   ```

   Add `--with-playback` to also run the playback check. On a Volumio box the
   installer configures the ALSA split, the MPD buffers, the guard units and
   the CamillaDSP tone step, and ends with a verification table that must say
   **All checks passed**.

3. Install the potentiometer daemon (volume, balance, bass, treble). The pot
   power button (short press halts the Pi, relay cut ~30 s later) is on by
   default; `--no-power-button` / `--power-off-delay N` change that:

   ```sh
   cd software/jukebox-pots
   ./deploy.sh --host volumio@<host> install                       # power button on, 30 s
   ./deploy.sh --host volumio@<host> install --no-power-button     # short press does nothing
   ./deploy.sh --host volumio@<host> install --power-off-delay 45  # cut the relay after 45 s
   ```

   Then, for the on-screen indicator when moving balance/bass/treble pots:

   ```sh
   cd software/volumio/pot-overlay
   ./deploy.sh --host volumio@<host> install
   ```

4. *(Optional)* Speed up the touch UI (GPU compositing, no blur, correct DSI
   resolution):

   ```sh
   cd software/volumio/ui-boost
   ./deploy.sh --host volumio@<host> install
   ./deploy.sh --host volumio@<host> status
   ```

   It takes full effect after a reboot (`ssh volumio@<host> 'sudo reboot'`).

5. *(Optional)* Wire the keyboard's playback keys. The map is versioned in
   `software/jukebox-keyboard/files/keymap.conf`; install it as-is (identify a
   key with `--watch` and edit the file if needed):

   ```sh
   cd software/jukebox-keyboard
   ./deploy.sh --host volumio@<host> install
   ```

   A one-off `--key-action ACTION ROW,COL` (repeatable) overrides single entries
   without touching the repo.

6. **Reboot** so `alsa-restore`, the guard units and the pot daemon come up
   together, then play something and move the four pots.

Verification / state any time (all packages at once, or a single one):

```sh
./deploy-all.sh -H volumio@<host> verify                # every package
./deploy-all.sh -H volumio@<host> status                # every package
./software/volumio/dual-output/deploy.sh --host volumio@<host> verify --with-playback
./software/jukebox-pots/deploy.sh --host volumio@<host> status
```

If `sudo` on the box needs a password, add `-p <password>` or export
`JUKEBOX_PASSWORD=<password>`.

### What each installer does

| Package | What it installs |
|---|---|
| `software/volumio/dual-output` | ALSA split + CamillaDSP tone step + guards + MPD buffers for Volumio |
| `software/volumio/pot-overlay` | On-screen balance/bass/treble indicator (overlay server + injected UI loader) |
| `software/volumio/ui-nav` | UI navigation channel (a daemon can switch the screen; used by the open/close key) |
| `software/jukebox-pots` | `jukebox-pots.service` (volume/balance/tone from the Arduino; power button halts the Pi, on by default) |
| `software/jukebox-keyboard` | `jukebox-keyboard.service` (play/pause/stop/prev/next/mute/clear/save-queue, favourite, open/close the queue view) |
| `software/volumio/ui-boost` | Volumio-only touch UI performance fixes |

## Safety notice

This project drives a power relay (low-voltage control side) and includes
parts meant to be printed and assembled with electronic and electrical
components. In this build the relay switches a PC **ATX power supply**, so the
relay contacts are low voltage — but the PSU still has mains at its input, and
an ATX supply carries high currents and stored energy. Handle it with the usual
care for electrical work; a supply can still get hot or hold a charge. None of
it is a certified or safety-rated design. Use it entirely at your own risk;
if you are not comfortable working with electronics or mains wiring, don't —
consult a professional.

## License

MIT, plus an additional disclaimer of liability and safety notice — see
[LICENSE](LICENSE). The project is provided "as is", with no warranty and no
responsibility for any damage or injury arising from its use.
