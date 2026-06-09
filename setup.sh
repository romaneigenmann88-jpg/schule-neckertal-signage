#!/usr/bin/env bash
# ============================================================
# Schule Neckertal – Digital Signage: Ein-Befehl-Setup
# ------------------------------------------------------------
# Holt das öffentliche Repo und richtet diesen Pi als Player ein.
# Aufruf (auf dem frisch geflashten Pi, im Terminal):
#
#   curl -fsSL https://romaneigenmann88-jpg.github.io/schule-neckertal-signage/setup.sh \
#     | PLAYER_ID=OZN_SCREEN_02 \
#       MANIFEST_URL=https://romaneigenmann88-jpg.github.io/schule-neckertal-signage/groups/OZN_EINGANG/manifest.json \
#       bash
#
# PLAYER_ID und MANIFEST_URL werden an pi/install.sh durchgereicht.
# ============================================================
set -euo pipefail

REPO_URL="https://github.com/romaneigenmann88-jpg/schule-neckertal-signage.git"
DEST="$HOME/school-signage-src"

echo "== Schule Neckertal Signage – Setup =="
echo "PlayerId:  ${PLAYER_ID:-(Hostname)}"
echo "Manifest:  ${MANIFEST_URL:-(Standard aus install.sh)}"
echo

if ! command -v git >/dev/null 2>&1; then
  echo "[setup] git installieren ..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq git
fi

echo "[setup] Repo holen ..."
rm -rf "$DEST"
git clone --depth 1 "$REPO_URL" "$DEST"

echo "[setup] Installation starten ..."
cd "$DEST"
bash pi/install.sh

echo
echo "== Setup abgeschlossen =="
echo "Jetzt einmal neu starten:   sudo reboot"
