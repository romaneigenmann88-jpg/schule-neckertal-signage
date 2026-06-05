# Schule Neckertal – Digital Signage

Eigenes, schlankes Digital-Signage-System (Ersatz für Yodeck) für die Schule Neckertal.

## Architektur (Kurzfassung)

| Schicht | Lösung |
|---|---|
| **Folien bearbeiten** | **Google Slides** – Lehrpersonen bearbeiten je Bildschirmgruppe eine geteilte Präsentation („Jeder mit Link: Betrachter") |
| **Rendern + Ausliefern** | GitHub Actions holt den **öffentlichen Google-Export** (PDF rendern, PPTX nur für Notizen) → PNG + `manifest.json` → GitHub Pages |
| **Anzeigen** | Raspberry-Pi-Player, *local-first*: spielt lokale Bilder ab, prüft alle 3 Min auf neue Version, läuft offline weiter |
| **Code / Zusammenarbeit** | GitHub (öffentliches Repo) |

**Keine Secrets, keine Tokens, kein eigener Server.** Quelle (Google-Export) ist öffentlich abrufbar, der Pages-Push läuft über den automatischen `GITHUB_TOKEN`. Google rendert die Schriften (z. B. *Caveat*) korrekt – keine Schrift-Installation nötig. Auslösung zeitgesteuert (cron alle 5 Min, öffentliches Repo = unbegrenzte Minuten).

## Stand

- ✅ **Render-Test** erfolgreich: echte Schul-PPTX → PNG via GitHub Actions (LibreOffice/Linux), Schriften *Caveat SemiBold* / *Comfortaa* korrekt.
- ✅ **Lokaler Player** (Phase 1): Slideshow, Dauer pro Folie, Overlay (Datum/Uhr), Zeitplan/Black-Screen, robuste Fehlerbehandlung.
- ✅ **Raspberry-Pi-Kiosk** auf echter Hardware (Pi 400): Autostart nach Reboot, lokaler Server, Watchdog, HDMI-Off getestet.
- ⏳ Als Nächstes: automatische Render-Pipeline (PPTX → Pages), Datenmodell, Adminkonsole.

## Komponenten

| Pfad | Inhalt |
|---|---|
| `player/` | Lokaler HTML/JS-Player (Phase 1) |
| `pi/install.sh` | Reproduzierbares Pi-Installationsskript (Kiosk) |
| `docs/raspberry-pi-installation.md` | Pi-Installations- & Betriebsanleitung |
| `.github/workflows/render-test.yml` | Render-Test PPTX → PNG |
| `render/samples/` | Test-PPTX |
| `schule-neckertal-...-pflichtenheft.txt` | Vollständiges Pflichtenheft |

## Player lokal testen

```bash
python -m http.server 8099 --directory player
# Browser: http://localhost:8099  (ausserhalb Schulzeit: ?ignoreSchedule=1)
```

## Render-Test ausführen

In GitHub unter **Actions → „Render-Test (PPTX → PNG)" → Run workflow**. Das Ergebnis liegt danach als Artefakt `gerenderte-folien-png` zum Download bereit.

## Pi aufsetzen

Siehe [docs/raspberry-pi-installation.md](docs/raspberry-pi-installation.md). Kurz: Repo auf den Pi, dann `bash pi/install.sh`, dann `sudo reboot`.
