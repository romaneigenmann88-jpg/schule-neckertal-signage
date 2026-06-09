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

curl -fsS -m 15 -X POST -H "Content-Type: application/json" \
  -d "{\"playerId\":\"${PID}\",\"groupId\":\"${GID}\",\"version\":\"${VER}\",\"hostname\":\"$(hostname)\"}" \
  "$HB" >/dev/null 2>&1 || true
