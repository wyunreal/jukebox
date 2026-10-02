#!/bin/bash
# jukebox-ui - keep the Volumio touch UI fast and the DSI panel correctly sized.
#
# Idempotent. Re-asserts four things that Volumio or the now_playing plugin can
# otherwise undo, and that were measured to matter a lot on this Pi 4:
#
#   1. Chromium kiosk flags suitable for hardware compositing: drop
#      --disable-gpu-compositing and --disable-3d-apis. With those, Chromium
#      falls back to software compositing and every scroll frame burns CPU.
#      (Measured: scrolling CPU 55% -> 22% of one core just from this.)
#
#   2. Remove --force-renderer-accessibility, which Debian's/RPi's
#      /etc/chromium.d/00-rpi-vars adds by default and which costs work per
#      frame. (Small, plausible win; not isolated in the measurements.)
#
#   3. Lighten the now_playing web client's CSS blur. A full-screen 50px
#      background blur plus 20/30px screen filters are recomputed on the GPU
#      and are very expensive here. (Measured: scrolling CPU 40% -> 11%.)
#
#   4. Turn the phantom HDMI-1 output off so the X screen is the native
#      800x480 DSI panel. Volumio forces HDMI on (hdmi_force_hotplug), making
#      the virtual screen 848px wide: the right ~48px of the panel are clipped
#      and the touch mapping is ~6% off. HDMI here carries no audio or video
#      we use (audio is the I2S DAC + USB second output).
#
# The systemd .path unit re-runs "apply" when Volumio rewrites these files
# (e.g. saving a setting on the Touch Display page regenerates
# /opt/volumiokiosk.sh).
#
# Usage: jukebox-ui.sh [apply|status|verify]

set -u

KIOSK=${JUKEBOX_UI_KIOSK:-/opt/volumiokiosk.sh}
CHROMIUM_D=${JUKEBOX_UI_CHROMIUM_D:-/etc/chromium.d/00-rpi-vars}
NP_CSS_DIR=${JUKEBOX_UI_NP_CSS_DIR:-/data/plugins/user_interface/now_playing/dist/app/client/build/static/css}
LOG=${JUKEBOX_UI_LOG:-/var/log/jukebox-ui.log}
DISPLAY_NUM=${JUKEBOX_UI_DISPLAY:-0}
HDMI_OUT=${JUKEBOX_UI_HDMI_OUT:-HDMI-1}

CHANGED=0
cmd=${1:-apply}

log() { echo "$(date '+%F %T') [$cmd] $*" >>"$LOG" 2>/dev/null || true; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "jukebox-ui: must run as root" >&2
    exit 1
  fi
}

xauth_path() {
  ps -eo args= 2>/dev/null | grep -oE '/tmp/serverauth\.[A-Za-z0-9_.-]+' | head -1
}

# --- patches -----------------------------------------------------------------

patch_kiosk() {
  [ -f "$KIOSK" ] || { log "no $KIOSK (skipping)"; return 0; }
  local b a
  b=$(md5sum "$KIOSK" | cut -d' ' -f1)

  # Drop the software-compositing flags. Match the flags, not whole lines, in
  # case the plugin put something else on the same line.
  sed -i -e 's/--disable-gpu-compositing//g' -e 's/--disable-3d-apis//g' "$KIOSK"

  # Ensure the HDMI output is turned off right after the window manager starts,
  # i.e. inside the X session, before Chromium maps its window.
  if ! grep -q 'jukebox-ui:hdmi-off' "$KIOSK"; then
    sed -i "\|^openbox-session &$|a xrandr --output $HDMI_OUT --off 2>/dev/null  # jukebox-ui:hdmi-off" "$KIOSK"
  fi

  a=$(md5sum "$KIOSK" | cut -d' ' -f1)
  if [ "$b" != "$a" ]; then log "patched $KIOSK"; CHANGED=1; fi
}

patch_chromium() {
  [ -f "$CHROMIUM_D" ] || { log "no $CHROMIUM_D (skipping)"; return 0; }
  local b a
  b=$(md5sum "$CHROMIUM_D" | cut -d' ' -f1)
  sed -i 's/ --force-renderer-accessibility//g' "$CHROMIUM_D"
  a=$(md5sum "$CHROMIUM_D" | cut -d' ' -f1)
  if [ "$b" != "$a" ]; then log "patched $CHROMIUM_D"; CHANGED=1; fi
}

patch_css() {
  local f b a
  for f in "$NP_CSS_DIR"/main.*.css; do
    [ -f "$f" ] || continue
    b=$(md5sum "$f" | cut -d' ' -f1)
    sed -i \
      -e 's/--default-background-blur:50px/--default-background-blur:10px/' \
      -e 's/--browse-screen-background-filter:blur(20px)/--browse-screen-background-filter:blur(8px)/' \
      -e 's/--queue-screen-background-filter:blur(20px)/--queue-screen-background-filter:blur(8px)/' \
      -e 's/--browse-screen-header-background-image-filter:blur(30px)/--browse-screen-header-background-image-filter:blur(10px)/' \
      "$f"
    a=$(md5sum "$f" | cut -d' ' -f1)
    if [ "$b" != "$a" ]; then log "patched $f"; CHANGED=1; fi
  done
}

# --- live actions ------------------------------------------------------------

xrandr_hdmi_off() {
  local auth
  auth=$(xauth_path)
  [ -n "$auth" ] || return 0
  DISPLAY=":$DISPLAY_NUM" XAUTHORITY="$auth" \
    xrandr --output "$HDMI_OUT" --off >/dev/null 2>&1 || true
}

# --- commands ----------------------------------------------------------------

apply() {
  require_root
  CHANGED=0
  patch_kiosk
  patch_chromium
  patch_css

  if [ "$CHANGED" = 1 ]; then
    log "restarting volumio-kiosk.service"
    systemctl restart volumio-kiosk.service >/dev/null 2>&1 || true
    # wait for the X server to come back (best effort)
    for _ in $(seq 1 30); do pgrep -x Xorg >/dev/null 2>&1 && break; sleep 1; done
  fi

  xrandr_hdmi_off
  log "applied (changed=$CHANGED)"
  status
}

status() {
  echo "=== jukebox-ui status ==="
  if [ -f "$KIOSK" ]; then
    if grep -qE -- '--disable-gpu-compositing|--disable-3d-apis' "$KIOSK"; then
      echo "kiosk compositing flags : PRESENT (bad)"
    else
      echo "kiosk compositing flags : absent (ok)"
    fi
    if grep -q 'jukebox-ui:hdmi-off' "$KIOSK"; then
      echo "kiosk HDMI-off hook     : present"
    else
      echo "kiosk HDMI-off hook     : MISSING"
    fi
  else
    echo "kiosk script            : MISSING ($KIOSK)"
  fi

  if [ -f "$CHROMIUM_D" ] && grep -q force-renderer-accessibility "$CHROMIUM_D" 2>/dev/null; then
    echo "chromium.d accessibility: PRESENT (bad)"
  else
    echo "chromium.d accessibility: absent (ok)"
  fi

  local f
  for f in "$NP_CSS_DIR"/main.*.css; do
    [ -f "$f" ] || continue
    echo "css $(basename "$f")      : $(grep -oE -- '--default-background-blur:[0-9]+px' "$f" | head -1)"
  done

  local auth
  auth=$(xauth_path)
  if [ -n "$auth" ]; then
    echo "X screen/outputs        :"
    DISPLAY=":$DISPLAY_NUM" XAUTHORITY="$auth" xrandr 2>/dev/null | grep -E 'Screen 0|connected' | sed 's/^/    /'
  else
    echo "X screen/outputs        : (no X server / auth found)"
  fi
}

verify() {
  local rc=0
  echo "=== jukebox-ui verify ==="
  if grep -qE -- '--disable-gpu-compositing|--disable-3d-apis' "$KIOSK" 2>/dev/null; then
    echo "FAIL: kiosk still has software-compositing flags"; rc=1
  else
    echo "ok  : kiosk compositing flags absent"
  fi
  if grep -q force-renderer-accessibility "$CHROMIUM_D" 2>/dev/null; then
    echo "FAIL: --force-renderer-accessibility still present"; rc=1
  else
    echo "ok  : accessibility flag absent"
  fi
  if grep -q 'jukebox-ui:hdmi-off' "$KIOSK" 2>/dev/null; then
    echo "ok  : kiosk HDMI-off hook present"
  else
    echo "FAIL: kiosk HDMI-off hook missing"; rc=1
  fi
  local f found=0
  for f in "$NP_CSS_DIR"/main.*.css; do
    [ -f "$f" ] || continue; found=1
    if grep -q -- '--default-background-blur:10px' "$f"; then
      echo "ok  : css blur lightened ($(basename "$f"))"
    else
      echo "FAIL: css blur not lightened ($(basename "$f"))"; rc=1
    fi
  done
  [ "$found" = 1 ] || echo "warn: now_playing css not found"

  local auth
  auth=$(xauth_path)
  if [ -n "$auth" ]; then
    local line
    line=$(DISPLAY=":$DISPLAY_NUM" XAUTHORITY="$auth" xrandr 2>/dev/null | grep -E 'Screen 0')
    if echo "$line" | grep -q '800 x 480'; then
      echo "ok  : X screen is 800x480 (native DSI)"
    else
      echo "warn: X screen not 800x480 -> $line"
    fi
  fi
  return $rc
}

case "$cmd" in
  apply)  apply ;;
  status) status ;;
  verify) verify ;;
  *) echo "usage: $0 [apply|status|verify]" >&2; exit 2 ;;
esac
