# Schule Neckertal – Digital Signage

Eigenes, schlankes Digital-Signage-System (Ersatz für Yodeck) für die Schule Neckertal.

## Architektur (Kurzfassung)

| Schicht | Lösung |
|---|---|
| **Folien bearbeiten** | PowerPoint Online (Microsoft 365) – Lehrpersonen bearbeiten je Bildschirmgruppe eine zentrale `.pptx` |
| **Rendern + Ausliefern** | GitHub Actions (LibreOffice headless: PPTX → PNG + `manifest.json`) → GitHub Pages (statisch, HTTPS) |
| **Anzeigen** | Raspberry-Pi-Player, *local-first*: spielt lokale Bilder ab, prüft alle 5 Min auf neue Version, läuft offline weiter |
| **Code / Zusammenarbeit** | GitHub |

Es gibt **keinen** eigenen, dauerhaft laufenden Server. Das Rendering läuft ereignis-/zeitgesteuert in GitHub Actions, die Auslieferung ist statisches Hosting.

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
