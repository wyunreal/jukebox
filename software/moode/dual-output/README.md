# moOde dual output + tone (jukebox)

Port of the jukebox audio stack to **moOde audio player 10** (64-bit Trixie)
on the same Raspberry Pi 4B. The Volumio implementation stays in
`software/volumio/dual-output/`; this package is the moOde counterpart.

## What moOde already provides

Verified on the live box and in the moOde sources:

* **CamillaDSP 4.1.3** at `/usr/local/bin/camilladsp` (same stable version we
  ship for Volumio), started on demand by the scripple **`cdsp`** ALSA plugin
  declared in `/etc/alsa/conf.d/camilladsp.conf`.
* Active CamillaDSP config is a **symlink**:
  `/usr/share/camilladsp/working_config.yml -> configs/<name>.yml`, selected
  from the WebUI or with the REST command
  `set_cdsp_config <name>` (`http://moode/command/?cmd=...`).
* **Volume type "CamillaDSP"** (`mpdmixer=null` + `camilladsp_volume_sync=on`)
  keeps the knob volume in a CamillaDSP fader, via
  `/usr/local/bin/mpd2cdspvolume` and `statefile.yml`.
* Output chain: MPD → `_audioout` → `peppy` (softvol + meter) →
  `_peppyout` → `plughw:<card>,0`; `_peppyout` is rewritten by moOde on
  every output change (`inc/audio.php`).
* GPIO rotary encoder support for the volume knob (not used by us).

Because the plugin runs CamillaDSP **as a child of MPD** and the whole DAC
branch passes through it, the jukebox tone (bass/treble shelves) and the
balance can live in the CamillaDSP pipeline and be changed live with
`SIGHUP`, exactly like on Volumio.

## Target chain

```
MPD ──► _audioout ──► peppy (moOde softvol/meter, untouched)
                            │
                  jukeboxTone (cdsp → CamillaDSP)      [DAC branch]
                     │            └─ pipeline: L/R balance gain + bass + treble
                     └─► plughw:CARD=<dac>,0            [speakers]

                  jukeboxAnalyser (optional low-shelf)
                     └─► plughw:CARD=<usb>,0            [spectrum analyser, fixed]
```

The split itself is a small ALSA `multi` override; the CamillaDSP config
carries the tone and balance. The analyser branch bypasses CamillaDSP so its
level is never touched by volume/tone.

## Status

- [x] M0/M1 — inventory: moOde already ships stable CamillaDSP 4.1.3 + cdsp
      (aarch64); native `gcc` + `libasound2-dev` available on the box.
- [x] M1b — patched cdsp plugin built natively on the Pi and installed
      (underrun concealment; atomic config write).
- [x] M2 — ALSA split override (`_audioout` -> `jukeboxSplit`) + guard unit,
      verified: moOde rewrites are re-asserted and playback survives.
- [x] M3 — tone config (`jukebox-tone.yml`) with live gain rewrite + SIGHUP,
      verified while playing.
- [x] M4 — volume type CamillaDSP (moOde knob -> fader, analyser untouched),
      balance as per-channel gain filters, verified.
- [x] M5 — jukebox-pots with moOde backend (`vol.sh` + CamillaDSP balance).
- [x] M6 — guards, DAC-only fail-safe when the analyser card is absent, 3 s
      MPD buffer, cold-boot test passed (chain + pots up on their own).
- [ ] M7 — touch UI (go/no-go).
- [ ] M8 — clean-room validation from a fresh moOde SD.
- [ ] M9 — docs/skill updates for the moOde box.

### Verified on the box (2026-10-02)

* DAC + USB analyser both `RUNNING` simultaneously while playing a local FLAC
  and radio streams.
* `mpc`/moOde volume 50% -> CamillaDSP `volume[0] = -30.0 dB`; both outputs
  stay running; the analyser is never attenuated.
* Tone/balance rewrite: `gain:` values in `jukebox-tone.yml` changed and
  reloaded via SIGHUP with no playback interruption.
* Guard: manually reverting `_audioout.conf` to `"peppy"` is re-asserted back
  to `"jukeboxSplit"` within seconds, playback uninterrupted.
* Fail-safe: with the USB card absent, the chain falls back to DAC-only
  (`_audioout -> camilladsp`) and restores the split when it returns.
* Cold boot: after `moodeutl --reboot`, the chain, tone config, guard and
  `jukebox-pots` come up on their own; playback works without intervention.

## Design notes

* **Do not fight the moOde updater.** Anything moOde rewrites (`_peppyout.conf`,
  `working_config.yml`, `mpd.conf`) is re-asserted by a guard unit, the same
  pattern as `software/volumio/dual-output`.
* **Stable versions only.** CamillaDSP must stay at the stable release moOde
  ships; never swap in a development build.
* **The plugin must not assert DTR** on the Arduino serial port (it would
  reset the power state machine).

## Install

```sh
# from the repo root (dev machine):
cd software/moode/dual-output
bash deploy.sh install --second-output usb
```

See `docs/moode-port-plan.md` for the full milestone plan and
`software/jukebox-pots/README.md` for the pot daemon (shared backend).
