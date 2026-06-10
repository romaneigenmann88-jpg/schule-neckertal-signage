#!/bin/sh
# Schule Neckertal Signage – Fernwartungs-Poller.
# Fragt den Worker nach einem Befehl fuer DIESEN Player und fuehrt ihn aus.
# Wird per systemd-Timer alle ~20s aufgerufen. Kein Token noetig.
#
# Befehle (aus der Admin-Konsole):
#   kiosk-off  -> Kiosk verlassen (Desktop)
#   kiosk-on   -> Kiosk wieder starten
#   reboot     -> Neustart
#
# Jeder Befehl hat einen Zeitstempel (ts, in ms). Wir merken uns den zuletzt
# ausgefuehrten ts und fuehren nur NEUERE Befehle aus -> jeder Klick wirkt genau
# einmal, ein erneuter Klick (neuer ts) wirkt erneut.

DEV="${SIGNAGE_DEVICE:-/opt/school-signage/config/device.json}"
LASTF="${SIGNAGE_LAST_CMD:-/opt/school-signage/config/last-command-ts}"

HB=$(python3 -c "import json;print(json.load(open('$DEV')).get('heartbeatUrl',''))" 2>/dev/null || echo "")
PID=$(python3 -c "import json;print(json.load(open('$DEV')).get('playerId',''))" 2>/dev/null || echo "")
[ -n "$HB" ] && [ -n "$PID" ] || exit 0

RESP=$(curl -fsS --max-time 8 "$HB/command/$PID?t=$(date +%s)" 2>/dev/null) || exit 0
ACTION=$(printf '%s' "$RESP" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('action') or '')" 2>/dev/null || echo "")
TS=$(printf '%s' "$RESP" | python3 -c "import sys,json;d=json.load(sys.stdin);print(int(d.get('ts') or 0))" 2>/dev/null || echo 0)
[ -n "$ACTION" ] || exit 0

LAST=$(cat "$LASTF" 2>/dev/null || echo 0)
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
case "$TS"   in ''|*[!0-9]*) TS=0   ;; esac
[ "$TS" -gt "$LAST" ] || exit 0      # nichts Neues

echo "$TS" > "$LASTF"                 # als ausgefuehrt merken (auch vor reboot)

case "$ACTION" in
  kiosk-off) /usr/local/bin/kiosk-off ;;
  kiosk-on)  /usr/local/bin/kiosk-on ;;
  reboot)    sudo /sbin/reboot ;;
esac
