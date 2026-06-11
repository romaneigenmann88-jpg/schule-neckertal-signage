#!/usr/bin/env python3
"""Schule Neckertal – Signage: Pi-Render-Sync (local-first, token-frei).

Rendert die Google-Folien DIREKT auf dem Pi – ohne GitHub im Live-Weg:

  1. Gruppen-Config (config.json) vom oeffentlichen Repo holen (raw).
  2. Google-Export holen:  .../export/pdf  (Rendering, korrekte Schriften)
                           .../export/pptx (nur fuer Notizen/Dauer + versteckte)
  3. Aenderung erkennen (Hash aus PDF + Config). Unveraendert -> nichts tun
     (spart CPU/Hitze).
  4. PDF -> PNG mit pdftoppm, Namen normalisieren.
  5. manifest.json lokal erzeugen (build_manifest.py – gleiche Logik wie GitHub).
  6. Staging vollstaendig pruefen, dann web/content atomar umschalten.

Bei JEDEM Fehler bleibt die aktuelle Version aktiv (Anzeige laeuft weiter).
Token-frei: Google-Export + Repo-config sind oeffentlich.

Konfiguration: /opt/school-signage/config/device.json
  {
    "groupId":  "STPETERZELL_EINGANG",
    "configUrl":"https://raw.githubusercontent.com/<repo>/main/groups/<gid>/config.json",
    "dataDir":  "/opt/school-signage/data",
    "webDir":   "/opt/school-signage/web",
    "keepVersions": 3
  }
"""
import fcntl
import hashlib
import json
import os
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone

CONFIG_PATH = os.environ.get("SIGNAGE_DEVICE_JSON", "/opt/school-signage/config/device.json")
BIN_DIR = os.path.dirname(os.path.abspath(__file__))
TIMEOUT = 30
GOOGLE = "https://docs.google.com/presentation/d/{id}/export/{fmt}"


def log(msg):
    print(f"[render-sync] {datetime.now(timezone.utc).isoformat()} {msg}", flush=True)


def fetch(url, timeout=TIMEOUT):
    req = urllib.request.Request(url, headers={"Cache-Control": "no-cache"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def safe_version_dir(version):
    return "".join(c if c.isalnum() or c in "-_." else "-" for c in version)


def active_source_hash(web_dir):
    man = os.path.join(web_dir, "content", "manifest.json")
    try:
        with open(man, encoding="utf-8") as f:
            return json.load(f).get("sourceHash")
    except Exception:
        return None


def _rmtree(path):
    import shutil
    shutil.rmtree(path, ignore_errors=True)


def main():
    with open(CONFIG_PATH, encoding="utf-8") as f:
        cfg = json.load(f)

    config_url = cfg.get("configUrl")
    if not config_url:
        log("configUrl fehlt in device.json – nichts zu tun.")
        return 1
    data_dir = cfg.get("dataDir", "/opt/school-signage/data")
    web_dir = cfg.get("webDir", "/opt/school-signage/web")
    keep = int(cfg.get("keepVersions", 3))
    os.makedirs(data_dir, exist_ok=True)

    # Dateisperre gegen Parallellaeufe (Timer + manuell)
    lock_file = open(os.path.join(data_dir, ".sync.lock"), "w")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("Ein anderer Lauf ist aktiv – uebersprungen.")
        return 0

    # 1) Config holen (mit Cache-Buster gegen raw-CDN)
    import time as _t
    bust = ("&" if "?" in config_url else "?") + "t=" + str(int(_t.time()))
    try:
        config_raw = fetch(config_url + bust)
        config = json.loads(config_raw)
    except Exception as e:
        log(f"Config nicht erreichbar ({e}). Aktuelle Version bleibt aktiv.")
        return 1

    gid_src = config.get("source", {}).get("googleSlidesId", "")
    if not gid_src:
        log("Keine googleSlidesId in der Config – nichts zu tun.")
        return 1

    # 2) Google-Export holen (PDF + PPTX)
    try:
        pdf = fetch(GOOGLE.format(id=gid_src, fmt="pdf"))
        pptx = fetch(GOOGLE.format(id=gid_src, fmt="pptx"))
    except Exception as e:
        log(f"Google-Export nicht erreichbar ({e}). Aktuelle Version bleibt aktiv.")
        return 1
    if not pdf.startswith(b"%PDF"):
        log("Google-PDF ungueltig (nicht oeffentlich freigegeben?). Aktuelle Version bleibt aktiv.")
        return 1
    if not pptx.startswith(b"PK"):
        log("Google-PPTX ungueltig. Aktuelle Version bleibt aktiv.")
        return 1

    # 3) Aenderungserkennung: Hash aus PDF + Config
    h = hashlib.sha256()
    h.update(pdf)
    h.update(config_raw)
    source_hash = h.hexdigest()
    if source_hash == active_source_hash(web_dir):
        log("Keine Aenderung (gleicher Inhalt). Nichts zu rendern.")
        return 0

    version = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    log(f"Neuer Inhalt erkannt -> rendere Version {version} ...")

    verdir = os.path.join(data_dir, safe_version_dir(version))
    staging = verdir + ".tmp"
    if os.path.isdir(staging):
        _rmtree(staging)
    slides_dir = os.path.join(staging, "slides")
    os.makedirs(slides_dir, exist_ok=True)

    try:
        # Quelldateien in Staging ablegen
        pdf_path = os.path.join(staging, "g.pdf")
        pptx_path = os.path.join(staging, "g.pptx")
        cfg_path = os.path.join(staging, "config.json")
        with open(pdf_path, "wb") as f:
            f.write(pdf)
        with open(pptx_path, "wb") as f:
            f.write(pptx)
        with open(cfg_path, "wb") as f:
            f.write(config_raw)

        # 4) PDF -> PNG (gleiche Parameter wie der GitHub-Workflow)
        subprocess.run(
            ["pdftoppm", "-png", "-scale-to-x", "1920", "-scale-to-y", "-1",
             pdf_path, os.path.join(slides_dir, "slide")],
            check=True,
        )
        subprocess.run([sys.executable, os.path.join(BIN_DIR, "normalize_slides.py"), slides_dir], check=True)

        # 5) manifest.json erzeugen (gleiche Logik wie GitHub)
        subprocess.run(
            [sys.executable, os.path.join(BIN_DIR, "build_manifest.py"),
             "--config", cfg_path,
             "--pptx", pptx_path,
             "--slides-dir", slides_dir,
             "--output", os.path.join(staging, "manifest.json"),
             "--version", version,
             "--slides-rel", "slides",
             "--source-hash", source_hash],
            check=True,
        )

        # 6) Vollstaendigkeit pruefen
        with open(os.path.join(staging, "manifest.json"), encoding="utf-8") as f:
            man = json.load(f)
        slides = man.get("baseLayer", {}).get("slides", [])
        if not slides:
            raise RuntimeError("Manifest enthaelt keine Folien.")
        for s in slides:
            p = os.path.join(staging, s["file"])
            if not (os.path.isfile(p) and os.path.getsize(p) > 0):
                raise RuntimeError(f"Folie fehlt/leer: {s['file']}")
    except Exception as e:
        log(f"Rendern fehlgeschlagen ({e}). Verwerfe Staging, aktuelle Version bleibt aktiv.")
        _rmtree(staging)
        return 1

    # Quelldateien aus dem Web-Verzeichnis entfernen (nicht ausliefern)
    for junk in ("g.pdf", "g.pptx", "config.json"):
        try:
            os.remove(os.path.join(staging, junk))
        except OSError:
            pass

    # 7) Staging -> finale Version, dann content-Symlink atomar umschalten
    if os.path.isdir(verdir):
        _rmtree(verdir)
    os.rename(staging, verdir)

    link = os.path.join(web_dir, "content")
    tmplink = os.path.join(web_dir, ".content.tmp")
    if os.path.islink(tmplink) or os.path.exists(tmplink):
        os.remove(tmplink)
    os.symlink(verdir, tmplink)
    os.replace(tmplink, link)
    log(f"Aktiv geschaltet: {version} ({len(slides)} Folien)")

    _prune(data_dir, keep_dirs={os.path.realpath(verdir)}, keep=keep)
    return 0


def _prune(data_dir, keep_dirs, keep):
    dirs = []
    for name in os.listdir(data_dir):
        p = os.path.join(data_dir, name)
        if os.path.isdir(p) and not p.endswith(".tmp"):
            dirs.append((os.path.getmtime(p), p))
    dirs.sort(reverse=True)
    for i, (_, p) in enumerate(dirs):
        if os.path.realpath(p) in keep_dirs:
            continue
        if i < keep:
            continue
        _rmtree(p)


if __name__ == "__main__":
    sys.exit(main())
