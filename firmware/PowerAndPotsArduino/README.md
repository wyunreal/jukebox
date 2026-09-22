# PowerAndPotsArduino

Firmware for the jukebox's **Arduino Micro (ATmega32U4)**: drives the power
relay through a power switch state machine and reports the state of
potentiometers and switches over USB serial (9600 baud).

## Power switch state machine (`src/power-state-machine.hpp`)

The relay starts **OFF** when the Arduino powers up. All turn-on actions
happen **on button release**:

| Relay state | Press | Action |
|---|---|---|
| OFF | short or long (any) | on release: relay **ON** + `POWER: ON` |
| ON | short (< 5 s) | on release: `POWER: soft off` (relay stays on) |
| ON | long (≥ 5 s) | at 5 s, while still held: `POWER: hard off` + relay **OFF** immediately (the later release is ignored) |

The long-press threshold lives in `POWER_LONG_PRESS_MS` (5000 ms).

## Serial report

Output over USB at 9600 baud. Values are only reported when they change,
at most every 250 ms (`REPORT_INTERVAL_MS`). A `-----` separator is printed
whenever anything is reported.

```
POT volume: 15 (raw 700)
POT single: 20 (raw 1020)
POT balance: 10 (raw 512)
POT multi second: 0 (raw 540)
POWER tristate: CENTER|LEFT|RIGHT
POWER switch: ON|OFF
MULTI PUSH switch: ON|OFF
MULTI ROTARY switch: OFF|SW1|SW2
-----------------------------------------
```

Potentiometers are scaled through per-segment calibration tables
(`POT_VOLUME_POINTS`, `POT_SINGLE_POINTS`, `POT_BALANCE_POINTS`,
`POT_MULTI_SECOND_POINTS` in `src/main.cpp`): each entry maps a raw reading
to a value, interpolating between points. Adjust them there to calibrate
your hardware.

## Pin map

| Pin | Function | Notes |
|---|---|---|
| 2 | Power relay | **active-low** module (`RELAY_ON = LOW`), defined in `power-state-machine.hpp` |
| 14 | Power switch | `INPUT`, HIGH = pressed |
| 15 | Single pot supply | enabled only during its reading |
| A0 | Mux analog input | |
| 7 | Mux select | LOW = multi second pot, HIGH = balance pot |
| A1 | Volume pot | |
| A2 | Power tristate pot | raw > 500 → RIGHT, > 100 → LEFT, else CENTER |
| A3 | Single pot | |
| 4 | Multi push switch | `INPUT_PULLUP`, active LOW (ON = pressed) |
| 8, 9 | Rotary switch 1/2 | `INPUT_PULLUP`, active LOW |

## Build and flash

[PlatformIO](https://platformio.org/) project:

```sh
pio run                # build
pio run -t upload      # flash
pio device monitor     # serial monitor (9600)
```

On Linux, install the udev rules so the Micro's port is accessible
without root:

```sh
sudo cp 99-platformio-udev.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

`99-platformio-udev.rules` is PlatformIO's standard file (Apache 2.0).

## Layout

```
src/main.cpp                  # pot/switch reading and serial reporting
src/power-state-machine.hpp   # relay + short/long press power switch logic
99-platformio-udev.rules      # PlatformIO udev rules (Linux)
```
