#!/bin/sh
# ============================================================
# Schule Neckertal Signage - automatische SICHERHEITS-Updates
# ------------------------------------------------------------
# Richtet unattended-upgrades so ein, dass jede Nacht NUR die Pakete aus
# Debians Sicherheitskanal installiert werden (z. B. ca-certificates,
# libnss3, openssl). Der naechtliche Neustart (signage-reboot.timer,
# Standard 04:00) aktiviert sie anschliessend.
#
# NICHT automatisch: Kernel, Firmware, Chromium und Desktop-Pakete aus dem
# Raspberry-Pi-Archiv sowie Debians normale Wartungs-Releases. Die koennen den
# Kiosk veraendern und wuerden sonst auf allen Pis in derselben Nacht kommen.
# Dafuer: pi/full-upgrade.sh, von Hand, zuerst auf EINEM Pi.
#
# Aufruf (als root, idempotent - darf mehrfach laufen):
#   sudo sh setup-auto-security-updates.sh
# Zeiten anpassbar:  LIST_TIME=02:00 UPGRADE_TIME=02:30 sudo -E sh ...
# ============================================================
set -eu

LIST_TIME="${LIST_TIME:-02:00}"        # Paketlisten aktualisieren
UPGRADE_TIME="${UPGRADE_TIME:-02:30}"  # Sicherheitsupdates installieren (vor dem Neustart!)

if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausfuehren."; exit 1; fi
export DEBIAN_FRONTEND=noninteractive

echo "== Automatische Sicherheitsupdates einrichten ($(hostname)) =="

# 1. Paket installieren (falls noetig)
if ! dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q "install ok installed"; then
  echo "[1/4] unattended-upgrades installieren ..."
  apt-get update -qq
  apt-get install -y -qq unattended-upgrades
else
  echo "[1/4] unattended-upgrades bereits installiert."
fi

# 2. Taeglich ausfuehren
echo "[2/4] Taeglichen Lauf aktivieren ..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
// Schule Neckertal Signage - von setup-auto-security-updates.sh verwaltet
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# 3. NUR Sicherheitskanal. "#clear" ist noetig: Debians 50unattended-upgrades
#    erlaubt auch die normalen Wartungs-Releases, und weitere Eintraege in
#    apt-Konfigurationslisten wuerden nur ERGAENZEN, nicht ersetzen.
echo "[3/4] Nur Debian-Sicherheitsupdates zulassen ..."
cat > /etc/apt/apt.conf.d/52signage-unattended-upgrades <<'EOF'
// Schule Neckertal Signage - von setup-auto-security-updates.sh verwaltet.
// NUR Debians Sicherheitskanal. Kernel/Firmware/Chromium (Raspberry-Pi-Archiv)
// und normale Wartungs-Releases bleiben dem manuellen pi/full-upgrade.sh vorbehalten.
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
};
// Neustart uebernimmt der naechtliche signage-reboot.timer
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::OnlyOnACPower "false";
EOF

# 4. Zeiten: Listen um LIST_TIME, Installation um UPGRADE_TIME (ohne Zufallsverzoegerung),
#    damit beides sicher vor dem naechtlichen Neustart fertig ist.
echo "[4/4] Zeiten setzen: Listen $LIST_TIME, Installation $UPGRADE_TIME ..."
mkdir -p /etc/systemd/system/apt-daily.timer.d /etc/systemd/system/apt-daily-upgrade.timer.d
cat > /etc/systemd/system/apt-daily.timer.d/signage.conf <<EOF
# Schule Neckertal Signage
[Timer]
OnCalendar=
OnCalendar=*-*-* $LIST_TIME
RandomizedDelaySec=0
EOF
cat > /etc/systemd/system/apt-daily-upgrade.timer.d/signage.conf <<EOF
# Schule Neckertal Signage
[Timer]
OnCalendar=
OnCalendar=*-*-* $UPGRADE_TIME
RandomizedDelaySec=0
EOF
systemctl daemon-reload
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
# Wartet beim Herunterfahren, bis ein laufendes Update fertig ist
systemctl enable unattended-upgrades.service >/dev/null 2>&1 || true

# Kontrolle
echo
echo "== Kontrolle =="
echo "Erlaubte Quellen:"
apt-config dump Unattended-Upgrade::Origins-Pattern | sed -n 's/^Unattended-Upgrade::Origins-Pattern:: "\(.*\)";$/  \1/p'
echo "Timer:"
systemctl list-timers --no-legend apt-daily.timer apt-daily-upgrade.timer | awk '{print "  " $NF ": naechster Lauf " $2 " " $3}'
if unattended-upgrade --dry-run >/dev/null 2>&1; then echo "Probelauf: OK"; else echo "Probelauf: FEHLER"; exit 1; fi
echo "Fertig."
