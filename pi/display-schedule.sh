#!/bin/sh
# Schule Neckertal Signage – Bildschirm-Zeitsteuerung (HDMI-Off).
# Liest Zeitplan + offMode aus dem aktiven Manifest. Nur wenn offMode=hdmi_off:
# schaltet den HDMI-Ausgang ausserhalb der Betriebszeit aus (echter Standby)
# und innerhalb wieder an. Idempotent (schaltet nur bei Zustandswechsel).

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
MAN="${SIGNAGE_MANIFEST:-/opt/school-signage/web/content/manifest.json}"
OUTPUT="${SIGNAGE_OUTPUT:-HDMI-A-1}"

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
    print("on")   # im Zweifel Bildschirm an lassen
PY
)

[ "$desired" = "skip" ] && exit 0

# aktuellen Zustand des Ausgangs ermitteln (yes/no)
cur=$(wlr-randr 2>/dev/null | awk -v o="$OUTPUT" '$0 ~ "^"o" " {f=1} f && /Enabled/ {print $2; exit}')

case "$desired" in
  off) [ "$cur" = "no" ]  || { wlr-randr --output "$OUTPUT" --off && echo "HDMI $OUTPUT -> aus"; } ;;
  on)  [ "$cur" = "yes" ] || { wlr-randr --output "$OUTPUT" --on  && echo "HDMI $OUTPUT -> an"; } ;;
esac
