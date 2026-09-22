# jukebox

A homemade jukebox: firmware for power control and input reading
(potentiometers and switches) on an **Arduino Micro (ATmega32U4)**,
plus FreeCAD 3D models of the hardware (screen, Raspberry Pi, HDD and
electronics supports).

## Status

The repository currently contains the firmware and the 3D models of
the hardware:

```
firmware/PowerAndPotsArduino/   # PlatformIO project (Arduino Micro)
├── src/main.cpp                # pot/switch reading and serial reporting
├── src/power-state-machine.hpp # relay + short/long press power switch logic
├── platformio.ini
└── README.md                   # detailed firmware documentation

hardware/3d-models/             # FreeCAD models, grouped by part
├── Electronic support/         # PowerAndPots controller board, box, fuse case
├── hdd/                        # hard drive wall support
├── Pi support/                 # Raspberry Pi support
├── screen/                     # screen supports, cover and joints
└── Spectrum/                   # spectrum display frame
```

## Firmware

- **Power relay** driven by a state machine: short press turns it on,
  long press (≥ 5 s) performs a hard off; the button acts on release.
- **Serial reporting** (9600 baud, only on change): volume/single/balance/
  multi second pots (with per-segment calibration tables), power tristate,
  power switch, multi push and rotary switch.

Pin map, output format, calibration and flashing: see
[firmware/PowerAndPotsArduino/README.md](firmware/PowerAndPotsArduino/README.md).

## 3D models

FreeCAD (`.FCStd`) models, grouped by part: see
[hardware/3d-models/README.md](hardware/3d-models/README.md).
No STL/STEP exports are committed yet — export from FreeCAD as needed.
