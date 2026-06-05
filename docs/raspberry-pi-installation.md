# Raspberry-Pi-Installationsanleitung

Diese Anleitung richtet einen Raspberry Pi als **Kiosk-Player** für das Digital-Signage-System der Schule Neckertal ein.

Getestet mit: **Raspberry Pi 4 / Pi 400**, **Raspberry Pi OS (64-bit)** Bookworm/Trixie mit Desktop (labwc/Wayland).

---

## 1. Was der Player macht

- Spielt die **lokal gespeicherten gerenderten Folien** als Vollbild-Slideshow ab.
- Zeigt das **Overlay** (Datum oben Mitte, Uhr oben rechts).
- Schaltet **außerhalb der Betriebszeit** auf Black-Screen (Zeitplan im `manifest.json`).
- Läuft **offline weiter**, wenn das Netzwerk weg ist (lokaler Server).
- Startet nach **Reboot automatisch** und nach einem **Chromium-Absturz** automatisch neu (Watchdog).

Der Pi ist **kein Browser für SharePoint** – er zeigt nur fertige Bilder.

---

## 2. Schritt 1: Betriebssystem flashen

Mit dem **Raspberry Pi Imager**:

1. **Choose Device:** Raspberry Pi 4 / 400
2. **Choose OS:** Raspberry Pi OS (64-bit) – mit Desktop
3. **Choose Storage:** SD-Karte
4. **Edit Settings:**
   - **Hostname:** z. B. `ozn-screen-01` (entspricht der PlayerId)
   - **Benutzer/Passwort:** setzen (Passwort merken, **kein** triviales wie `1234`)
   - **WLAN:** nur falls kein LAN-Kabel (Land **CH**); ein **LAN-Kabel ist stabiler**
   - **Locale:** Zeitzone `Europe/Zurich`, Tastatur `ch`
   - **Services → SSH aktivieren** (Public-Key empfohlen)
5. Schreiben, SD in den Pi, HDMI + Netzwerk + Strom anschließen, booten.

---

## 3. Schritt 2: Repo auf den Pi bringen

Variante A – per `git` (wenn der Pi Zugriff aufs Repository hat):

```bash
git clone <REPO-URL> ~/school-signage-src
cd ~/school-signage-src
```

Variante B – per `scp`/`tar` vom Arbeitsrechner (Repo dorthin kopieren).

---

## 4. Schritt 3: Installation ausführen

```bash
bash pi/install.sh
```

Optionale Parameter (per Umgebungsvariable):

| Variable | Standard | Bedeutung |
|---|---|---|
| `PLAYER_ID` | Hostname | PlayerId in `device.json` |
| `SIGNAGE_PORT` | `8099` | Port des lokalen Servers |
| `INSTALL_DIR` | `/opt/school-signage` | Zielverzeichnis |
| `DAILY_REBOOT` | `04:00` | Uhrzeit täglicher Reboot; **leer** = aus |
| `SIGNAGE_OUTPUT` | `HDMI-A-1` | Wayland-Output (für HDMI-Off) |

Beispiel:

```bash
PLAYER_ID=OZN_SCREEN_01 DAILY_REBOOT=03:30 bash pi/install.sh
```

Danach zum Test neu starten:

```bash
sudo reboot
```

Nach dem Reboot erscheint automatisch die Slideshow im Vollbild.

---

## 5. Was installiert wird

| Komponente | Ort |
|---|---|
| App-Dateien (Player) | `/opt/school-signage/web/` (index.html, app.js, style.css) |
| Aktive Inhalte | `/opt/school-signage/web/content` → Symlink auf `data/<version>/` |
| Inhalts-Versionen | `/opt/school-signage/data/<version>/` (manifest.json + slides/) |
| Konfiguration | `/opt/school-signage/config/device.json` |
| Lokaler Server | systemd-Dienst `signage-server.service` (127.0.0.1:8099, liefert `web/`) |
| Inhalts-Sync | `signage-sync.service` + `signage-sync.timer` (alle 5 Min) |
| Kiosk-Autostart + Watchdog | `~/.config/labwc/autostart` |
| Chromium-Policy | `/etc/chromium/policies/managed/signage.json` |
| Täglicher Reboot (optional) | `signage-reboot.timer` |

---

## 6. Betrieb & Wartung

**Inhalte aktualisieren** geschieht **automatisch**: Die PowerPoint wird (künftig in
M365) bearbeitet, der GitHub-Workflow rendert und veröffentlicht, und der Pi holt
die neue Version per `signage-sync.timer` (alle 5 Min). Der Player erkennt die neue
Version und lädt selbständig neu. Manuell sofort synchronisieren:

```bash
sudo systemctl start signage-sync.service
journalctl -u signage-sync.service -e        # Sync-Log
```

**Server-Status / Logs:**

```bash
systemctl status signage-server.service
journalctl -u signage-server.service -e
```

**Lokal testen (auf dem Pi):**

```bash
curl -I http://localhost:8099/manifest.json
```

**Bildschirm manuell aus-/einschalten (HDMI-Off):**

```bash
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0
wlr-randr --output HDMI-A-1 --off    # aus
wlr-randr --output HDMI-A-1 --on     # ein
```

> Den Output-Namen ermittelt `wlr-randr` (oben in derselben Umgebung). Beim HP E232 löst `--off` einen echten Standby aus.

**Täglichen Reboot abschalten:**

```bash
sudo systemctl disable --now signage-reboot.timer
```

---

## 7. Troubleshooting

| Problem | Prüfen / Lösung |
|---|---|
| Schwarzer Bildschirm | Liegt „jetzt" außerhalb der Betriebszeit im `manifest.json`? Mit `?ignoreSchedule=1` testen (URL im Autostart temporär ergänzen). |
| Keine Slideshow, weißes Bild | Läuft `signage-server`? `systemctl is-active signage-server.service`. `manifest.json` per `curl` erreichbar? |
| Chromium startet nicht | `~/.config/labwc/autostart` vorhanden und ausführbar? Browser heißt evtl. `chromium-browser`. |
| Übersetzungsleiste erscheint | Policy `/etc/chromium/policies/managed/signage.json` vorhanden? Chromium neu starten. |
| Bildschirm geht nachts nicht aus | Off-Mode `hdmi_off` wird in v1 vom Player als Black-Screen umgesetzt; echtes HDMI-Off per `wlr-randr` (siehe oben), Display-abhängig. |

---

## 8. Mehrere Player / Standorte

- **Eine PowerPoint pro Bildschirmgruppe** (= pro Inhalt), nicht pro Player.
- Mehrere Player derselben Gruppe zeigen **denselben** Inhalt (z. B. St. Peterzell: 1 PowerPoint, 2 Player).
- Pro Player eine eigene `PLAYER_ID` vergeben (z. B. `OZN_SCREEN_01`, `OZN_SCREEN_02`).
