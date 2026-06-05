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

Konzeptphase. Aktueller Schritt: **früher Render-Test** – prüfen, ob LibreOffice die echten Folien (inkl. der Schriften *Caveat SemiBold* / *Comfortaa*) unter Linux-Bedingungen gut genug rendert.

- Test-Workflow: [.github/workflows/render-test.yml](.github/workflows/render-test.yml)
- Test-Folien: `render/samples/`
- Vollständiges Pflichtenheft: `schule-neckertal-digital-signage-konzept-pflichtenheft.txt`

## Render-Test ausführen

In GitHub unter **Actions → „Render-Test (PPTX → PNG)" → Run workflow**. Das Ergebnis liegt danach als Artefakt `gerenderte-folien-png` zum Download bereit.
