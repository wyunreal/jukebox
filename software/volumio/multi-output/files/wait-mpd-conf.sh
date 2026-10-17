#!/bin/bash
# jukebox-audio: wait for a complete /etc/mpd.conf before MPD starts.
#
# Volumio writes /etc/mpd.conf asynchronously (its createMPDFile() calls its
# callback before fs.writeFile() finishes) and immediately restarts MPD. MPD
# can then read a truncated/empty config -- no audio_output, no db_file -- and
# comes up silent with an empty library until a manual restart. This runs as
# MPD's ExecStartPre and waits until the file looks complete and has stopped
# changing, so MPD only ever reads a finished file.
#
# Best effort: it always exits 0 and never waits more than MAX_WAIT seconds, so
# a missing/broken Volumio can never wedge playback.
set -u

conf="${1:-/etc/mpd.conf}"
max_wait="${2:-15}"   # seconds we are willing to wait
settle=0.4            # required stillness once the file looks complete

deadline=$(( $(date +%s) + max_wait ))
last=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -s "$conf" ] && grep -q 'audio_output' "$conf" 2>/dev/null; then
    m="$(stat -c '%Y.%s' "$conf" 2>/dev/null || echo x)"
    # Require the file to be unchanged across one settle interval (the writer
    # has stopped) before letting MPD read it.
    if [ "$m" = "$last" ]; then
      exit 0
    fi
    last="$m"
    sleep "$settle"
  else
    sleep 0.1
  fi
done
exit 0
