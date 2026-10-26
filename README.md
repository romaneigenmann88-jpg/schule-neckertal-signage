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
| `pi/setup-auto-security-updates.sh` | Automatische **Sicherheits**updates jede Nacht 02:30 (von `install.sh` aufgerufen) |
| `pi/full-upgrade.sh` | Manuelles Voll-Update (Kernel, Chromium, Firmware) mit Neustart |
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

## Updates & Wartung

| Was | Wie oft | Wie |
|---|---|---|
| **Sicherheitsupdates** (Debian-Sicherheitskanal: Zertifikate, NSS, OpenSSL …) | jede Nacht, **automatisch** | Paketlisten 02:00, Installation 02:30, aktiviert durch den Neustart 04:00 |
| **Alles andere** (Kernel, Firmware, Chromium, Desktop, Debian-Wartungs-Releases) | ca. **pro Quartal / in den Ferien**, von Hand | `sudo sh pi/full-upgrade.sh` — **zuerst auf einem Pi**, prüfen, dann die anderen |

Warum nicht alles automatisch: Kernel und Chromium können den Kiosk verändern. Automatisch kämen sie auf allen Pis in derselben Nacht — geht etwas schief, sind alle Bildschirme gleichzeitig dunkel. Chromium zu verzögern ist vertretbar, weil er nur lokale Inhalte (`127.0.0.1`) anzeigt.

Zum Vergleich: Zwischen Inbetriebnahme (Juni 2026) und erstem Voll-Update (26.10.2026) fielen ~470 Pakete an, davon 30 aus dem Sicherheitskanal.

**Hinweise für Fernwartung per SSH**
- Updates nie direkt in der SSH-Sitzung laufen lassen — das Netz zu einzelnen Pis ist wacklig, ein abgebrochenes `apt` hinterlässt ein halb installiertes System. Beide Skripte starten die Arbeit deshalb als eigenen systemd-Dienst.
- `full-upgrade.sh` behält angepasste Konfigurationsdateien (`--force-confold`) und startet nur nach fehlerfreiem Update neu. Fortschritt: `tail -f /var/log/signage-fullupgrade.log`.
- Kontrolle der automatischen Updates: `sudo unattended-upgrade --dry-run --debug | grep "Allowed origins"` — darf nur `…-security` zeigen.

## Changelog

### 2026-10-26 — Voll-Update aller Pis + automatische Sicherheitsupdates

- **Alle 5 Pis voll aktualisiert** (erstes Update seit Inbetriebnahme, je ~430 Pakete): Kernel 6.18.50, Chromium 155, `ca-certificates 20250419+deb13u1`. Anlass: kompromittierte eMudhra-Zwischenzertifikate (Okt. 2026) — das Debian-Sicherheitsupdate entfernt „emSign ECC Root CA - G3" und „Comodo AAA". Vorgehen: zuerst ein Pi als Test, dann die übrigen; alle fehlerfrei, alle Bildschirme danach geprüft
- **Neu `pi/setup-auto-security-updates.sh`**: `unattended-upgrades` nur für den Debian-Sicherheitskanal (Standard-Konfiguration mit `#clear` geleert — Debians Vorgabe würde auch die normalen Wartungs-Releases installieren). Listen 02:00, Installation 02:30, ohne Zufallsverzögerung, vor dem Neustart um 04:00. Auf allen 5 Pis eingerichtet; `install.sh` ruft es künftig in Schritt 9 auf
- **Neu `pi/full-upgrade.sh`**: das bewährte Voll-Update vom 26.10. als wiederverwendbares Skript
