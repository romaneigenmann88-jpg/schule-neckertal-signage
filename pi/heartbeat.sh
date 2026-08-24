#!/bin/sh
# Schule Neckertal Signage – Heartbeat.
# Meldet playerId, aktive Inhalts-Version und Gruppe an den Sammelpunkt (Worker).
# Die URL steht in device.json (heartbeatUrl); ohne URL passiert nichts.

DEV="${SIGNAGE_DEVICE_JSON:-/opt/school-signage/config/device.json}"
MAN="/opt/school-signage/web/content/manifest.json"

read_json() { python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$1" "$2" 2>/dev/null || echo ""; }

HB=$(read_json "$DEV" heartbeatUrl)
PID=$(read_json "$DEV" playerId)
[ -n "$HB" ] || exit 0

NOW=$(date +%s)

VER=$(read_json "$MAN" version)
GID=$(read_json "$MAN" groupId)
# Wie viele Folien zeigt DIESER Bildschirm gerade? (Soll-Vergleich in der Konsole)
SLIDES=$(python3 -c "import json;print(len(json.load(open('$MAN')).get('baseLayer',{}).get('slides',[])))" 2>/dev/null || echo -1)
case "$SLIDES" in ''|*[!0-9]*) SLIDES=-1 ;; esac
# Fingerabdruck der sichtbaren Folien: aendert sich NUR bei echter
# Inhaltsaenderung (nicht bei blossem Neu-Rendern).
CHASH=$(read_json "$MAN" contentHash)

# Klemmt die Sync-Sperre? (fruehe Ermittlung, fliesst in die Meldeentscheidung)
LOCK="/opt/school-signage/data/.sync.lock"
SYNC_STUCK=0
if [ -f "$LOCK" ] && pgrep -f render-sync.py >/dev/null 2>&1; then
  LOCKAGE=$(( NOW - $(stat -c %Y "$LOCK" 2>/dev/null || echo "$NOW") ))
  [ "$LOCKAGE" -gt 600 ] && SYNC_STUCK=1
fi

# ---- Schreib-Sparbremse fuers KV-Budget (Gratis-Tarif: 1000 Schreibvorgaenge
# pro Tag, und JEDE Meldung ist einer). Zwei Faelle:
#   * Hat sich etwas WICHTIGES geaendert (Inhalt, Folienzahl, Sync klemmt)?
#     -> sofort melden, egal wie kurz die letzte Meldung her ist.
#   * Sonst nur Routine -> hoechstens alle ~30 Min melden.
# So bleiben echte Ereignisse taggenau sichtbar und das Budget reicht auch fuer
# deutlich mehr Bildschirme.
STAMP="${SIGNAGE_HB_STAMP:-/opt/school-signage/config/last-heartbeat-ts}"
SUMFILE="${SIGNAGE_HB_SUMMARY:-/opt/school-signage/config/last-heartbeat-sum}"
MIN_INTERVAL="${SIGNAGE_HB_MIN_INTERVAL:-1740}"   # ~29 Min Routine-Abstand
# WICHTIG: die Render-Version (VER) NICHT einbeziehen - sie aendert sich bei
# jedem Neu-Rendern, auch ohne echte Inhaltsaenderung, und wuerde sonst einen
# Sofort-Versand ausloesen (das war die Ursache der KV-Schreibflut). Der
# contentHash (CHASH) beschreibt den tatsaechlichen Bildinhalt.
SUMMARY="${CHASH}|${SLIDES}|${SYNC_STUCK}"
LASTSUM=$(cat "$SUMFILE" 2>/dev/null || echo "")
LASTHB=$(cat "$STAMP" 2>/dev/null || echo 0)
case "$LASTHB" in ''|*[!0-9]*) LASTHB=0 ;; esac
if [ "$SUMMARY" = "$LASTSUM" ] && [ $((NOW - LASTHB)) -lt "$MIN_INTERVAL" ]; then
  exit 0            # nichts Neues und Routine-Abstand noch nicht erreicht
fi

# Netzwerk-Infos fuer die Admin-Konsole: aktive IP + Verbindungsart (LAN/WLAN).
# Interface + IP aus der Default-Route (das, worueber der Pi wirklich rausgeht).
ROUTE=$(ip route get 1.1.1.1 2>/dev/null)
IFACE=$(printf '%s\n' "$ROUTE" | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)
IP=$(printf '%s\n' "$ROUTE" | sed -n 's/.*src \([^ ]*\).*/\1/p' | head -1)
case "$IFACE" in
  eth*|en*)  CONN="LAN" ;;
  wlan*|wl*) CONN="WLAN" ;;
  "")        CONN="" ;;
  *)         CONN="$IFACE" ;;
esac
SSID=""
if [ "$CONN" = "WLAN" ]; then
  SSID=$(iwgetid -r 2>/dev/null)
  [ -n "$SSID" ] || SSID=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | sed -n 's/^yes://p' | head -1)
  SSID=$(printf '%s' "$SSID" | sed 's/["\\]//g' | cut -c1-32)   # JSON-sicher machen
fi

# Display-Frische: Sekunden seit der letzten Browser-Anfrage an den lokalen
# Server (der Player fragt jede Minute manifest.json ab). Grosser Wert / -1 =
# Bild haengt oder Browser weg. Kostet KEINEN zusaetzlichen KV-Write (reist im
# ohnehin faelligen Heartbeat mit).
LASTGET=$(journalctl -u signage-server.service -o short-unix --since "-30min" 2>/dev/null | grep -F "GET /content/manifest.json" | tail -1 | cut -d. -f1)
case "$LASTGET" in ''|*[!0-9]*) DISPLAY_FRESH=-1 ;; *) DISPLAY_FRESH=$((NOW - LASTGET)) ;; esac

# Sync-Gesundheit: Wann lief render-sync zuletzt ERFOLGREICH durch (egal ob es
# etwas Neues gab)? Und klemmt gerade die Sperre? Damit sieht man in der Konsole
# den Fall "Browser laeuft, aber der Inhalt kommt nicht mehr nach".
LASTSYNC=$(journalctl -u signage-sync.service -o short-unix --since "-24h" 2>/dev/null \
           | grep -E "Keine Aenderung|Aktiv geschaltet" | tail -1 | cut -d. -f1)
case "$LASTSYNC" in ''|*[!0-9]*) SYNC_AGE=-1 ;; *) SYNC_AGE=$((NOW - LASTSYNC)) ;; esac

if curl -4 -fsS -m 15 -X POST -H "Content-Type: application/json" \
  -d "{\"playerId\":\"${PID}\",\"groupId\":\"${GID}\",\"version\":\"${VER}\",\"hostname\":\"$(hostname)\",\"ip\":\"${IP}\",\"conn\":\"${CONN}\",\"iface\":\"${IFACE}\",\"ssid\":\"${SSID}\",\"displayFreshSec\":${DISPLAY_FRESH},\"syncAgeSec\":${SYNC_AGE},\"syncStuck\":${SYNC_STUCK},\"slideCount\":${SLIDES},\"contentHash\":\"${CHASH}\"}" \
  "$HB" >/dev/null 2>&1; then
  echo "$NOW" > "$STAMP"          # nur bei Erfolg als gesendet merken
  printf '%s' "$SUMMARY" > "$SUMFILE"
fi