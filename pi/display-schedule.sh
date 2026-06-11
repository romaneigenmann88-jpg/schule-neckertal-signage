#!/bin/sh
# Schule Neckertal Signage - Bildschirm-Zeitsteuerung (HDMI-Aus).
# Schaltet den HDMI-Ausgang ausserhalb der Betriebszeit per DPMS aus (wlopm),
# damit das Display "kein Signal" sieht und in Standby geht - funktioniert auf
# JEDEM Monitor/TV (das moderne Pendant zu Yodecks tvservice/Signal-Aus).
# Zusaetzlich CEC-Standby fuer echte TVs (auf Geraeten ohne CEC harmlos).
#
# Quelle des Zeitplans: bevorzugt der Worker (Live-Einstellungen), sonst das
# aktive Manifest. Nur aktiv, wenn offMode=hdmi_off. Bei offMode=black_screen
# uebernimmt der Player das Schwarzschalten (hier dann nichts tun).
#
# Aufruf:
#   display-schedule.sh        -> nach Zeitplan an/aus
#   display-schedule.sh on|off -> manuell (Wartung/Test)

MAN="${SIGNAGE_MANIFEST:-/opt/school-signage/web/content/manifest.json}"
DEV="${SIGNAGE_DEVICE:-/opt/school-signage/config/device.json}"
CEC="${SIGNAGE_CEC:-/dev/cec0}"
OUTPUT="${SIGNAGE_OUTPUT:-HDMI-A-1}"

# Wayland-Umgebung (der Dienst laeuft ausserhalb der grafischen Session).
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ -z "$WAYLAND_DISPLAY" ]; then
  WAYLAND_DISPLAY=$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -m1 '^wayland-[0-9]$')
  export WAYLAND_DISPLAY
fi

screen_off() {
  command -v wlopm >/dev/null 2>&1 && wlopm --off "$OUTPUT" >/dev/null 2>&1
  if [ -e "$CEC" ] && command -v cec-ctl >/dev/null 2>&1; then
    cec-ctl -d "$CEC" --playback >/dev/null 2>&1
    cec-ctl -d "$CEC" --to 0 --standby >/dev/null 2>&1
  fi
}
screen_on() {
  command -v wlopm >/dev/null 2>&1 && wlopm --on "$OUTPUT" >/dev/null 2>&1
  if [ -e "$CEC" ] && command -v cec-ctl >/dev/null 2>&1; then
    cec-ctl -d "$CEC" --playback >/dev/null 2>&1
    cec-ctl -d "$CEC" --to 0 --image-view-on >/dev/null 2>&1
  fi
}

# Manuelle Uebersteuerung (Wartung/Test)
case "$1" in
  on)  screen_on;  exit 0 ;;
  off) screen_off; exit 0 ;;
esac

# Zeitplan bestimmen: Worker bevorzugt, sonst Manifest.
HB=$(python3 -c "import json;print(json.load(open('$DEV')).get('heartbeatUrl',''))" 2>/dev/null || echo "")
GID=$(python3 -c "import json;print(json.load(open('$MAN')).get('groupId',''))" 2>/dev/null || echo "")
SETTINGS=""
if [ -n "$HB" ] && [ -n "$GID" ]; then
  SETTINGS=$(curl -fsS --max-time 5 "$HB/settings/$GID?t=$(date +%s)" 2>/dev/null || echo "")
fi

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
    s = data.get("settings", data)
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

case "$desired" in
  off) screen_off ;;
  on)  screen_on ;;
  *)   exit 0 ;;   # skip
esac
