#!/usr/bin/env bash
# ============================================================
# Schule Neckertal – Digital Signage
# Raspberry-Pi-Installationsskript (Kiosk-Player + Sync)
# ------------------------------------------------------------
# Richtet einen Raspberry Pi (Pi OS Bookworm/Trixie, labwc/Wayland)
# als Vollbild-Kiosk-Player ein:
#   - App-Dateien in web/, Inhalte (synchronisiert) in data/<version>/
#   - lokaler HTTP-Server (systemd) liefert web/
#   - Sync-Agent (systemd-Timer alle 5 Min) holt Inhalte von GitHub Pages
#   - Chromium im Kioskmodus mit Watchdog (Autostart via labwc)
#   - Chromium-Policy, Bildschirm-Blanking aus, optionaler täglicher Reboot
#
# Idempotent. Aufruf im Repo:  bash pi/install.sh
# ============================================================
set -euo pipefail

# ---------- Parameter (per Umgebungsvariable überschreibbar) ----------
SIGNAGE_USER="${SIGNAGE_USER:-$(id -un)}"
PLAYER_ID="${PLAYER_ID:-$(hostname)}"
PORT="${SIGNAGE_PORT:-8099}"
INSTALL_DIR="${INSTALL_DIR:-/opt/school-signage}"
DAILY_REBOOT="${DAILY_REBOOT:-04:00}"              # "" = täglichen Reboot aus
OUTPUT="${SIGNAGE_OUTPUT:-HDMI-A-1}"
MANIFEST_URL="${MANIFEST_URL:-https://romaneigenmann88-jpg.github.io/schule-neckertal-signage/groups/OZN_EINGANG/manifest.json}"
HEARTBEAT_URL="${HEARTBEAT_URL:-https://signage-heartbeat.schule-neckertal.workers.dev}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
USER_HOME="$(getent passwd "$SIGNAGE_USER" | cut -d: -f6)"

echo "== Schule Neckertal Signage – Installation =="
echo "Benutzer:    $SIGNAGE_USER"
echo "PlayerId:    $PLAYER_ID"
echo "Port:        $PORT"
echo "Zielverz.:   $INSTALL_DIR"
echo "Manifest:    $MANIFEST_URL"
echo

if [ ! -d "$REPO_ROOT/player" ]; then
  echo "FEHLER: $REPO_ROOT/player nicht gefunden. Skript im Repo ausführen (bash pi/install.sh)." >&2
  exit 1
fi

# ---------- 1. Pakete ----------
echo "[1/10] Pakete installieren ..."
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  chromium python3 grim wlr-randr v4l-utils fonts-comfortaa >/dev/null 2>&1 || \
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  chromium-browser python3 grim wlr-randr v4l-utils fonts-comfortaa >/dev/null

# ---------- 2. Verzeichnisse ----------
echo "[2/10] Verzeichnisse anlegen ..."
sudo mkdir -p "$INSTALL_DIR"
sudo chown -R "$SIGNAGE_USER:$SIGNAGE_USER" "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"/web "$INSTALL_DIR"/data "$INSTALL_DIR"/config "$INSTALL_DIR"/logs "$INSTALL_DIR"/bin

# ---------- 3. App-Dateien (web/) ----------
echo "[3/10] App-Dateien kopieren ..."
cp "$REPO_ROOT/player/index.html" "$REPO_ROOT/player/app.js" "$REPO_ROOT/player/style.css" "$INSTALL_DIR/web/"

# ---------- 4. Sync-Agent ----------
echo "[4/10] Sync-Agent ..."
cp "$REPO_ROOT/pi/sync.py" "$INSTALL_DIR/bin/sync.py"
chmod +x "$INSTALL_DIR/bin/sync.py"
cp "$REPO_ROOT/pi/display-schedule.sh" "$INSTALL_DIR/bin/display-schedule.sh"
chmod +x "$INSTALL_DIR/bin/display-schedule.sh"
cp "$REPO_ROOT/pi/heartbeat.sh" "$INSTALL_DIR/bin/heartbeat.sh"
chmod +x "$INSTALL_DIR/bin/heartbeat.sh"
cp "$REPO_ROOT/pi/command-poll.sh" "$INSTALL_DIR/bin/command-poll.sh"
chmod +x "$INSTALL_DIR/bin/command-poll.sh"
# Nur kuenftige Befehle ausfuehren (Zeitstempel jetzt als Basislinie)
date +%s%3N > "$INSTALL_DIR/config/last-command-ts"

# ---------- 5. device.json (Konfiguration) ----------
echo "[5/10] Konfiguration (device.json) ..."
cat > "$INSTALL_DIR/config/device.json" <<JSON
{
  "playerId": "$PLAYER_ID",
  "manifestUrl": "$MANIFEST_URL",
  "heartbeatUrl": "$HEARTBEAT_URL",
  "dataDir": "$INSTALL_DIR/data",
  "webDir": "$INSTALL_DIR/web",
  "keepVersions": 3,
  "checkIntervalSeconds": 300
}
JSON

# ---------- 6. Lokaler HTTP-Server (systemd) ----------
echo "[6/10] Dienst signage-server ..."
sudo tee /etc/systemd/system/signage-server.service >/dev/null <<UNIT
[Unit]
Description=Schule Neckertal Signage - lokaler HTTP-Server (web/)
After=network.target

[Service]
Type=simple
User=$SIGNAGE_USER
ExecStart=/usr/bin/python3 -m http.server $PORT --bind 127.0.0.1 --directory $INSTALL_DIR/web
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

# ---------- 7. Sync-Dienst + Timer (alle 5 Minuten) ----------
echo "[7/10] Sync-Timer (alle 5 Min) ..."
sudo tee /etc/systemd/system/signage-sync.service >/dev/null <<UNIT
[Unit]
Description=Schule Neckertal Signage - Inhalts-Sync
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$SIGNAGE_USER
ExecStart=/usr/bin/python3 $INSTALL_DIR/bin/sync.py
UNIT
sudo tee /etc/systemd/system/signage-sync.timer >/dev/null <<'UNIT'
[Unit]
Description=Schule Neckertal Signage - Inhalts-Sync alle 5 Minuten

[Timer]
OnBootSec=1min
OnUnitActiveSec=3min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

# Bildschirm-Zeitsteuerung (HDMI-Off ausserhalb Betriebszeit, wenn offMode=hdmi_off)
sudo tee /etc/systemd/system/signage-display.service >/dev/null <<UNIT
[Unit]
Description=Schule Neckertal Signage - HDMI-Zeitsteuerung
After=graphical.target

[Service]
Type=oneshot
User=$SIGNAGE_USER
ExecStart=/bin/sh $INSTALL_DIR/bin/display-schedule.sh
UNIT
sudo tee /etc/systemd/system/signage-display.timer >/dev/null <<'UNIT'
[Unit]
Description=Schule Neckertal Signage - HDMI-Zeitsteuerung jede Minute

[Timer]
OnBootSec=40s
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

# Heartbeat (meldet Status an den Sammelpunkt, alle 5 Min)
sudo tee /etc/systemd/system/signage-heartbeat.service >/dev/null <<UNIT
[Unit]
Description=Schule Neckertal Signage - Heartbeat
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$SIGNAGE_USER
ExecStart=/bin/sh $INSTALL_DIR/bin/heartbeat.sh
UNIT
sudo tee /etc/systemd/system/signage-heartbeat.timer >/dev/null <<'UNIT'
[Unit]
Description=Schule Neckertal Signage - Heartbeat alle 5 Minuten

[Timer]
OnBootSec=50s
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

# Fernwartungs-Poller (holt Befehle aus der Admin-Konsole, alle 20s)
sudo tee /etc/systemd/system/signage-command.service >/dev/null <<UNIT
[Unit]
Description=Schule Neckertal Signage - Fernwartungs-Befehle
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$SIGNAGE_USER
# Nicht die Kindprozesse killen, wenn der Dienst endet – sonst wuerde ein per
# 'kiosk-on' frisch gestarteter Chromium sofort wieder beendet.
KillMode=process
ExecStart=/bin/sh $INSTALL_DIR/bin/command-poll.sh
UNIT
sudo tee /etc/systemd/system/signage-command.timer >/dev/null <<'UNIT'
[Unit]
Description=Schule Neckertal Signage - Befehle alle 20 Sekunden

[Timer]
OnBootSec=30s
OnUnitActiveSec=20s
AccuracySec=2s

[Install]
WantedBy=timers.target
UNIT

# sudoers: erlaubt dem Player-Benutzer NUR den Neustart ohne Passwort
# (fuer den Fernwartungs-Befehl "reboot"; sonst nichts).
echo "$SIGNAGE_USER ALL=(root) NOPASSWD: /sbin/reboot" | sudo tee /etc/sudoers.d/signage-reboot >/dev/null
sudo chmod 440 /etc/sudoers.d/signage-reboot

# ---------- 8. Chromium-Policy + Kiosk-Autostart (Watchdog) + Blanking ----------
echo "[8/10] Chromium-Policy, Kiosk-Autostart, Blanking ..."
sudo mkdir -p /etc/chromium/policies/managed
sudo tee /etc/chromium/policies/managed/signage.json >/dev/null <<'JSON'
{
  "TranslateEnabled": false,
  "BackgroundModeEnabled": false,
  "DefaultBrowserSettingEnabled": false,
  "MetricsReportingEnabled": false,
  "BrowserSignin": 0,
  "PasswordManagerEnabled": false
}
JSON

mkdir -p "$USER_HOME/.config/labwc"
cat > "$USER_HOME/.config/labwc/autostart" <<AUTO
#!/bin/sh
# Schule Neckertal Signage - Kiosk-Autostart (labwc/Wayland) mit Watchdog.
# Pausierbar fuer Wartung: 'kiosk-off' (zum Desktop) / 'kiosk-on' (zurueck).
# Cache beim Start leeren, damit Code-Updates nach Neustart/Reboot greifen
# (KEIN --incognito: das wird durch die Managed-Policy blockiert -> Crash-Loop).
rm -rf "\$HOME/.cache/chromium" "\$HOME/.config/chromium/Default/Cache" "\$HOME/.config/chromium/Default/Code Cache" 2>/dev/null
(
  while [ ! -e /tmp/signage-kiosk-stop ]; do
    chromium --kiosk --ozone-platform=wayland --noerrdialogs --disable-infobars --disable-session-crashed-bubble --disable-translate --disable-features=Translate,TranslateUI --no-first-run --no-default-browser-check --password-store=basic --check-for-update-interval=31536000 --autoplay-policy=no-user-gesture-required http://localhost:$PORT/ >/dev/null 2>&1
    sleep 3
  done
) &
AUTO
chmod +x "$USER_HOME/.config/labwc/autostart"

# Wartungsbefehle: Kiosk verlassen / zurueck (fuer Updates am Bildschirm)
sudo tee /usr/local/bin/kiosk-off >/dev/null <<'KOFF'
#!/bin/sh
# Stop-Markierung setzen und Chromium ~4s lang wiederholt beenden, bis der
# Watchdog-Loop die Markierung gesehen hat (verhindert sofortiges Neustarten).
touch /tmp/signage-kiosk-stop
i=0
while [ $i -lt 8 ]; do pkill chromium 2>/dev/null; sleep 0.5; i=$((i+1)); done
echo "Kiosk pausiert – du bist auf dem Desktop. Zurueck mit:  kiosk-on"
KOFF
sudo tee /usr/local/bin/kiosk-on >/dev/null <<KON
#!/bin/sh
rm -f /tmp/signage-kiosk-stop
export XDG_RUNTIME_DIR=/run/user/\$(id -u) WAYLAND_DISPLAY=wayland-0
setsid sh "$USER_HOME/.config/labwc/autostart" >/dev/null 2>&1 < /dev/null
echo "Kiosk laeuft wieder."
KON
sudo chmod +x /usr/local/bin/kiosk-off /usr/local/bin/kiosk-on

# Tastenkürzel (labwc): Kiosk ohne Terminal/SSH verlassen und zurück.
#   Strg+Alt+K = kiosk-off (Desktop) · Strg+Alt+O = kiosk-on · Strg+Alt+T = Terminal
# Wir kopieren die System-rc.xml (damit Standard-Keybinds erhalten bleiben) und
# fügen unsere Keybinds direkt nach <default /> ein.
DEFAULT_RC="/etc/xdg/labwc/rc.xml"
USER_RC="$USER_HOME/.config/labwc/rc.xml"
if [ -f "$DEFAULT_RC" ] && [ ! -f "$USER_RC" ]; then
  python3 - "$DEFAULT_RC" "$USER_RC" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
xml = open(src, encoding="utf-8").read()
binds = """    <!-- Schule Neckertal Signage: Kiosk-Wartung ohne Terminal/SSH -->
    <keybind key="C-A-k"><action name="Execute" command="/usr/local/bin/kiosk-off" /></keybind>
    <keybind key="C-A-o"><action name="Execute" command="/usr/local/bin/kiosk-on" /></keybind>
    <keybind key="C-A-t"><action name="Execute" command="x-terminal-emulator" /></keybind>
"""
marker = "<default />"
if marker in xml and "kiosk-off" not in xml:
    xml = xml.replace(marker, marker + "\n" + binds, 1)
open(dst, "w", encoding="utf-8").write(xml)
PY
  echo "    labwc-Tastenkürzel gesetzt (Strg+Alt+K = Kiosk verlassen)."
fi

sudo raspi-config nonint do_blanking 1 || true

# ---------- 9. Optionaler täglicher Reboot ----------
echo "[9/10] Taeglicher Reboot ..."
if [ -n "$DAILY_REBOOT" ]; then
  sudo tee /etc/systemd/system/signage-reboot.service >/dev/null <<'UNIT'
[Unit]
Description=Schule Neckertal Signage - taeglicher Reboot
[Service]
Type=oneshot
ExecStart=/sbin/reboot
UNIT
  sudo tee /etc/systemd/system/signage-reboot.timer >/dev/null <<UNIT
[Unit]
Description=Schule Neckertal Signage - taeglicher Reboot um $DAILY_REBOOT
[Timer]
OnCalendar=*-*-* $DAILY_REBOOT:00
Persistent=false
[Install]
WantedBy=timers.target
UNIT
  sudo systemctl enable signage-reboot.timer >/dev/null 2>&1 || true
  echo "    Taeglicher Reboot um $DAILY_REBOOT aktiviert."
else
  sudo systemctl disable signage-reboot.timer >/dev/null 2>&1 || true
  sudo rm -f /etc/systemd/system/signage-reboot.timer /etc/systemd/system/signage-reboot.service
fi

# ---------- 10. Dienste aktivieren + initialer Sync ----------
echo "[10/10] Dienste aktivieren + initialer Sync ..."
sudo systemctl daemon-reload
sudo systemctl enable signage-server.service >/dev/null
sudo systemctl restart signage-server.service   # restart, damit Unit-Aenderungen greifen

# Initialer Sync ZUERST (vor dem Timer, um Parallelläufe zu vermeiden)
python3 "$INSTALL_DIR/bin/sync.py" || echo "    Initialer Sync (noch) nicht erfolgreich."

# Fallback nur, wenn noch kein Inhalt aktiv ist (z. B. offline bei Erstinstallation)
if [ ! -e "$INSTALL_DIR/web/content" ]; then
  echo "    Kein Inhalt vom Server – Fallback-Inhalt aus Repo (offline-tauglich)."
  mkdir -p "$INSTALL_DIR/data/seed/slides"
  cp "$REPO_ROOT/player/content/manifest.json" "$INSTALL_DIR/data/seed/manifest.json"
  cp "$REPO_ROOT/player/content/slides/"*.png "$INSTALL_DIR/data/seed/slides/" 2>/dev/null || true
  ln -sfn "$INSTALL_DIR/data/seed" "$INSTALL_DIR/web/content"
fi

# Jetzt den Sync-Timer aktivieren (künftige Aktualisierungen alle 5 Min)
sudo systemctl enable --now signage-sync.timer >/dev/null
sudo systemctl enable --now signage-display.timer >/dev/null
sudo systemctl enable --now signage-heartbeat.timer >/dev/null
sudo systemctl enable --now signage-command.timer >/dev/null

echo
echo "== Installation abgeschlossen =="
echo "Lokaler Server:  http://localhost:$PORT/   (Status: $(systemctl is-active signage-server.service))"
echo "Sync-Timer:      $(systemctl is-active signage-sync.timer)"
echo "Aktiver Inhalt:  $(readlink -f "$INSTALL_DIR/web/content" 2>/dev/null || echo '(noch keiner)')"
echo
echo "Jetzt neu starten zum Test:   sudo reboot"
