# jukebox pot overlay

Shows a circular indicator on the Volumio screen when the **balance**, **bass**
or **treble** pot moves — the same look as Volumio's own volume indicator, which
only covers volume.

Volumio knows nothing about balance/bass/treble (the jukebox does those directly
in ALSA and CamillaDSP), so there is no state change for the UI to react to.
This package adds the missing piece: a tiny local server that receives the pot
changes from the `jukebox-pots` daemon and pushes them to the browser.

## How it works

```
jukebox-pots (daemon)  --POST /update-->  jukebox-overlay (this package)
                                              |  Server-Sent Events
                                              v
                              Volumio UI  <-- overlay.js + jQuery-knob
```

* `jukebox-overlay.py` — dependency-free HTTP/SSE server (stdlib only) on port
  `3210`. Endpoints: `/overlay.js`, `/overlay.css`, `/events` (SSE stream),
  `/state` (debug), `/update` (POST from the daemon).
* `overlay.js` — injected into the Volumio UI pages. Reuses Volumio's own
  jQuery-knob plugin and `.knobWrapper` / `.knobInfosWrapper` markup so it
  matches the volume indicator exactly. Shows one knob at a time (like volume):
  `Balance` (`C` / `L n` / `R n`), `Bass ±x.x dB`, `Treble ±x.x dB`.
* `apply.sh` — (re)injects the loader `<script>` into every
  `/volumio/http/www*/index.html`; idempotent.
* `jukebox-overlay-guard.path` — re-runs `apply.sh` when Volumio rewrites those
  pages (updates, UI switches), so the overlay survives.

The daemon side lives in `software/jukebox-pots` (`JP_OVERLAY`,
`JP_OVERLAY_URL`): it POSTs `{"type":"balance","pan":…}`,
`{"type":"bass","db":…}`, `{"type":"treble","db":…}` and only for the pot that
actually changed.

## Install

From a development machine:

```sh
cd software/volumio/pot-overlay
./deploy.sh --host volumio@<host> install
```

Install this **after** `software/jukebox-pots` (or re-run its `install` so the
daemon gets the `JP_OVERLAY` settings).

On the host:

```sh
sudo ./install.sh            # install / re-assert
sudo ./install.sh status
sudo ./install.sh verify
sudo ./install.sh uninstall
```

## Notes

* No third-party dependencies: the server is stdlib Python, and the client
  reuses the jQuery-knob already bundled with the Volumio UI.
* One knob at a time, matching the volume indicator's behaviour (it disappears
  ~3 s after the last change).
* The overlay is best-effort: if it is not installed the daemon's POSTs fail
  fast and are ignored.
* `jk-overlay-guard.path` watches the three `index.html` files; after a Volumio
  update it re-injects automatically.
