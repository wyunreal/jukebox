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
chain, on the **Volumio** box:

| Pot | Range | Effect |
| --- | --- | --- |
| `POT volume` | 0–20 | Volumio volume, 0–100 % |
| `POT balance` | 0–20, center 10 | pan of the DAC left/right (opposite channel attenuated) |
| `POT single` | 0–20, center 10 | **bass** shelf, ±8 dB |
| `POT multi second` | 0–20, center 10 | **treble** shelf, ±8 dB |

Center (10) on either tone pot means **0 dB**, i.e. bit-for-bit transparent.
The pots are not hard-wired to a function: `JP_TONE_BASS_POT` and
`JP_TONE_TREBLE_POT` pick which firmware lines drive bass and treble
(`single` / `multisecond` by default).

The **second, constant-level output that feeds the spectrum analyser is never
touched**: volume lives on the DAC branch only and the tone shelves live on the
DAC branch only, so nothing in this package can change its level or response.

## How it works

```
PowerAndPotsArduino --USB serial--> jukebox-pots daemon
                                      | volume  -> player volume (DAC branch)
                                      | balance -> DAC pan (per-channel)
                                      '- tone    -> CamillaDSP config + SIGHUP (live)
```

The volume path, balance and tone are those of the **Volumio** chain:

| | Volumio |
| --- | --- |
| Volume | Volumio API (`/api/v1/commands/?cmd=volume`) -> `SoftMaster` |
| Balance | two channels of `SoftMaster Playback Volume` |
| Tone | shelves in `/usr/local/jukebox-audio/cdsp/camilla.*.yml` |

* **Volume** goes through Volumio's own volume path, so the UI/API stay in
  sync. If the API is unreachable the daemon writes the ALSA mixer directly
  instead.
* **Balance** attenuates the channel opposite to the pan, keeping the other at
  its current level via the left/right values of `SoftMaster`.
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

Or directly on the host (Volumio):

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
./deploy.sh uninstall
```

* `status` shows the detected port, its USB product string and the current
  `SoftMaster` Left/Right values.
* `verify` checks the daemon, the self-tests, the unit state, the serial port
  and the `SoftMaster` control.
* The daemon can be probed on its own:

  ```sh
  sudo /usr/local/jukebox-pots/jukebox-pots.py --probe    # port + mixer + a few lines
  sudo /usr/local/jukebox-pots/jukebox-pots.py --selftest # mapping tests
  ```

## Identify the Arduino

The jukebox has **two identical Arduino Micros** (the PowerAndPots one and the
keyboard one). They share the USB VID:PID `2341:8037` and carry **no unique USB
serial number**, so the kernel cannot tell them apart by id — and binding the
daemon to a port number or a `by-path` link would break as soon as a cable or
hub moved. Instead each board is flashed with its own **USB product string**:

| Board | `board_build.usb_product` | `/dev/serial/by-id` link |
| --- | --- | --- |
| PowerAndPots | `Jukebox Pots` | `usb-Jukebox_Pots_*-if00` |
| Keyboard | `Jukebox Keyboard` | `usb-Jukebox_Keyboard_*-if00` |

The daemon selects the board whose product string is `Jukebox Pots`
(`--product` / `JP_PRODUCT` to change it, must match the firmware). Lookup
order:

1. `--port DEV` / `JP_PORT` if you set one explicitly;
2. a `/dev/serial/by-id/*` symlink whose name matches the product string;
3. any `/dev/ttyACM*` / `/dev/ttyUSB*` whose sysfs `product` matches.

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
| `--port DEV` | auto | serial device (overrides product matching) |
| `--product STR` | `Jukebox Pots` | USB product string of the PowerAndPots board |
| `--baud N` | 9600 | serial baud rate |
| `--pot-max N` | 20 | firmware pot range |
| `--volume-max N` | 100 | player volume scale |
| `--balance-center N` | 10 | pot value meaning "centered" |
| `--balance-span N` | 10 | pot steps from center to hard pan |
| `--volume-invert` | off | reverse the volume pot direction |
| `--balance-invert` | off | reverse left/right |
| `--no-api` | off | write the mixer directly instead of the player volume path |
| `--tone` / `--no-tone` | on | enable/disable the bass+treble pots |
| `--tone-max-db N` | 8 | shelf range at the pot extremes |
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
  `/usr/local/jukebox-audio/cdsp/`; the template is updated too, so the
  setting survives a regeneration by the guard and a reboot.
* The daemon never asserts DTR (see the hardware notes above); the firmware
  reports regardless of it, and the status request is a plain byte.
* Uninstall removes the service, the unit, the udev rule and
  `/usr/local/jukebox-pots/`, and restores nothing else — the audio chain was
  never modified by this package.

## Layout

```
install.sh            # idempotent installer (install/verify/status)
uninstall.sh          # remove the service, unit, udev rule and files
deploy.sh             # ship and run install.sh/uninstall.sh over SSH
files/                # everything that lands on the host (readable, human)
├── jukebox-pots.py   # the daemon (+ --probe and --selftest)
├── jukebox-pots.service
├── 89-jukebox-pots.rules
└── config.env.in     # settings template (@PLACEHOLDER@ filled at install)
README.md             # this file
```
