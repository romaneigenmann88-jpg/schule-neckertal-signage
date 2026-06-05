#!/usr/bin/env python3
"""Schule Neckertal – Signage: Pi-Sync-Agent (local-first).

Holt periodisch das Remote-manifest.json (GitHub Pages), vergleicht die Version
mit der lokal aktiven und lädt NUR bei Änderung die neue Version vollständig in
einen Staging-Bereich. Erst wenn alle Dateien vorhanden sind, wird der Symlink
`web/content` atomar auf die neue Version umgeschaltet. Die vorherige Version
bleibt als Fallback erhalten.

Bei jedem Fehler bleibt die aktuelle Version aktiv (kein Abbruch der Anzeige).

Konfiguration: /opt/school-signage/config/device.json
  {
    "manifestUrl": "https://.../groups/OZN_EINGANG/manifest.json",
    "dataDir": "/opt/school-signage/data",
    "webDir":  "/opt/school-signage/web",
    "keepVersions": 3
  }
"""
import fcntl
import json
import os
import sys
import time
import urllib.request
from datetime import datetime, timezone
from urllib.parse import urljoin

CONFIG_PATH = os.environ.get("SIGNAGE_DEVICE_JSON", "/opt/school-signage/config/device.json")
TIMEOUT = 20


def log(msg):
    print(f"[sync] {datetime.now(timezone.utc).isoformat()} {msg}", flush=True)


def fetch(url, timeout=TIMEOUT):
    req = urllib.request.Request(url, headers={"Cache-Control": "no-cache"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def safe_version_dir(version):
    return "".join(c if c.isalnum() or c in "-_." else "-" for c in version)


def current_version(web_dir):
    """Version der aktuell aktiven Inhalte (oder None)."""
    man = os.path.join(web_dir, "content", "manifest.json")
    try:
        with open(man, encoding="utf-8") as f:
            return json.load(f).get("version")
    except Exception:
        return None


def main():
    with open(CONFIG_PATH, encoding="utf-8") as f:
        cfg = json.load(f)

    manifest_url = cfg["manifestUrl"]
    data_dir = cfg.get("dataDir", "/opt/school-signage/data")
    web_dir = cfg.get("webDir", "/opt/school-signage/web")
    keep = int(cfg.get("keepVersions", 3))

    os.makedirs(data_dir, exist_ok=True)

    # 0) Dateisperre: verhindert, dass zwei Sync-Läufe (z. B. Timer + manuell)
    #    gleichzeitig auf dieselben Verzeichnisse zugreifen.
    lock_file = open(os.path.join(data_dir, ".sync.lock"), "w")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("Ein anderer Sync-Lauf ist aktiv – übersprungen.")
        return 0

    # 1) Remote-Manifest holen (mit Cache-Buster gegen das Pages-CDN, damit neue
    #    Versionen sofort sichtbar sind; die Folien-URLs sind versioniert und
    #    daher ohnehin cache-sicher).
    bust = ("&" if "?" in manifest_url else "?") + "t=" + str(int(time.time()))
    try:
        raw = fetch(manifest_url + bust)
        remote = json.loads(raw)
    except Exception as e:
        log(f"Remote-Manifest nicht erreichbar ({e}). Aktuelle Version bleibt aktiv.")
        return 1

    remote_version = remote.get("version")
    if not remote_version:
        log("Remote-Manifest ohne Version – ignoriert.")
        return 1

    # 2) Vergleich mit aktiver Version
    active = current_version(web_dir)
    if active == remote_version:
        log(f"Keine Änderung (Version {remote_version}).")
        return 0

    log(f"Neue Version {remote_version} (aktiv: {active}). Lade herunter ...")

    # 3) In Staging-Verzeichnis laden
    verdir = os.path.join(data_dir, safe_version_dir(remote_version))
    staging = verdir + ".tmp"
    if os.path.isdir(staging):
        _rmtree(staging)
    os.makedirs(os.path.join(staging, "slides"), exist_ok=True)

    try:
        # manifest.json speichern
        with open(os.path.join(staging, "manifest.json"), "wb") as f:
            f.write(raw)
        # alle Folien laden
        slides = remote.get("baseLayer", {}).get("slides", [])
        if not slides:
            raise RuntimeError("Manifest enthält keine Folien.")
        for s in slides:
            rel = s["file"]                      # z. B. slides/slide-001.png
            url = urljoin(manifest_url, rel)
            dest = os.path.join(staging, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            data = fetch(url)
            if not data:
                raise RuntimeError(f"Leere Datei: {rel}")
            with open(dest, "wb") as f:
                f.write(data)
        # 4) Vollständigkeit prüfen
        for s in slides:
            p = os.path.join(staging, s["file"])
            if not (os.path.isfile(p) and os.path.getsize(p) > 0):
                raise RuntimeError(f"Unvollständig: {s['file']}")
    except Exception as e:
        log(f"Download unvollständig ({e}). Verwerfe Staging, aktuelle Version bleibt aktiv.")
        _rmtree(staging)
        return 1

    # 5) Staging -> finale Version, dann content-Symlink atomar umschalten
    if os.path.isdir(verdir):
        _rmtree(verdir)
    os.rename(staging, verdir)

    link = os.path.join(web_dir, "content")
    tmplink = os.path.join(web_dir, ".content.tmp")
    if os.path.islink(tmplink) or os.path.exists(tmplink):
        os.remove(tmplink)
    os.symlink(verdir, tmplink)
    os.replace(tmplink, link)          # atomarer Wechsel
    log(f"Aktiv geschaltet: {remote_version}")

    # 6) Alte Versionen aufräumen (aktuelle behalten + 'keep' weitere)
    _prune(data_dir, keep_dirs={os.path.realpath(verdir)}, keep=keep)
    return 0


def _rmtree(path):
    import shutil
    shutil.rmtree(path, ignore_errors=True)


def _prune(data_dir, keep_dirs, keep):
    dirs = []
    for name in os.listdir(data_dir):
        p = os.path.join(data_dir, name)
        if os.path.isdir(p) and not p.endswith(".tmp"):
            dirs.append((os.path.getmtime(p), p))
    dirs.sort(reverse=True)            # neueste zuerst
    for i, (_, p) in enumerate(dirs):
        if os.path.realpath(p) in keep_dirs:
            continue
        if i < keep:
            continue
        _rmtree(p)


if __name__ == "__main__":
    sys.exit(main())
