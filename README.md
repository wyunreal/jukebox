# jukebox

A homemade jukebox built around a **Raspberry Pi 4B** running
[Volumio](https://volumio.com/): firmware for power control and input reading
(potentiometers, switches and a 4x4 button matrix) on **Arduino Micro
(ATmega32U4)** boards, FreeCAD 3D models of the hardware (screen, Raspberry Pi,
HDD and electronics supports), the audio software that gives the Pi a custom
dual output, and the operations skill used to run and troubleshoot the box.

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

software/volumio-dual-output/   # custom dual audio output for Volumio
├── jukebox-audio.sh            # installer / verify / status (runs on the Pi)
├── deploy.sh                   # ship and run the installer over SSH
├── camilladsp                  # CamillaDSP v4.1.3 (armv7), tone-control engine
├── libasound_module_pcm_cdsp.so# cdsp ALSA plugin (armhf)
├── cdsp/                       # plugin source (patched) + strrep.h
└── README.md                   # design doc: ALSA split, tone, variants, fail-safe

software/jukebox-pots/          # pot volume/balance/tone from the Arduino
├── jukebox-pots.py             # daemon: USB serial -> DAC volume/balance/tone
├── install.sh                  # idempotent installer (runs on the Pi)
├── deploy.sh                   # ship and run the installer over SSH
└── README.md                   # design doc: mapping, detection, analyser safety

skills/jukebox/SKILL.md         # agent skill to operate and troubleshoot the box

docs/moode-port-plan.md         # plan: porting the audio/control stack to moOde
```

The audio setup splits playback into the I2S DAC (speakers, volume-controlled
by Volumio) and a second constant-level output feeding a hardware spectrum
analyser, with an automatic DAC-only fallback when the second device is absent.
The DAC branch also carries a live **bass/treble tone control** (CamillaDSP),
driven by two of the Arduino's potentiometers.

## Physical controls

Four potentiometers of the PowerAndPots Arduino drive the DAC (speakers) only:

| Pot | Function |
| --- | --- |
| `POT volume` | Volumio volume (0–100 %) |
| `POT balance` | left/right balance of the DAC |
| `POT single` | bass shelf (±12 dB, center = flat) |
| `POT multi second` | treble shelf (±12 dB, center = flat) |

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

Custom dual audio output for Volumio (I2S DAC + constant-level second output
for the spectrum analyser): see
[software/volumio-dual-output/README.md](software/volumio-dual-output/README.md).
The installer runs on the Pi (`sudo ./jukebox-audio.sh install
--second-output usb`) or is shipped over SSH with `./deploy.sh`.

Physical volume and balance from the PowerAndPots Arduino's potentiometers are
handled by `software/jukebox-pots/` (`jukebox-pots.service`): it reads `POT
volume` / `POT balance` over USB serial and drives the DAC volume and balance,
leaving the analyser output untouched. Install with `software/jukebox-pots/deploy.sh
install`; see its [README](software/jukebox-pots/README.md).

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
