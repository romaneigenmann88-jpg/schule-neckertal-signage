#!/bin/sh
# ============================================================
# Schule Neckertal Signage - Voll-Update (manuell)
# ------------------------------------------------------------
# Spielt ALLE ausstehenden Updates ein (Kernel, Firmware, Chromium, Desktop,
# Debian-Wartungs-Releases) und startet den Pi danach neu - aber NUR, wenn das
# Update fehlerfrei durchlief. Sicherheitsupdates kommen ohnehin jede Nacht
# automatisch (setup-auto-security-updates.sh); dieses Skript ist fuer den Rest,
# etwa einmal pro Quartal oder in den Ferien.
#
# Vorgehen (bewaehrt am 26.10.2026):
#   1. Zuerst auf EINEM Pi ausfuehren und pruefen, ob er sauber hochkommt.
#   2. Erst dann die anderen.
#
# Aufruf (als root):
#   sudo sh full-upgrade.sh
#
# Laeuft als eigener systemd-Dienst weiter, auch wenn die SSH-Verbindung
# abbricht (das Netz zu einzelnen Pis ist wacklig). Ein in der SSH-Sitzung
# abgebrochenes apt wuerde das Paketsystem halb installiert zuruecklassen.
# Angepasste Konfigurationsdateien (Kiosk aus install.sh) bleiben erhalten.
#
# Fortschritt:  tail -f /var/log/signage-fullupgrade.log
# Ergebnis:     letzte Zeile EXIT=0 = erfolgreich (danach automatischer Neustart)
# ============================================================
if [ "$(id -u)" -ne 0 ]; then echo "Bitte mit sudo ausfuehren."; exit 1; fi
if fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; then
  echo "apt ist gerade beschaeftigt - bitte in ein paar Minuten nochmals."; exit 1
fi
if systemctl is-active --quiet signage-fullupgrade 2>/dev/null; then
  echo "Ein Voll-Update laeuft bereits."; exit 1
fi
systemd-run --unit=signage-fullupgrade --description="Signage full-upgrade" \
  --setenv=DEBIAN_FRONTEND=noninteractive --setenv=NEEDRESTART_MODE=l \
  /bin/sh -c 'L=/var/log/signage-fullupgrade.log; { apt-get update && apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade; } > $L 2>&1; RC=$?; echo EXIT=$RC >> $L; [ $RC -eq 0 ] && systemctl reboot'
echo ""
echo "OK - Update laeuft auf $(hostname). Der Pi startet danach von selbst neu."
echo "Fortschritt: tail -f /var/log/signage-fullupgrade.log"
echo "Dieses Fenster darf geschlossen werden."
