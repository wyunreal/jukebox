#!/usr/bin/env bash
#
# apply.sh - (re)inject the jukebox overlay loader into the Volumio UI pages.
#
# Idempotent.  Each UI's index.html gets a tiny loader <script> just before
# </body> that pulls http://<host>:3210/overlay.js.  Safe to run any time a
# Volumio update (or a UI switch) replaces those files; the systemd .path unit
# does exactly that automatically.
#
set -euo pipefail

PORT="${JK_OVERLAY_PORT:-3210}"

python3 - "$PORT" <<'PY'
import glob
import sys

port = sys.argv[1]
loader = (
    '<script id="jk-overlay-loader">(function(){var s=document.createElement("script");'
    's.src="http://"+(location.hostname||"localhost")+":%s/overlay.js";'
    'document.head.appendChild(s);})();</script>' % port
)

for f in sorted(glob.glob("/volumio/http/www*/index.html")):
    try:
        s = open(f, encoding="utf-8").read()
    except OSError:
        continue
    if "jk-overlay-loader" in s:
        continue
    if "</body>" in s:
        s = s.replace("</body>", loader + "</body>", 1)
    else:
        s += loader
    open(f, "w", encoding="utf-8").write(s)
    print("injected " + f)
PY
