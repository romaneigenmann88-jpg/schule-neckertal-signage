#!/bin/sh
# Schule Neckertal Signage – Display-Watchdog.
# ------------------------------------------------------------
# Erkennt einen EINGEFRORENEN Kiosk-Browser (Seite haengt, obwohl der Prozess
# noch laeuft -> der bisherige Autostart-Watchdog greift NICHT, weil chromium
# nicht abstuerzt) und startet ihn neu.
#
# Lebenszeichen (rein lokal, keine Cloud, keine Limits): Der Player fragt den
# lokalen Server jede Minute ab (GET /content/manifest.json -> steht im Journal
# von signage-server). Bleiben diese Anfragen aus, haengt die Seite.
#
# Massnahme: chromium beenden -> der Autostart-Loop (labwc) startet ihn in ~3s neu.
#
# Guards gegen Fehlausloesung / Neustart-Schleifen:
#   - Kiosk absichtlich pausiert (/tmp/signage-kiosk-stop) -> nichts tun
#   - chromium laeuft gar nicht -> Autostart-Loop macht seinen Job -> nichts tun
#   - erst nach STALE_SEC ohne Anfrage eingreifen
#   - COOLDOWN_SEC zwischen zwei Neustarts (frischer Browser braucht ~15s bis GET)
# DRYRUN=1 -> nur melden, NICHT neu starten (zum Testen).

STALE_SEC="${SIGNAGE_DISPLAY_STALE:-300}"        # 5 Min ohne Anfrage = haengt
COOLDOWN_SEC="${SIGNAGE_WATCHDOG_COOLDOWN:-300}" # min. Abstand zweier Neustarts
STAMP="${SIGNAGE_WATCHDOG_STAMP:-/opt/school-signage/config/last-watchdog-restart}"

# Kiosk absichtlich aus (Wartung)? -> raus
[ -e /tmp/signage-kiosk-stop ] && exit 0

# Laeuft ueberhaupt ein chromium? Wenn nicht, ist das Sache des Autostart-Loops.
pgrep chromium >/dev/null 2>&1 || exit 0

# Alter der letzten Browser-Anfrage an den lokalen Server
NOW=$(date +%s)
LASTGET=$(journalctl -u signage-server.service -o short-unix --since "-15min" 2>/dev/null \
          | grep -F "GET /content/manifest.json" | tail -1 | cut -d. -f1)
case "$LASTGET" in ''|*[!0-9]*) AGE=99999 ;; *) AGE=$((NOW - LASTGET)) ;; esac

# Frisch genug -> alles gut
[ "$AGE" -lt "$STALE_SEC" ] && exit 0

# Cooldown: nicht dauernd neu starten
LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
[ $((NOW - LAST)) -lt "$COOLDOWN_SEC" ] && exit 0

logger -t signage-watchdog "Display haengt (seit ${AGE}s keine Browser-Anfrage) -> Chromium-Neustart"
if [ "${DRYRUN:-0}" = "1" ]; then
  echo "[DRYRUN] wuerde Chromium neu starten (AGE=${AGE}s, STALE=${STALE_SEC}s)"
  exit 0
fi
echo "$NOW" > "$STAMP"
pkill chromium 2>/dev/null    # Autostart-Loop startet chromium in ~3s neu
exit 0
