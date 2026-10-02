# jukebox pots (volume + balance + tone from the Arduino)

Turns four potentiometers of the **PowerAndPotsArduino** into physical
controls **for the speakers (I2S DAC) only**: volume, balance, bass and
treble.

The Arduino prints their state on its USB serial port (9600 baud, only on
change):

```
POT volume: 15 (raw 700)
POT balance: 10 (raw 512)
POT single: 12 (raw 640)
POT multi second: 8 (raw 430)
```

A small daemon reads those lines and applies them to the DAC branch of the
chain, on **either platform** (`JP_BACKEND=auto|volumio|moode`):

| Pot | Range | Effect |
| --- | --- | --- |
| `POT volume` | 0–20 | player volume, 0–100 % |
| `POT balance` | 0–20, center 10 | pan of the DAC left/right (opposite channel attenuated) |
| `POT single` | 0–20, center 10 | **bass** shelf, ±12 dB |
| `POT multi second` | 0–20, center 10 | **treble** shelf, ±12 dB |

Center (10) on either tone pot means **0 dB**, i.e. bit-for-bit transparent.
The pots are not hard-wired to a function: `JP_TONE_BASS_POT` and
`JP_TONE_TREBLE_POT` pick which firmware lines drive bass and treble
(`single` / `multisecond` by default).

The **second, constant-level output that feeds the spectrum analyser is never
touched** on either platform: volume lives on the DAC branch only and the
tone shelves live on the DAC branch only, so nothing in this package can
change its level or response.

## How it works

```
PowerAndPotsArduino --USB serial--> jukebox-pots daemon
                                      | volume  -> player volume (DAC branch)
                                      | balance -> DAC pan (per-channel)
                                      '- tone    -> CamillaDSP config + SIGHUP (live)
```

The platform is detected automatically (`JP_BACKEND`):

| | Volumio | moOde |
| --- | --- | --- |
| Volume | Volumio API (`/api/v1/commands/?cmd=volume`) -> `SoftMaster` | `/var/www/util/vol.sh` -> CamillaDSP fader (volume type "CamillaDSP") |
| Balance | two channels of `SoftMaster Playback Volume` | `balance_l`/`balance_r` gain filters in `jukebox-tone.yml` |
| Tone | shelves in `/usr/local/jukebox-audio/cdsp/camilla.*.yml` | shelves in `/usr/share/camilladsp/configs/jukebox-tone.yml` |

* **Volume** goes through the player's own volume path, so the UI/API stay in
  sync. On moOde the volume type must be **CamillaDSP** (the dual-output
  installer sets it): the knob value becomes the CamillaDSP fader, which only
  the DAC branch passes through. If the API/CLI is unreachable the daemon
  writes the ALSA mixer directly instead.
* **Balance** attenuates the channel opposite to the pan, keeping the other at
  its current level: on Volumio via the left/right values of `SoftMaster`, on
  moOde via per-channel gain filters inside the CamillaDSP config (down to
  `JP_BALANCE_MAX_DB`, default 60 dB, at hard pan).
* **Bass/treble** rewrite the two shelf `gain:` values in the CamillaDSP
  config and send the running process a `SIGHUP`; it re-reads the config and
  rebuilds the filters **without interrupting playback**. The rewrite finds
  the shelves by their biquad type (`Lowshelf`/`Highshelf`) and preserves the
  file's mode/owner so MPD's `cdsp` plugin can keep rewriting it.
* The daemon has **no third-party dependencies** (no `pyserial`); it opens the
  serial port with `termios` and re-scans for it when missing, so it survives
  the Arduino being unplugged/replugged. A udev rule also restarts it when a
  `ttyACM`/`ttyUSB` appears.
* Right after opening the port the daemon **requests a full status report** (it
  writes one byte; the firmware re-emits every value). This is required at boot:
  the board is powered from 5VSB and may already be running when the Pi comes
  up, and the firmware only reports on change, so without the request the daemon
  would never learn the current pot positions and volume/balance would not be
  seeded.
* The daemon never asserts DTR (see the clone notes above); the firmware reports
  regardless of it, and the status request is a plain byte.

## Install

From this directory (the script copies itself to the Pi and runs it there):

```sh
./deploy.sh install
```

Or directly on the host (Volumio or moOde):

```sh
sudo ./install.sh install
```

The installer is **idempotent**: re-running it just re-asserts the same files
and restarts the service. It will:

1. detect the I2S DAC card (`sndrpirpidac`) unless `--dac-card` is given,
2. install the daemon in `/usr/local/jukebox-pots/`,
3. install and enable `jukebox-pots.service` (starts at boot, stays up,
   `Restart=always`),
4. install a udev rule that restarts the service when the serial port appears.

## Verify / operate

```sh
./deploy.sh status
./deploy.sh verify
sudo ./install.sh uninstall
```

* `status` shows the detected port, its USB id and the current `SoftMaster`
  Left/Right values.
* `verify` checks the daemon, the self-tests, the unit state, the serial port
  and the `SoftMaster` control.
* The daemon can be probed on its own:

  ```sh
  sudo /usr/local/jukebox-pots/jukebox-pots.py --probe    # port + mixer + a few lines
  sudo /usr/local/jukebox-pots/jukebox-pots.py --selftest # mapping tests
  ```

## Identify the Arduino

With only the PowerAndPots board plugged in, the port should be
`/dev/ttyACM0` and its USB id `2341:8037` (Arduino Micro). The daemon looks for
it in this order:

1. `--port DEV` / `JP_PORT` if you set one explicitly;
2. a `/dev/serial/by-id/*` symlink whose name contains `arduino`;
3. the first `/dev/ttyACM*` or `/dev/ttyUSB*` whose USB ids are `2341:8036`,
   `2341:8037`, `2a03:0042`, `2a03:0043`, or whose product string mentions
   Arduino.

> If `lsusb` does not show the board at all, it is usually a **charge-only USB
> cable** or a port without data lines. Try another cable before anything else.

### Powering the board from 5VSB (VBUS sense)

On the ATmega32U4 the **VBUS pin is not only power — it is the "a USB host is
present" signal**. The chip only talks USB when it sees ~5 V there.

Feeding 5VSB into the Arduino **`5V` pin** is fine and, on a genuine Arduino
Micro, *also* satisfies VBUS: its power-select FET (T1) connects `5V` to the
VUSB net whenever VIN is low, so the 5 V also reaches the VBUS sense input. The
usual cable with the **VBUS wire cut** (D+/D-/GND only) then has no path back to
the Pi, so there is no back-feed either.

* VBUS cut + 5 V into `5V` (Micro) -> sense OK, enumerates, no back-feed.
* VBUS intact + 5 V into `5V` -> works, but 5VSB can push ~150 mA back into the
  Pi's USB port through T1 + the polyfuse; put a Schottky in the VBUS wire
  (cathode towards the Arduino) if you keep the cable whole.

**Clone warning (e.g. Pro Micro).** The clones have no T1, so feeding their `5V`
/ `VCC` pin does **not** put anything on VBUS sense: the board is powered (LEDs
on) but **never enumerates** — `lsusb` stays empty and `dmesg` shows no attempt
at all. The fix is to tie the supply to VBUS sense:

* bridge the **`J1`/`SJ1` solder jumper** (present on the Pro Micro, next to the
  USB connector) — its one pad is VCC and the other is UVCC/VBUS. On a 5 V board
  it is meant to be closed; or
* solder a wire from the `5V`/`VCC` pin to the VBUS net (the USB-C VBUS pins
  A4/A9/B4/B9, or the polyfuse `F1` beside the connector).

Measure to confirm: with 5VSB on and **no USB cable**, the VBUS net must read
~5 V. Then the board appears as `2341:8037` on `/dev/ttyACM0` within a second or
two of the Pi's USB becoming active.

### DTR resets the board (and the power relay)

The daemon deliberately **does not assert DTR**. On the Arduino Micro DTR is
wired to reset, and this board also runs the power-button state machine: raising
DTR reboots it, which resets the relay state and would cut power if the jukebox
is running. The firmware streams regardless of DTR, so plain `termios` suffices.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `--dac-card NAME` | auto | ALSA card id of the DAC |
| `--port DEV` | auto | serial device |
| `--baud N` | 9600 | serial baud rate |
| `--pot-max N` | 20 | firmware pot range |
| `--volume-max N` | 100 | player volume scale |
| `--balance-center N` | 10 | pot value meaning "centered" |
| `--balance-span N` | 10 | pot steps from center to hard pan |
| `--volume-invert` | off | reverse the volume pot direction |
| `--balance-invert` | off | reverse left/right |
| `--backend NAME` | auto | `auto`/`volumio`/`moode` |
| `--balance-max-db N` | 60 | attenuation at hard pan (moOde backend) |
| `--no-api` | off | write the mixer directly instead of the player volume path |
| `--tone` / `--no-tone` | on | enable/disable the bass+treble pots |
| `--tone-max-db N` | 12 | shelf range at the pot extremes |
| `--tone-center N` | 10 | pot value meaning "flat" |
| `--tone-span N` | 10 | pot steps from center to full shelf |
| `--tone-bass-pot NAME` | single | firmware line driving bass (`single`/`multisecond`) |
| `--tone-treble-pot NAME` | multisecond | firmware line driving treble |
| `--tone-bass-invert` | off | reverse the bass pot direction |
| `--tone-treble-invert` | off | reverse the treble pot direction |

The same values can be set as environment variables in
`/usr/local/jukebox-pots/config.env` (`JP_*`), which the unit loads at start.

## Notes

* The firmware already scales the raw ADC reading, so the daemon consumes the
  `POT volume` / `POT balance` / `POT single` / `POT multi second` values
  directly. If you re-calibrate the pots in the firmware, the daemon needs no
  change.
* `SoftMaster` is created by the `softvol` plugin the first time the chain is
  opened. The daemon creates it on demand (a 1-second silent `aplay`) if it is
  missing, and the standard `jukebox-audio` install materializes it too.
* Balance is relative to the current level, so it keeps working across volume
  changes; only the two channel values of `SoftMaster` are written.
* The tone pots only work when the dual-output package was installed with the
  tone enabled (the default). Gains are applied live with a `SIGHUP` on
  `/usr/local/jukebox-audio/cdsp/` (Volumio) or
  `/usr/share/camilladsp/configs/jukebox-tone.yml` (moOde); the template is
  updated too, so the setting survives a regeneration by the guard and a
  reboot.
* The daemon never asserts DTR (see the hardware notes above); the firmware
  reports regardless of it, and the status request is a plain byte.
* Uninstall removes the service, the unit, the udev rule and
  `/usr/local/jukebox-pots/`, and restores nothing else — the audio chain was
  never modified by this package.

## Layout

```
install.sh            # idempotent installer (install/verify/status/uninstall)
deploy.sh             # ship and run install.sh over SSH
jukebox-pots.py       # the daemon (+ --probe and --selftest)
README.md             # this file
```
