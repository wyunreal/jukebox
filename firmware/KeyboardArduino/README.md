# KeyboardArduino

Firmware for the jukebox's **Arduino Micro (ATmega32U4)**: scans a 4x4
push-button matrix and reports press events over USB serial (9600 baud).

## Button matrix

16 plain push buttons wired as a 4x4 matrix — no external resistors or
diodes needed: rows are driven outputs and columns use the internal
pull-ups (`INPUT_PULLUP`).

| Pins | Function |
|---|---|
| 2-5 | Rows (outputs, one driven LOW at a time) |
| 6-9 | Columns (`INPUT_PULLUP`, LOW = pressed) |

Without diodes, three buttons pressed at once forming a rectangle can
produce a ghost key; single presses are unaffected.

## Serial events

Output over USB at 9600 baud, format `<EVENT> <row> <col>` with 1-based
row/column numbering:

| Event | Meaning |
|---|---|
| `DOWN 2 3` | button pressed |
| `UP 2 3` | button released |
| `PRESS 2 3` | short press: released after less than `LONG_PRESS_MS` (1000 ms) |
| `LONG_PRESS 2 3` | long press: released after `LONG_PRESS_MS` (1000 ms) or more |
| `PRESSED 2 3` | repeat, emitted every `REPEAT_MS` (500 ms) while held |

Example (short press of row 1, column 2):

```
DOWN 1 2
PRESSED 1 2
UP 1 2
PRESS 1 2
```

Debounce is `DEBOUNCE_MS` (20 ms); all constants live at the top of
`src/main.cpp`.

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
src/main.cpp                  # matrix scan, debounce and event reporting
99-platformio-udev.rules      # PlatformIO udev rules (Linux)
```
