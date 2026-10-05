# jukebox UI navigation channel

Lets a local daemon ask the **Volumio UI to change screen**. It only carries
navigation; it knows nothing about audio or pots (that is
`software/volumio/pot-overlay`'s job). Kept separate on purpose.

Used today by the keyboard's **open/close** key: on the now-playing home it
opens the **play queue**, and from the play queue it returns **home**.

## How it works

```
daemon (e.g. jukebox-keyboard)  --POST /update-->  jukebox-ui-nav (this package)
                                                       |  Server-Sent Events
                                                       v
                                   Volumio UI  <-- ui-nav.js -> ui-router $state
```

* `ui-nav.py` — dependency-free HTTP/SSE server (stdlib only) on port `3211`.
  Endpoints: `/ui-nav.js`, `/events` (SSE), `/state` (debug), `/update` (POST).
* `ui-nav.js` — injected into the Volumio UI pages. On a navigation command it
  uses the UI's ui-router `$state` service:
  - `{"type":"nav","view":"toggle"}` → home ⇄ play queue
  - `{"type":"nav","view":"home"}` → now-playing (`volumio.playback`)
  - `{"type":"nav","view":"queue"}` → play queue (`volumio.play-queue`)
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
