#!/bin/sh
# Schule Neckertal Signage – Video-Kiosk (mpv, Hardware-Decode).
# ------------------------------------------------------------
# Spielt die lokalen Videos (web/content/videos/, Reihenfolge = Dateiname) in
# Endlosschleife, Vollbild, stumm, mit HW-Decode (V4L2 M2M). Ersetzt im
# Video-Modus den Chromium-Kiosk - Chromium nutzt den HW-Decoder nicht und
# ruckelt, mpv nicht.
#
# Startet mpv automatisch neu, wenn:
#   - sich die Videoliste aendert (video-sync hat etwas geladen/geloescht),
#   - mpv beendet/abstuerzt,
# und pausiert sauber bei 'kiosk-off' (/tmp/signage-kiosk-stop).

VIDEOS="${SIGNAGE_VIDEOS_DIR:-/opt/school-signage/web/content/videos}"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ -z "$WAYLAND_DISPLAY" ]; then
  WAYLAND_DISPLAY=$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -m1 '^wayland-[0-9]$')
  export WAYLAND_DISPLAY
fi

list_sig() { ls -1 "$VIDEOS"/*.mp4 2>/dev/null | sort | md5sum; }

while [ ! -e /tmp/signage-kiosk-stop ]; do
  # Aktuelle Dateiliste (alphabetisch = gewuenschte Reihenfolge)
  set --
  for f in $(ls -1 "$VIDEOS"/*.mp4 2>/dev/null | sort); do
    set -- "$@" "$f"
  done
  if [ "$#" -eq 0 ]; then
    sleep 5          # noch keine Videos -> warten (video-sync laedt sie)
    continue
  fi

  sig=$(list_sig)
  mpv --no-config --really-quiet --fullscreen --no-audio \
      --hwdec=v4l2m2m --vo=gpu \
      --loop-playlist=inf --keep-open=no --idle=no \
      --no-input-default-bindings --input-conf=/dev/null \
      --cursor-autohide=always \
      "$@" &
  MPV=$!

  # Laufen lassen, bis Stop-Flag gesetzt wird ODER sich die Videoliste aendert.
  while kill -0 "$MPV" 2>/dev/null; do
    if [ -e /tmp/signage-kiosk-stop ]; then kill "$MPV" 2>/dev/null; break; fi
    [ "$(list_sig)" != "$sig" ] && { kill "$MPV" 2>/dev/null; break; }
    sleep 5
  done
  wait "$MPV" 2>/dev/null
  sleep 1            # kurze Pause vor Neustart (verhindert enge Schleife)
done
