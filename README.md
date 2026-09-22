# jukebox

Firmware for the jukebox: power control and input reading (potentiometers
and switches) on an **Arduino Micro (ATmega32U4)**, reporting state over
USB serial at 9600 baud.

## Status

The repository currently contains only the firmware stage:

```
firmware/PowerAndPotsArduino/   # PlatformIO project (Arduino Micro)
├── src/main.cpp                # pot/switch reading and serial reporting
├── src/power-state-machine.hpp # relay + short/long press power switch logic
├── platformio.ini
└── README.md                   # detailed firmware documentation
```

## What it does

- **Power relay** driven by a state machine: short press turns it on,
  long press (≥ 5 s) performs a hard off; the button acts on release.
- **Serial reporting** only when a value changes (250 ms throttle):
  volume/single/balance/multi second pots (with per-segment calibration
  tables), power tristate, power switch, multi push and rotary switch.

Pin map, output format, calibration and flashing: see
[firmware/PowerAndPotsArduino/README.md](firmware/PowerAndPotsArduino/README.md).

## Development

Requires [PlatformIO](https://platformio.org/). From
`firmware/PowerAndPotsArduino`:

```sh
pio run                # build
pio run -t upload      # flash
pio device monitor     # serial monitor (9600)
```
