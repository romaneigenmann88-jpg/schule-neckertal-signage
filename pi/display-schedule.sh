#!/bin/sh
# Schule Neckertal Signage – Bildschirm-Zeitsteuerung (HDMI-Off via CEC).
# Liest Zeitplan + offMode. Quelle bevorzugt der Worker (Live-Einstellungen aus
# der Admin-Konsole), sonst das aktive Manifest als Fallback. Nur wenn
# offMode=hdmi_off: sendet ausserhalb der Betriebszeit CEC-Standby und innerhalb
# CEC-"Einschalten". CEC ist der zuverlässige Weg für Fernseher/Displays.
#
# Auf Geräten OHNE CEC (z. B. PC-Monitore) bleibt das wirkungslos und stört
# NICHT (kein Flackern). Der Browser-Player zeigt zusätzlich Black-Screen als
# universellen Fallback.

MAN="${SIGNAGE_MANIFEST:-/opt/school-signage/web/content/manifest.json}"
DEV="${SIGNAGE_DEVICE:-/opt/school-signage/config/device.json}"
CEC="${SIGNAGE_CEC:-/dev/cec0}"

# Worker-URL + groupId bestimmen, dann Live-Einstellungen ziehen (best effort).
HB=$(python3 -c "import json;print(json.load(open('$DEV')).get('heartbeatUrl',''))" 2>/dev/null || echo "")
GID=$(python3 -c "import json;print(json.load(open('$MAN')).get('groupId',''))" 2>/dev/null || echo "")
SETTINGS=""
if [ -n "$HB" ] && [ -n "$GID" ]; then
  SETTINGS=$(curl -fsS --max-time 5 "$HB/settings/$GID?t=$(date +%s)" 2>/dev/null || echo "")
fi

# desired = on|off|skip. Nimmt den Zeitplan aus den Worker-Einstellungen, wenn
# vorhanden, sonst aus dem Manifest. "skip" wenn offMode != hdmi_off.
desired=$(SETTINGS_JSON="$SETTINGS" python3 - "$MAN" <<'PY'
import sys, os, json, datetime

def schedule_from_settings():
    raw = os.environ.get("SETTINGS_JSON", "").strip()
    if not raw:
        return None
    try:
        data = json.loads(raw)
    except Exception:
        return None
    s = data.get("settings", data)        # GET liefert {groupId,settings,updated}
    sch = s.get("schedule")
    return sch if isinstance(sch, dict) and sch else None

def schedule_from_manifest():
    try:
        return json.load(open(sys.argv[1])).get("schedule", {})
    except Exception:
        return {}

try:
    sch = schedule_from_settings() or schedule_from_manifest()
    if sch.get("offMode") != "hdmi_off":
        print("skip"); raise SystemExit
    now = datetime.datetime.now()
    days = ["monday","tuesday","wednesday","thursday","friday","saturday","sunday"]
    day = sch.get(days[now.weekday()], {})
    on = bool(day.get("active"))
    if on and day.get("from") and day.get("until"):
        cur = now.hour * 60 + now.minute
        fh, fm = map(int, day["from"].split(":"))
        uh, um = map(int, day["until"].split(":"))
        on = (fh * 60 + fm) <= cur < (uh * 60 + um)
    print("on" if on else "off")
except SystemExit:
    raise
except Exception:
    print("on")   # im Zweifel anlassen
PY
)

[ "$desired" = "skip" ] && exit 0
[ -e "$CEC" ] || exit 0
command -v cec-ctl >/dev/null 2>&1 || exit 0

# Pi als Playback-Geraet am CEC-Bus anmelden (idempotent)
cec-ctl -d "$CEC" --playback >/dev/null 2>&1

case "$desired" in
  off) cec-ctl -d "$CEC" --to 0 --standby >/dev/null 2>&1 ;;
  on)  cec-ctl -d "$CEC" --to 0 --image-view-on >/dev/null 2>&1 ;;
esac
