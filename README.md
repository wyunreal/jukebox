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
│   ├── jukebox-audio.sh        # installer / verify / status (runs on the Pi)
│   ├── deploy.sh               # ship and run the installer over SSH
│   ├── camilladsp              # CamillaDSP v4.1.3 (armv7), tone-control engine
│   ├── libasound_module_pcm_cdsp.so  # cdsp ALSA plugin (armhf, patched)
│   ├── cdsp/                   # plugin source (patched) + strrep.h
│   └── README.md               # design doc: ALSA split, tone, variants, fail-safe
├── pot-overlay/                # on-screen indicator for balance/bass/treble
│   ├── jukebox-overlay.py      # dependency-free HTTP/SSE server (port 3210)
│   ├── overlay.js / overlay.css  # UI overlay (reuses Volumio's knob)
│   ├── apply.sh                # (re)inject the loader into the UI pages
│   ├── install.sh / deploy.sh  # installer + SSH wrapper
│   └── README.md               # design doc: how the overlay is wired
├── ui-nav/                     # daemon -> UI screen navigation channel
│   ├── ui-nav.py               # dependency-free HTTP/SSE server (port 3211)
│   ├── ui-nav.js               # injected client; drives the UI's $state
│   ├── apply.sh                # (re)inject the loader into the UI pages
│   ├── install.sh / deploy.sh  # installer + SSH wrapper
│   └── README.md               # design doc
└── ui-boost/                   # touch UI performance kit for Volumio

software/jukebox-pots/          # pot volume/balance/tone from the Arduino
├── jukebox-pots.py             # daemon: USB serial -> DAC volume/balance/tone
├── install.sh                  # idempotent installer (Volumio)
├── deploy.sh                   # ship and run the installer over SSH
└── README.md                   # design doc: mapping, detection, analyser safety

software/jukebox-keyboard/      # playback keys from the KeyboardArduino
├── jukebox-keyboard.py         # daemon: USB serial -> play/pause/stop/prev/next
├── install.sh                  # idempotent installer (Volumio)
├── deploy.sh                   # ship and run the installer over SSH
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

- **Power relay** driven by a state machine: short press turns it on,
  long press (≥ 5 s) performs a hard off; the button acts on release.
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
(installer `jukebox-audio.sh`, shipped over SSH by `deploy.sh`).

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
next track and mute. One key toggles the current track/station in **favourites**,
and one can **toggle the screen** between the now-playing home and the play queue
(that one asks the UI, so it needs `software/volumio/ui-nav`). The key → action
map lives in its `config.env` (`JK_KEY_<action>=row,col`); identify a key with
`--watch`. Install with
`software/jukebox-keyboard/deploy.sh install --key-action play ROW,COL ...`; see
its [README](software/jukebox-keyboard/README.md).

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

3. Install the potentiometer daemon (volume, balance, bass, treble):

   ```sh
   cd software/jukebox-pots
   ./deploy.sh --host volumio@<host> install
   ```

   Then, for the on-screen indicator when moving balance/bass/treble pots:

   ```sh
   cd software/volumio/pot-overlay
   ./deploy.sh --host volumio@<host> install
   ```

4. *(Optional)* Speed up the touch UI (GPU compositing, no blur, correct DSI
   resolution). This one runs on the Pi itself:

   ```sh
   cd software/volumio/ui-boost
   scp install.sh jukebox-ui.sh jukebox-ui-guard.service jukebox-ui-guard.path \
       volumio@<host>:/tmp/
   ssh volumio@<host> 'cd /tmp && sudo bash install.sh'
   ssh volumio@<host> 'sudo reboot'
   ```

5. *(Optional)* Wire the keyboard's playback keys. Identify each key with
   `--watch` (press it and note the `row,col`) and assign the actions:

   ```sh
   cd software/jukebox-keyboard
   ./deploy.sh --host volumio@<host> install \
       --key-action play 3,3 --key-action pause 4,2 --key-action stop 3,1 \
       --key-action prev 2,3 --key-action next 1,4
   ```

6. **Reboot** so `alsa-restore`, the guard units and the pot daemon come up
   together, then play something and move the four pots.

Verification any time:

```sh
./software/volumio/dual-output/deploy.sh --host volumio@<host> verify --with-playback
./software/jukebox-pots/deploy.sh --host volumio@<host> verify
./software/jukebox-keyboard/deploy.sh --host volumio@<host> verify
```

If `sudo` on the box needs a password, add `-p <password>` or export
`JUKEBOX_PASSWORD=<password>`.

### What each installer does

| Package | What it installs |
|---|---|
| `software/volumio/dual-output` | ALSA split + CamillaDSP tone step + guards + MPD buffers for Volumio |
| `software/volumio/pot-overlay` | On-screen balance/bass/treble indicator (overlay server + injected UI loader) |
| `software/volumio/ui-nav` | UI navigation channel (a daemon can switch the screen; used by the open/close key) |
| `software/jukebox-pots` | `jukebox-pots.service` (volume/balance/tone from the Arduino) |
| `software/jukebox-keyboard` | `jukebox-keyboard.service` (play/pause/stop/prev/next/mute, and open/close the queue view) |
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
