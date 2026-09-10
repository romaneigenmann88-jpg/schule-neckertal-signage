#!/usr/bin/env python3
"""Schule Neckertal – Signage: Video-Sync (local-first) fuer den Schaukasten.

Spiegelt den Video-Bucket LOKAL auf den Pi:
  1. Playlist vom Worker holen (GET /videos -> {videos:[{name,url,size}]}).
  2. Neue/geaenderte Videos herunterladen (nach web/content/videos/).
  3. Lokale Videos loeschen, die im Bucket nicht mehr existieren.
  4. Lokale playlist.json schreiben (der Player spielt LOKALE Dateien).

So laeuft der Schaukasten offline weiter, spart Bandbreite (kein Streaming je
Schleife) und folgt trotzdem dem Bucket: Video hochladen -> erscheint; Video
loeschen -> verschwindet. Reihenfolge = alphabetisch nach Dateiname
(z. B. "01-intro.mp4", "02-...").

Konfiguration ueber Umgebung / device.json:
  SIGNAGE_VIDEOS_URL   Playlist-URL      (Default: heartbeatUrl aus device.json + /videos)
  SIGNAGE_WEB_DIR      Web-Verzeichnis   (Default: /opt/school-signage/web)
"""
import json
import os
import socket
import sys
import tempfile
import urllib.request

# IPv4 erzwingen (kaputtes IPv6 auf manchen Schulnetzen -> DNS-Timeouts).
_orig_gai = socket.getaddrinfo
socket.getaddrinfo = lambda host, port, family=0, *a: _orig_gai(host, port, socket.AF_INET, *a)

TIMEOUT = 60
DEVICE_JSON = os.environ.get("SIGNAGE_DEVICE_JSON", "/opt/school-signage/config/device.json")


def log(msg):
    print(f"[video-sync] {msg}", flush=True)


def _device(key, default=""):
    try:
        with open(DEVICE_JSON, encoding="utf-8") as f:
            return json.load(f).get(key, default)
    except Exception:
        return default


def fetch(url, timeout=TIMEOUT):
    # WICHTIG: eigener User-Agent. Cloudflare blockt den Default "Python-urllib"
    # als Bot mit HTTP 403 - mit normalem UA kommt die Anfrage durch.
    req = urllib.request.Request(url, headers={
        "Cache-Control": "no-cache",
        "User-Agent": "SchuleNeckertalSignage-VideoSync/1.0",
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def safe_name(name):
    """Nur flache, ungefaehrliche Dateinamen zulassen (kein Pfad-Ausbruch)."""
    return name and "/" not in name and "\\" not in name and not name.startswith(".")


def main():
    videos_url = os.environ.get("SIGNAGE_VIDEOS_URL") or (_device("heartbeatUrl").rstrip("/") + "/videos")
    web_dir = os.environ.get("SIGNAGE_WEB_DIR", "/opt/school-signage/web")
    if not videos_url or videos_url == "/videos":
        log("Keine videosUrl (heartbeatUrl fehlt) - nichts zu tun.")
        return 1

    content_dir = os.path.join(web_dir, "content")
    videos_dir = os.path.join(content_dir, "videos")
    os.makedirs(videos_dir, exist_ok=True)

    # 1) Playlist holen
    try:
        import time
        bust = ("&" if "?" in videos_url else "?") + "t=" + str(int(time.time()))
        data = json.loads(fetch(videos_url + bust))
    except Exception as e:
        log(f"Playlist nicht erreichbar ({e}). Lokaler Stand bleibt aktiv.")
        return 1
    remote = [v for v in data.get("videos", []) if v.get("name") and v.get("url") and safe_name(v["name"])]
    remote_names = {v["name"] for v in remote}

    # 2) Neue/geaenderte Videos herunterladen
    downloaded = 0
    for v in remote:
        name, url = v["name"], v["url"]
        size = int(v.get("size") or 0)
        dest = os.path.join(videos_dir, name)
        if os.path.isfile(dest) and (size == 0 or os.path.getsize(dest) == size):
            continue                                   # schon lokal + gleiche Groesse
        try:
            blob = fetch(url)
        except Exception as e:
            log(f"Download fehlgeschlagen: {name} ({e}) - uebersprungen.")
            continue
        if size and len(blob) != size:
            log(f"Groesse weicht ab: {name} ({len(blob)} statt {size}) - uebersprungen.")
            continue
        if len(blob) < 1000 or blob[:1] == b"<":       # zu klein / HTML-Fehlerseite
            log(f"Ungueltige Datei: {name} - uebersprungen.")
            continue
        fd, tmp = tempfile.mkstemp(dir=videos_dir, suffix=".part")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(blob)
            os.replace(tmp, dest)                       # atomar
            downloaded += 1
            log(f"Geladen: {name} ({len(blob)} Bytes)")
        except OSError as e:
            log(f"Schreiben fehlgeschlagen: {name} ({e})")
            try:
                os.remove(tmp)
            except OSError:
                pass

    # 3) Lokale Videos loeschen, die es im Bucket nicht mehr gibt
    removed = 0
    for fn in os.listdir(videos_dir):
        p = os.path.join(videos_dir, fn)
        if fn.endswith(".part"):
            os.remove(p)                               # abgebrochene Downloads
            continue
        if fn not in remote_names and os.path.isfile(p):
            os.remove(p)
            removed += 1
            log(f"Entfernt (nicht mehr im Bucket): {fn}")

    # 4) Lokale playlist.json schreiben (Player spielt content/videos/<name>)
    playlist = [
        {"name": v["name"], "url": "content/videos/" + v["name"], "size": int(v.get("size") or 0)}
        for v in sorted(remote, key=lambda x: x["name"])
        if os.path.isfile(os.path.join(videos_dir, v["name"]))
    ]
    pl_path = os.path.join(content_dir, "playlist.json")
    tmp = pl_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(playlist, f, indent=2, ensure_ascii=False)
    os.replace(tmp, pl_path)

    log(f"Fertig: {len(playlist)} Video(s) aktiv (+{downloaded} geladen, -{removed} entfernt).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
