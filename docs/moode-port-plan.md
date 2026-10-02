# moOde port plan — dual-output jukebox

**Status:** implemented for the core audio stack (M0–M6, M8 partial); M7 touch UI pending go/no-go
**Target:** moOde audio player 10.x (64-bit Raspberry Pi OS Trixie) on the same
Raspberry Pi 4B hardware
**Constraint:** the working Volumio SD stays untouched. Development happens on
a separate, freshly flashed moOde SD (swap cards physically; label both).
**Approach:** port the *concept*, reuse the existing Arduino firmware, and
re-implement only the Pi-side glue against moOde's native mechanisms.

> **Result (2026-10-02):** the moOde box now runs the full stack. See
> `software/moode/dual-output/README.md` for what was verified live:
> dual output (DAC + fixed-level USB analyser), live tone/balance via the
> pots, CamillaDSP volume, guards, fail-safe and cold boot.

---

## 1. Goal

Reproduce on moOde the behaviour the jukebox has on Volumio:

* **Dual output**: I2S DAC (speakers, volume-controlled, bass/treble tone)
  plus a second **constant-level** output (USB sound card `Device`,
  `08bb:2902`) feeding the hardware spectrum analyser.
* **Live bass/treble** from two PowerAndPots potentiometers (CamillaDSP
  shelves, ±12 dB, centre = flat), no playback interruption.
* **Volume and balance** from the other two pots; volume affects the DAC
  branch only; the analyser feed never changes level.
* **Fail-safe**: if the USB card disappears, the chain keeps the DAC branch
  alive (DAC-only variant); when it returns, the analyser branch comes back.
* **Idempotent installers** (install / verify / status / uninstall) shipped
  from this repo, reproducible from scratch.

**Non-goals for the first pass:** DSD/multichannel, moOde renderers beyond MPD
(AirPlay/Spotify/Squeeze may work but are not part of the acceptance tests),
touch-UI performance (that is M7, best effort), migration of the real box
(the Volumio SD stays as the daily driver until the port is fully validated).

---

## 2. What moOde already gives us (verified from docs/source)

moOde is MPD + ALSA on 64-bit Pi OS (Trixie on 10.x), with these primitives
that map almost 1:1 onto our Volumio work:

| moOde native | Where | Why it matters to us |
|---|---|---|
| CamillaDSP v4 integration using the **same scripple `cdsp` plugin** | `etc/alsa/conf.d/camilladsp.overwrite.conf` | Our tone approach (shelves + live gains) runs on the same engine. |
| **`multi` split** of the output into `plughw:0,0` + `hw:Loopback` | `etc/alsa/conf.d/_sndaloop.conf` | Exactly the technique we use for the DAC/analyser split. |
| **Volume type "CamillaDSP"** (64-bit, with dither) that pushes the knob/REST volume into CamillaDSP's fader | `www/util/cdsp_volume_update.py`, statefile `/var/lib/cdsp/statefile.yml` | Gives us DAC-only volume for free: CamillaDSP only processes the DAC branch. |
| CamillaDSP configs + quick switching via REST (`get/set_cdsp_config`) and a pipeline editor | `/usr/share/camilladsp/configs/V4-*.yml` | Our tone/balance pipeline can ship as a config; switching stays supported. |
| REST API `/command/?cmd=...` (`set_volume`, `get_volume`, `set_cdsp_config`...) and CLI (`moodeutl`, `vol.sh`, `mpc`) | `www/command/`, `/var/www/util/vol.sh` | Replacement for the Volumio API calls in `jukebox-pots`. |
| Native **rotary encoder / volume knob** support (GPIO, 8-pin config screen) | `www/daemon/gpio_buttons.py`, `www/gpio-config.php` | Alternative volume path; our pots still need the serial daemon, but this proves the volume plumbing is open. |
| GPIO/ALSA config managed with explicit "managed by moOde" files; in-place updater | `etc/alsa/conf.d/*`, `www/util/*-updater.sh` | Tells us where to hook and why a **guard is mandatory** (moOde rewrites audio files on settings changes/updates). |

**Bottlenecks found so far**

* moOde 10 is **aarch64 only** → our `camilladsp` armv7 and `cdsp` armhf
  binaries do not run; both need aarch64 builds (CamillaDSP publishes a stable
  `camilladsp-linux-aarch64.tar.gz`; the plugin we cross-build).
* CamillaDSP (any stable version, including 4.1.3) has a **single playback
  device**; the split must stay in ALSA, exactly as we do today.
* The DSI touchscreen is a **Waveshare panel**; moOde targets the official
  display. Driver/config support must be checked (M7), it may be the hardest
  part of the whole port.

---

## 3. Target architecture on moOde

```text
MPD  ──►  pcm._audioout            (moOde indirection point, overridden by us)
             │
          pcm.jukeboxSplit  (type multi)
             ├─ branch a:  pcm.camilladsp   (moOde's cdsp plugin → CamillaDSP v4)
             │                 │  pipeline: balance (per-channel gain)
             │                 │            + bass shelf  (120 Hz, Q 0.7)
             │                 │            + treble shelf (6 kHz, Q 0.7)
             │                 └─► plughw:CARD=sndrpirpidac   (speakers)
             └─ branch b:  analyser trim (alsaequal low-shelf, optional)
                              └─► plughw:CARD=Device          (spectrum analyser,
                                                               fixed level)
```

* **Volume**: moOde `Volume type = CamillaDSP`. The knob/REST volume goes into
  CamillaDSP's fader via the statefile/websocket, so it only affects branch a.
  Branch b never sees it.
* **Balance**: because the `SoftMaster` softvol trick does not exist on moOde,
  balance becomes per-channel gains inside the CamillaDSP pipeline (a Mixer
  entry). `jukebox-pots` rewrites those gains; live, same as tone.
* **Tone**: two Biquad shelves in the CamillaDSP config, gains rewritten +
  `SIGHUP`, identical to the Volumio implementation.
* **Fail-safe**: when the USB card is absent, the guard swaps our override for
  a DAC-only version (single branch). udev triggers on card add/remove.
* **Guards**: systemd path units re-assert our files after moOde rewrites
  (`_audioout.conf`, `working_config.yml`, `mpd.conf`) and after in-place
  updates.
* **MPD buffers**: inject `buffer_time "3000000"` / `period_time "50000"`
  (guard) so player stalls never starve the chain. Keep the patched plugin
  (underrun concealment + atomic config write + v4 format names + exec args).

---

## 4. moOde file map (pin these down on day 1)

| Path | What it is |
|---|---|
| `/etc/alsa/conf.d/_audioout.conf` | moOde's output indirection: `pcm._audioout { type copy; slave.pcm "plughw:0,0" }`. Managed by moOde. |
| `/etc/alsa/conf.d/_sndaloop.conf` | moOde's loopback split (`multi` of `plughw:0,0` + `hw:Loopback,0`). Reference implementation for our override. |
| `/etc/alsa/conf.d/camilladsp.overwrite.conf` | moOde's `pcm.camilladsp` declaration (`cpath`, `config_out /usr/share/camilladsp/working_config.yml`, `config_cdsp 1`, statefile, websocket 1234). |
| `/usr/local/bin/camilladsp` | moOde's CamillaDSP v4 binary. Check version before replacing anything. |
| `/usr/share/camilladsp/configs/` | moOde's V4 configs (quick switching). Where our tone/balance config goes. |
| `/usr/share/camilladsp/working_config.yml` | Active config generated by moOde when switching. Target for live gain rewrites + SIGHUP. |
| `/var/lib/cdsp/statefile.yml` | cdsp statefile (volume/mute, config path) used by the volume integration. |
| `/var/www/util/vol.sh`, `www/util/cdsp_volume_update.py` | Volume CLI / volume→CamillaDSP bridge. |
| `/etc/mpd.conf` (generated via `www/util/mpdconf_merge.py`) | MPD config; where the 3 s buffer must land. Verify the `audio_output.device` value (expect `_audioout`, to confirm). |
| `/var/www/command/` + `http://moode/command/?cmd=...` | REST API. |
| `www/snd-config.php`, `alsa_loopback` job | Audio settings screens/jobs that **rewrite ALSA config** → guard targets. |
| `www/util/system-updater.sh` | In-place updates; make sure guards re-assert afterwards. |

---

## 5. Assumptions to verify first (M0 on the fresh box)

1. `grep -A6 'audio_output' /etc/mpd.conf` → MPD's device name. If it is
   `_audioout`, overriding `pcm.!_audioout` is enough. If it is `hw:0,0`,
   adjust (`pcm.!default` or the actual name).
2. `aplay -L` shows `camilladsp`, `_audioout`, loopback only when enabled.
3. Exact moOde + CamillaDSP versions (`camilladsp --version`,
   `moodeutl --help`, WebUI About).
4. Which moOde actions rewrite which files (change a DSP option, toggle
   loopback, save audio settings) → list for the guard.
5. In-place update behaviour: does it overwrite `/etc/alsa/conf.d/*`?
6. Default login: moOde images have **no default password**; the SD must be
   flashed with Pi Imager setting user/password, SSH enabled and Wi-Fi
   (required for moOde to work properly).

---

## 6. Milestones

Each milestone ends with explicit checks; do not advance with a red check.

### M0 — Fresh moOde baseline (½ day)

* [x] Flash moOde 10.x 64-bit on a **new SD** (Pi Imager: user, password,
      SSH, Wi-Fi; hostname e.g. `moode`). Label the SD.
* [x] Boot, open `http://<host>`, confirm stock playback works.
* [x] Inventory: `uname -a`, `aplay -l`, `cat /proc/asound/cards`,
      `ls /dev/ttyACM0`, `camilladsp --version`, moOde release.
* [x] Verify large USB/ethernet stability is not needed for this work.
* [x] Save a baseline: copy `/etc/alsa/conf.d/`, `/etc/mpd.conf`,
      `/boot/firmware/config.txt` to `/root/moode-baseline/`.

**Exit:** inventory documented in this file; stock moOde plays music; baseline
saved.

### M1 — aarch64 binaries (½–1 day)

* [x] Check moOde's CamillaDSP version. If it is a stable v4 with the features
      we need, **keep it** (policy: stable versions only, no dev builds).
* [x] If a newer stable is needed: download `camilladsp-linux-aarch64.tar.gz`
      (pin exact version + sha256), install to `/usr/local/bin/` with backup.
* [x] Cross-build our patched `cdsp` plugin for aarch64 (Docker recipe in
      §7), md5 it, back up moOde's `.so`, deploy and confirm the plugin loads
      (`aplay -D camilladsp` smoke test with a minimal config to a `null`
      sink, then a real file to the DAC).

**Exit:** CamillaDSP runs through the plugin on aarch64 with our patch set.

### M2 — ALSA split override (½ day)

* [x] Create our own `/etc/alsa/conf.d/90-jukebox.conf` overriding
      `pcm.!_audioout` with the `multi` split (branch a: `camilladsp`;
      branch b: analyser chain → `plughw:CARD=Device`).
* [x] Leave moOde's own DSP options off (graphic/parametric EQ, its loopback,
      its CamillaDSP toggles) and document why.
* [x] Play a file: both cards `RUNNING` simultaneously.
* [x] Identify every moOde action that rewrites ALSA config and build the
      first guard (path unit) that restores `90-jukebox.conf`.

**Exit:** dual playback works; a settings change no longer clobbers it.

### M3 — Tone control (½ day)

* [x] Ship a CamillaDSP config with the two shelves (120 Hz / 6 kHz, Q 0.7,
      gain 0) into `/usr/share/camilladsp/configs/` and make it selectable
      with `set_cdsp_config`; keep a copy as the durable template.
* [x] Implement live gain rewrite on `working_config.yml` + `SIGHUP`
      (locate the process via `pgrep -f camilladsp`, as on Volumio).
* [x] Neutral position = flat (verify with a sweep or by ear + level check).
* [x] Test ±12 dB sweeps with music playing (no cut, no interruption).

**Exit:** pots-independent manual sweeps work live.

### M4 — Volume and balance (½ day)

* [x] Set moOde `Volume type = CamillaDSP`; verify knob/REST volume changes
      the DAC level only (analyser meter must not move).
* [x] Add balance as per-channel gains in the CamillaDSP pipeline; expose
      them for scripted rewrite.
* [x] Confirm volume + balance + tone coexist without fighting (all in the
      same config; rewrites preserve each other's values).

**Exit:** DAC-only volume; balance L/R works; analyser constant.

### M5 — `jukebox-pots` port (1 day)

* [x] Add a backend switch (`JP_BACKEND=volumio|moode`): volume via moOde REST
      (`set_volume`, read `get_volume`) instead of Volumio's `:3000` API.
* [x] Replace the `SoftMaster` balance implementation with CamillaDSP
      per-channel gain rewrites (same live mechanism as tone).
* [x] Keep: serial protocol, DTR-safe port opening (critical: a reset drops
      the relay state machine), tone rewrite, self-tests, `--probe`.
* [x] Installer adapted to moOde paths + systemd unit + udev rule; verify
      idempotency (install twice) and uninstall.

**Exit:** all four pots behave exactly as on Volumio.

### M6 — Guards, fail-safe, MPD buffer (½ day)

* [x] Guard re-asserts: our ALSA override, CamillaDSP tone/balance gains,
      MPD buffer settings.
* [x] udev rule on the USB card: unplug mid-playback → DAC keeps playing
      (DAC-only variant); replug → analyser returns.
* [x] `buffer_time "3000000"`, `period_time "50000"` survive a moOde settings
      change and a reboot.
* [x] Reboot test: everything comes back by itself.

**Exit:** power-cycle and hotplug tests pass unattended.

### M7 — Touch UI (best effort, 1+ day, may be dropped)

* [ ] Determine if the **Waveshare DSI panel** works on moOde 10 at all
      (dtoverlay / panel driver). If not, decide: official panel, keep
      Volumio for the UI, or custom kernel work. This is the go/no-go for a
      full migration.
* [ ] If the panel works: enable moOde local display, measure scroll cost and
      port only the applicable ideas (GPU compositing flags, avoid blur,
      correct resolution). Do **not** port `volumio-ui-boost` verbatim:
      every path it patches belongs to Volumio.

**Exit:** panel + touch usable and UI acceptable, or explicit decision to keep
Volumio for UI reasons.

### M8 — Clean-room validation (½ day) — *uninstall→install cycle done; fresh SD pass pending*

From a second freshly flashed moOde SD, run the whole install from this repo
and execute the acceptance checklist (§8) without touching anything by heart.

### M9 — Repo integration and docs (½ day)

* [ ] New package `software/moode-dual-output/` (installer + aarch64
      binaries), mirroring `software/volumio/dual-output/`.
* [ ] `software/jukebox-pots/` with the backend switch and shared docs.
* [ ] Update root `README.md`, `skills/jukebox/SKILL.md` (new moOde section
      or sibling skill) and this plan (results).
* [ ] Work on branch `moode-port`; `main` only after M8 passes.

---

## 7. aarch64 plugin build (Docker, no toolchain on the host needed)

```sh
mkdir -p /tmp/opencode
# run from software/volumio/dual-output (the cdsp/ folder lives there)
docker run --rm -v /tmp/opencode:/out -v "$PWD/cdsp:/src:ro" \
  debian:bookworm bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    dpkg --add-architecture arm64
    apt-get update -qq
    apt-get install -y -qq gcc-aarch64-linux-gnu libasound2-dev:arm64 >/dev/null
    aarch64-linux-gnu-gcc -DPIC -std=gnu11 -O2 -fPIC -shared -I/usr/include \
      -o /out/libasound_module_pcm_cdsp.so /src/libasound_module_pcm_cdsp.c'
```

Building against bookworm's older glibc is fine on Trixie (forward
compatible). Keep source and shipped `.so` in sync, as the Volumio package
does.

---

## 8. Acceptance checklist (definition of done)

1. Fresh install from the repo on a clean moOde SD ends with all checks green,
   twice in a row (idempotent).
2. Cold boot with music playing immediately: no output error, no dead chain.
3. 1 h continuous playback, local FLAC + radio, zero `XRUN`/`Broken pipe`.
4. All four pots: volume (DAC only), balance (L/R), bass/treble ±12 dB, live.
5. Analyser feed stays constant level while volume moves.
6. USB card unplugged → DAC-only fallback; replugged → analyser returns.
7. A moOde audio-settings change does not clobber the chain (guard works).
8. Reboot restores everything; an in-place update does not break the chain.
9. Install/uninstall leaves moOde's own config restored.
10. Documentation (README + skill) matches the live moOde box.

---

## 9. Risks and open questions

| Risk | Impact | Mitigation |
|---|---|---|
| Waveshare DSI panel unsupported on moOde 10 | Touch UI lost → migration may not be worth it | M7 go/no-go; fallback: official panel or keep Volumio |
| moOde in-place updates overwrite our hooks | Chain breaks after an update | Guards + re-run installer; verification step after updates |
| CamillaDSP version differences (config format, SIGHUP, volume proxy) | Tone/volume port details change | Pin stable versions; verify against the exact binary on the box |
| Our plugin patches vs moOde's plugin build | Underrun/atomic-write fixes missing | Rebuild our patched plugin for aarch64, back up moOde's |
| "One ALSA DSP at a time" / CamillaDSP off with Multiroom | Our chain is the only DSP; document and keep those options off | Guard could refuse/alert if moOde toggles them |
| 64-bit only | All binaries rebuilt | M1; Docker cross builds are cheap |
| Two SD installs to maintain | Confusion, accidental writes to the wrong card | Label cards; keep Volumio as-is until M8 passes |

---

## 10. References

* moOde audio infrastructure:
  <https://github.com/moode-player/docs/blob/main/moode_audio_infrastructure.md>
* moOde setup guide (10 series): <https://github.com/moode-player/docs/blob/main/setup_guide.md>
* moOde source: <https://github.com/moode-player/moode>
  * `etc/alsa/conf.d/camilladsp.overwrite.conf`, `_audioout.conf`, `_sndaloop.conf`
  * `www/util/cdsp_volume_update.py`, `www/util/mpdconf_merge.py`
  * `www/command/`, `www/daemon/gpio_buttons.py`, `www/relnotes.txt`
* moOde website / releases: <https://moodeaudio.org/>
* scripple `alsa_cdsp`: <https://github.com/scripple/alsa_cdsp>
* CamillaDSP (stable releases + aarch64 binary):
  <https://github.com/HEnquist/camilladsp/releases>
* Volumio design docs in this repo (reference implementation):
  `software/volumio/dual-output/README.md`,
  `software/jukebox-pots/README.md`, `skills/jukebox/SKILL.md`
