#!/usr/bin/env bash
# Rüstet den Heartbeat auf einem bereits installierten Pi nach – ohne
# Neuinstallation, ohne den laufenden Kiosk zu stören.
# Aufruf (per SSH auf dem Pi):
#   curl -fsSL https://romaneigenmann88-jpg.github.io/schule-neckertal-signage/add-heartbeat.sh | bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/school-signage}"
SUSER="${SIGNAGE_USER:-$(id -un)}"
HEARTBEAT_URL="${HEARTBEAT_URL:-https://signage-heartbeat.schule-neckertal.workers.dev}"
RAW="https://raw.githubusercontent.com/romaneigenmann88-jpg/schule-neckertal-signage/main/pi/heartbeat.sh"

echo "== Heartbeat nachrüsten =="
mkdir -p "$INSTALL_DIR/bin"
curl -fsSL "$RAW" -o "$INSTALL_DIR/bin/heartbeat.sh"
chmod +x "$INSTALL_DIR/bin/heartbeat.sh"

# heartbeatUrl in device.json eintragen
python3 -c "import json; p='$INSTALL_DIR/config/device.json'; d=json.load(open(p)); d['heartbeatUrl']='$HEARTBEAT_URL'; json.dump(d, open(p,'w'), indent=2)"

# Dienst + Timer (printf statt heredoc, damit es per 'curl | bash' sicher läuft)
printf '[Unit]\nDescription=Schule Neckertal Signage - Heartbeat\nAfter=network-online.target\nWants=network-online.target\n[Service]\nType=oneshot\nUser=%s\nExecStart=/bin/sh %s/bin/heartbeat.sh\n' "$SUSER" "$INSTALL_DIR" | sudo tee /etc/systemd/system/signage-heartbeat.service >/dev/null
printf '[Unit]\nDescription=Schule Neckertal Signage - Heartbeat alle 5 Minuten\n[Timer]\nOnBootSec=50s\nOnUnitActiveSec=5min\nPersistent=true\n[Install]\nWantedBy=timers.target\n' | sudo tee /etc/systemd/system/signage-heartbeat.timer >/dev/null

sudo systemctl daemon-reload
sudo systemctl enable --now signage-heartbeat.timer
sudo systemctl start signage-heartbeat.service
echo "== Fertig: Heartbeat läuft (meldet sich alle 5 Min) =="
