# jukebox UI command channel

Lets a local daemon ask the **Volumio UI to run a command** (change screen,
toggle favourite). It only carries **UI commands**; it knows nothing about audio
or pots (that is `software/volumio/pot-overlay`'s job). Kept separate on purpose.

Used today by the keyboard's **open/close** key (home ⇄ play queue) and its
**favourite** key (toggle the current favourite, with the UI's heart and toast
reacting).

## How it works

```
daemon (e.g. jukebox-keyboard)  --POST /update-->  jukebox-ui-nav (this package)
                                                       |  Server-Sent Events
                                                       v
                                   Volumio UI  <-- ui-nav.js -> ui-router $state
```

* `ui-nav.py` — dependency-free HTTP/SSE server (stdlib only) on port `3211`.
  Endpoints: `/ui-nav.js`, `/events` (SSE), `/state` (debug), `/update` (POST).
* `ui-nav.js` — injected into the Volumio UI pages. On a command it runs it
  *inside the UI*, so the UI updates itself (routing, the favourite heart, the
  toast):
  - `{"type":"nav","view":"toggle"}` → home ⇄ play queue (`volumio.playback` /
    `volumio.play-queue`); also `"home"` / `"queue"`.
  - `{"type":"ui","action":"favourite"}` → toggle the current track in
    favourites. Music uses Volumio's own `playlistService` path; for
    **webradio** it works around a backend gap (the heart never lights for a
    radio) by reading `/data/favourites/radio-favourites` through the server's
    `/favourite` query and syncing the heart.

  The server also exposes `GET /favourite?service=..&uri=..` → `{"favourite":bool}`,
  used for the webradio workaround.
* `apply.sh` + `jukebox-ui-nav-guard.path` — inject the loader into
  `/volumio/http/www*/index.html` and re-inject after Volumio rewrites them.

## Install

```sh
./deploy.sh --host volumio@<host> install
```

Test the channel by hand:

```sh
curl -sX POST -d '{"type":"nav","view":"toggle"}' http://localhost:3211/update
```

## Notes

* No third-party dependencies (stdlib server; the client uses the UI's own
  Angular router).
* Independent of the keyboard: any daemon can POST to `/update`. The keyboard
  just needs `software/volumio/pot-overlay` **not** installed for this; it
  points at this server instead (`JK_OVERLAY_URL` → `JK_NAV_URL`).
