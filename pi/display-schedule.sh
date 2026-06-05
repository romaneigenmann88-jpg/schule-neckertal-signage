#!/bin/sh
# Schule Neckertal Signage – Bildschirm-Zeitsteuerung (HDMI-Off via CEC).
# Liest Zeitplan + offMode aus dem aktiven Manifest. Nur wenn offMode=hdmi_off:
# sendet ausserhalb der Betriebszeit CEC-Standby an den Bildschirm und innerhalb
# CEC-"Einschalten". CEC ist der zuverlässige Weg für Fernseher/Displays.
#
# Auf Geräten OHNE CEC (z. B. PC-Monitore) bleibt das wirkungslos und stört
# NICHT (kein Flackern). Der Browser-Player zeigt zusätzlich Black-Screen als
# universellen Fallback.

MAN="${SIGNAGE_MANIFEST:-/opt/school-signage/web/content/manifest.json}"
CEC="${SIGNAGE_CEC:-/dev/cec0}"

desired=$(python3 - "$MAN" <<'PY'
import sys, json, datetime
try:
    d = json.load(open(sys.argv[1]))
    sch = d.get("schedule", {})
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
