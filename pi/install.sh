#!/usr/bin/env bash
# ============================================================
# Schule Neckertal – Digital Signage
# Raspberry-Pi-Installationsskript (Kiosk-Player)
# ------------------------------------------------------------
# Richtet einen Raspberry Pi (Pi OS Bookworm/Trixie, labwc/Wayland)
# als Vollbild-Kiosk-Player ein:
#   - lokaler HTTP-Server (systemd-Dienst)
#   - Chromium im Kioskmodus mit Watchdog (Autostart via labwc)
#   - Chromium-Policy (keine Übersetzungsleiste etc.)
#   - Bildschirm-Blanking aus
#   - optionaler täglicher Reboot
#
# Das Skript ist idempotent und kann mehrfach ausgeführt werden.
# Aufruf (im geklonten/kopierten Repo):  bash pi/install.sh
# ============================================================
set -euo pipefail

# ---------- Parameter (per Umgebungsvariable überschreibbar) ----------
SIGNAGE_USER="${SIGNAGE_USER:-$(id -un)}"          # Zielbenutzer (Standard: aktueller)
PLAYER_ID="${PLAYER_ID:-$(hostname)}"              # PlayerId (Standard: Hostname)
PORT="${SIGNAGE_PORT:-8099}"                       # Port des lokalen Servers
INSTALL_DIR="${INSTALL_DIR:-/opt/school-signage}"  # Zielverzeichnis
DAILY_REBOOT="${DAILY_REBOOT:-04:00}"              # "" = täglichen Reboot deaktivieren
OUTPUT="${SIGNAGE_OUTPUT:-HDMI-A-1}"               # Wayland-Output (für HDMI-Off, siehe Doku)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
USER_HOME="$(getent passwd "$SIGNAGE_USER" | cut -d: -f6)"

echo "== Schule Neckertal Signage – Installation =="
echo "Benutzer:   $SIGNAGE_USER"
echo "PlayerId:   $PLAYER_ID"
echo "Port:       $PORT"
echo "Zielverz.:  $INSTALL_DIR"
echo "Repo:       $REPO_ROOT"
echo "HDMI-Out:   $OUTPUT"
echo

if [ ! -d "$REPO_ROOT/player" ]; then
  echo "FEHLER: $REPO_ROOT/player nicht gefunden. Skript im Repo ausführen (bash pi/install.sh)." >&2
  exit 1
fi

# ---------- 1. Pakete ----------
echo "[1/9] Pakete installieren ..."
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  chromium python3 grim wlr-randr fonts-comfortaa >/dev/null 2>&1 || \
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  chromium-browser python3 grim wlr-randr fonts-comfortaa >/dev/null

# ---------- 2. Verzeichnisse ----------
echo "[2/9] Verzeichnisse anlegen ..."
sudo mkdir -p "$INSTALL_DIR"
sudo chown -R "$SIGNAGE_USER:$SIGNAGE_USER" "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"/player "$INSTALL_DIR"/config "$INSTALL_DIR"/logs

# ---------- 3. Player-Dateien ----------
echo "[3/9] Player-Dateien kopieren ..."
cp -r "$REPO_ROOT/player/." "$INSTALL_DIR/player/"

# ---------- 4. device.json (Konfiguration) ----------
echo "[4/9] Konfiguration (device.json) ..."
if [ ! -f "$INSTALL_DIR/config/device.json" ]; then
  cat > "$INSTALL_DIR/config/device.json" <<JSON
{
  "playerId": "$PLAYER_ID",
  "groupId": "",
  "localUrl": "http://localhost:$PORT/",
  "apiUrl": "",
  "checkIntervalSeconds": 300
}
JSON
  echo "    device.json erstellt (playerId=$PLAYER_ID)."
else
  echo "    device.json existiert bereits – wird nicht überschrieben."
fi

# ---------- 5. Lokaler HTTP-Server (systemd) ----------
echo "[5/9] Dienst signage-server ..."
sudo tee /etc/systemd/system/signage-server.service >/dev/null <<UNIT
[Unit]
Description=Schule Neckertal Signage - lokaler HTTP-Server fuer den Player
After=network.target

[Service]
Type=simple
User=$SIGNAGE_USER
ExecStart=/usr/bin/python3 -m http.server $PORT --bind 127.0.0.1 --directory $INSTALL_DIR/player
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

# ---------- 6. Chromium-Policy ----------
echo "[6/9] Chromium-Policy ..."
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

# ---------- 7. Kiosk-Autostart mit Watchdog (labwc) ----------
echo "[7/9] Kiosk-Autostart (labwc) mit Watchdog ..."
mkdir -p "$USER_HOME/.config/labwc"
cat > "$USER_HOME/.config/labwc/autostart" <<AUTO
#!/bin/sh
# Schule Neckertal Signage - Kiosk-Autostart (labwc/Wayland) mit Watchdog.
# Die Schleife startet Chromium automatisch neu, falls es beendet wird/abstuerzt.
(
  while true; do
    chromium --kiosk --ozone-platform=wayland --noerrdialogs --disable-infobars --disable-session-crashed-bubble --disable-translate --disable-features=Translate,TranslateUI --no-first-run --no-default-browser-check --password-store=basic --check-for-update-interval=31536000 --autoplay-policy=no-user-gesture-required http://localhost:$PORT/ >/dev/null 2>&1
    sleep 3
  done
) &
AUTO
chmod +x "$USER_HOME/.config/labwc/autostart"
# Hinweis: Auf manchen Images heisst der Browser 'chromium-browser'. Dann oben anpassen.

# ---------- 8. Bildschirm-Blanking deaktivieren ----------
echo "[8/9] Bildschirm-Blanking deaktivieren ..."
sudo raspi-config nonint do_blanking 1 || true

# ---------- 9. Optionaler täglicher Reboot ----------
echo "[9/9] Taeglicher Reboot ..."
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
  echo "    Taeglicher Reboot deaktiviert."
fi

# ---------- Dienste aktivieren ----------
sudo systemctl daemon-reload
sudo systemctl enable --now signage-server.service >/dev/null

echo
echo "== Installation abgeschlossen =="
echo "Lokaler Server:  http://localhost:$PORT/   (Status: $(systemctl is-active signage-server.service))"
echo "Kiosk startet automatisch beim nächsten Login/Reboot."
echo
echo "Jetzt neu starten zum Test:   sudo reboot"
