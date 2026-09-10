#!/bin/sh
# Schule Neckertal Signage – Video-Kiosk (mpv, Hardware-Decode).
# ------------------------------------------------------------
# Spielt die lokalen Videos in Endlosschleife, Vollbild, stumm, mit HW-Decode.
# Ersetzt im Video-Modus den Chromium-Kiosk (Chromium nutzt den HW-Decoder nicht
# und ruckelt).
#
# WICHTIG: mpv wird ueber eine PLAYLIST-DATEI (playlist.m3u, ein Pfad pro Zeile)
# gefuettert - so funktionieren auch Dateinamen mit Leerzeichen/Sonderzeichen
# (fruehere Version hat die Liste an Leerzeichen zerlegt -> solche Videos liefen
# nicht). video-sync schreibt die m3u.
#
# Startet mpv neu, wenn sich die Playlist aendert (video-sync) oder mpv beendet.
# Pausierbar via 'kiosk-off' (/tmp/signage-kiosk-stop).

CONTENT="${SIGNAGE_CONTENT_DIR:-/opt/school-signage/web/content}"
M3U="$CONTENT/playlist.m3u"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ -z "$WAYLAND_DISPLAY" ]; then
  WAYLAND_DISPLAY=$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -m1 '^wayland-[0-9]$')
  export WAYLAND_DISPLAY
fi

while [ ! -e /tmp/signage-kiosk-stop ]; do
  if [ ! -s "$M3U" ]; then
    sleep 5                # noch keine Videos -> warten (video-sync erstellt sie)
    continue
  fi
  sig=$(md5sum "$M3U" 2>/dev/null)

  mpv --no-config --really-quiet --fullscreen --no-audio \
      --hwdec=v4l2m2m --vo=gpu \
      --loop-playlist=inf --keep-open=no --idle=no \
      --no-input-default-bindings --input-conf=/dev/null \
      --cursor-autohide=always \
      --playlist="$M3U" &
  MPV=$!

  # Laufen lassen, bis Stop-Flag ODER Playlist-Aenderung.
  while kill -0 "$MPV" 2>/dev/null; do
    if [ -e /tmp/signage-kiosk-stop ]; then kill "$MPV" 2>/dev/null; break; fi
    [ "$(md5sum "$M3U" 2>/dev/null)" != "$sig" ] && { kill "$MPV" 2>/dev/null; break; }
    sleep 5
  done
  wait "$MPV" 2>/dev/null
  sleep 1
done
