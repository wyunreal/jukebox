# jukebox keyboard (playback keys)

Turns the **KeyboardArduino** (a 4x4 button matrix) into playback transport
controls for the jukebox: play, pause, stop, previous track and next track.

The board reports key events over USB serial (9600 baud, `<EVENT> <row> <col>`,
1-based). A small daemon reads them and runs the matching Volumio command, so
pressing a key acts immediately (`DOWN` / `on key press`).

It finds its board the same way as `jukebox-pots`: by the **USB product string**
baked into the firmware (`board_build.usb_product = Jukebox Keyboard`), never by
USB port. The two Arduino Micros are identical, so the port would not be stable.

## Layout

```
jukebox-keyboard.py    # daemon: serial -> Volumio commands
install.sh             # installer / verify / status / uninstall (runs on the Pi)
deploy.sh              # ship and run the installer over SSH
jukebox-keyboard.service
README.md
```

## Configuration

The key -> action map lives in `/usr/local/jukebox-keyboard/config.env`
(`JK_KEY_<action>=row,col`, 1-based). Actions:

| Action | Volumio command |
|---|---|
| `PLAY` | `cmd=play` |
| `PAUSE` | `cmd=pause` |
| `STOP` | `cmd=stop` |
| `PREV` | `cmd=prev` |
| `NEXT` | `cmd=next` |
| `MUTE` | toggles mute (reads the current state, then mute/unmute) |

## Identify the keys

The board prints `DOWN r c` on press, `UP r c` on release and `PRESS r c` /
`LONG_PRESS r c` on release as a classification. To find a key's coordinates,
watch the port and press it:

```sh
sudo /usr/local/jukebox-keyboard/jukebox-keyboard.py --probe
# or watch live:
sudo /usr/local/jukebox-keyboard/jukebox-keyboard.py --watch
```

## Install

```sh
./deploy.sh --host volumio@<host> install
```

The overlay/UI packages are independent; this one only needs the keyboard board
flashed with its own USB product string.
