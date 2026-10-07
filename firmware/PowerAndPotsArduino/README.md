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

### Soft off → the host powers itself down

`POWER: soft off` is a *request*, not an action: the host (the Raspberry Pi)
turns it into a clean shutdown. The **jukebox-pots** daemon watches for that
line and, when the power button is enabled, powers the Pi off and tells this
board to cut the relay **afterwards**:

```
button short press --> POWER: soft off --> Pi: systemctl poweroff
                                      \-> "POWER: off 30" --> relay OFF in 30 s
```

The relay must stay on while the Pi halts, and the Pi cannot send anything once
it is down — but this board keeps running from 5VSB — so the **delay lives
here**. On `POWER: off [N]` the firmware arms a cut `POWER_OFF_DELAY_MS`
(default 30000 ms) later; the optional `N` (seconds, may be `0`) overrides it,
so the host can tune the delay without reflashing. The cut prints
`POWER: hard off` when it happens. A **long press** still cuts immediately and
cancels any pending cut (`POWER: off cancelled`), which is also the escape
hatch if the Pi hangs and never shuts down.

> A second short press after the Pi has halted re-turns the relay on
> (`POWER: ON`) without booting anything, because the Pi is down. Use the long
> press to cut cleanly.

## Serial report

Output over USB at 9600 baud. Values are only reported when they change,
at most every 250 ms (`REPORT_INTERVAL_MS`). A `-----` separator is printed
whenever anything is reported.

**Status request.** Send a newline (or any line that does not start with
`POWER:`) and the firmware re-emits every value once, even if none changed. The
host uses this right after opening the port (`jukebox-pots` writes a newline) so
it can seed the volume and balance from the current pot positions — needed
because the board may already be running (powered from 5VSB) when the Pi boots
and would otherwise stay silent.

**Host commands.** A line beginning with `POWER:` is a command instead of a
status request (the line ends at `\n`/`\r`):

| Line from the host | Effect |
|---|---|
| `POWER: off` | arm a relay cut after `POWER_OFF_DELAY_MS` (30 s) |
| `POWER: off N` | same, but cut after `N` seconds (may be `0`) |
| `POWER: cancel` | disarm a pending cut (host could not shut down) |

Any other input (including a lone newline) is the full status request above.


```
POT volume: 15 (raw 700)
POT single: 20 (raw 1020)
POT balance: 10 (raw 512)
POT multi second: 0 (raw 540)
POT aux: 12 (raw 640)
POWER tristate: CENTER|LEFT|RIGHT
POWER switch: ON|OFF
MULTI PUSH switch: ON|OFF
MULTI ROTARY switch: OFF|SW1|SW2
-----------------------------------------
```

Potentiometers are scaled through per-segment calibration tables
(`POT_VOLUME_POINTS`, `POT_SINGLE_POINTS`, `POT_BALANCE_POINTS`,
`POT_MULTI_SECOND_POINTS`, `POT_AUX_POINTS` in `src/main.cpp`): each entry maps
a raw reading to a value, interpolating between points. Adjust them there to
calibrate your hardware.

## Multiplexer

The Pro Micro only breaks out A0-A3 and all four are used, so extra pots go
through a **CD4051B** 8:1 analog mux whose common output feeds `A0`. Address
bits (C tied to GND; `INH` and `VEE` to GND):

| A (D7) | B (D5) | Channel | Pin | Pot |
|---|---|---|---|---|
| 0 | 0 | X0 | 13 | multi second |
| 1 | 0 | X1 | 14 | balance |
| 0 | 1 | X2 | 15 | **aux** (spare) |
| 1 | 1 | X3 | 12 | spare |

The firmware reads the three channels in turn each loop by setting A
(`MUX_SELECT_PIN`) and B (`MUX_SELECT2_PIN`). To add a fourth pot, wire the next
channel to a free mux input and add its read (with a `PotPoint` table and a
`ReportedValue`) in the same block.

## USB identification

The jukebox also carries a KeyboardArduino; both are identical Arduino Micros
(same VID:PID, no unique USB serial). To let the host tell them apart without
depending on which USB port each is plugged into, this firmware sets
`board_build.usb_product = Jukebox Pots` in `platformio.ini`, so the board
enumerates with the product string **"Jukebox Pots"** (and appears as
`/dev/serial/by-id/usb-Jukebox_Pots_*-if00`). The keyboard board sets its own
string. `jukebox-pots` selects the port by this string.

## Pin map

| Pin | Function | Notes |
|---|---|---|
| 2 | Power relay | **active-low** module (`RELAY_ON = LOW`), defined in `power-state-machine.hpp` |
| 14 | Power switch | `INPUT`, HIGH = pressed |
| 15 | Single pot supply | enabled only during its reading |
| A0 | Mux analog input | |
| 7 | Mux address A | LOW = multi second pot, HIGH = balance pot |
| 5 | Mux address B | LOW = X0/X1, HIGH = X2 aux pot (see above) |
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
