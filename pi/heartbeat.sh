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

VER=$(read_json "$MAN" version)
GID=$(read_json "$MAN" groupId)

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

curl -4 -fsS -m 15 -X POST -H "Content-Type: application/json" \
  -d "{\"playerId\":\"${PID}\",\"groupId\":\"${GID}\",\"version\":\"${VER}\",\"hostname\":\"$(hostname)\",\"ip\":\"${IP}\",\"conn\":\"${CONN}\",\"iface\":\"${IFACE}\",\"ssid\":\"${SSID}\"}" \
  "$HB" >/dev/null 2>&1 || true
