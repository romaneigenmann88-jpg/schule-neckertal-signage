#!/usr/bin/env python3
"""Schule Neckertal – Signage: Video-Sync (local-first) fuer den Schaukasten.

Spiegelt den Video-Bucket LOKAL auf den Pi und sorgt fuer abspielbare 720p:
  1. Playlist vom Worker holen (GET /videos).
  2. Neue Videos herunterladen (Original -> content/videos/.src/).
  3. Auf <=720p bringen (content/videos/<name>): Originale >720p werden auf 720p
     transkodiert (HW-Encode, Fallback Software), <=720p einfach uebernommen.
     -> Der Pi 3B+ dekodiert 1080p nicht fluessig; 720p schon.
  4. Lokal loeschen, was im Bucket nicht mehr existiert.
  5. content/playlist.json schreiben (der mpv-Kiosk spielt content/videos/*.mp4).

Laeuft ueber den Dienst signage-video (ohne Start-Timeout), damit eine laengere
Transkodierung nicht abgewuergt wird.
"""
import json
import os
import socket
import subprocess
import sys
import urllib.request

# IPv4 erzwingen (kaputtes IPv6 auf manchen Schulnetzen -> DNS-Timeouts).
_orig_gai = socket.getaddrinfo
socket.getaddrinfo = lambda host, port, family=0, *a: _orig_gai(host, port, socket.AF_INET, *a)

TIMEOUT = 60
MAXH = 720
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
    # Eigener User-Agent: Cloudflare blockt den Default "Python-urllib" mit 403.
    req = urllib.request.Request(url, headers={
        "Cache-Control": "no-cache",
        "User-Agent": "SchuleNeckertalSignage-VideoSync/1.0",
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def safe_name(name):
    return name and "/" not in name and "\\" not in name and not name.startswith(".")


def video_height(path):
    """Hoehe des Videos via ffprobe (None, wenn ffprobe fehlt/Fehler)."""
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=height", "-of", "csv=p=0", path],
            capture_output=True, text=True, timeout=60)
        return int(out.stdout.strip())
    except Exception:
        return None


def to_720(src, out):
    """src -> out auf 720p bringen. Erst HW-Encode (h264_v4l2m2m), sonst Software
    (libx264). Gibt True bei Erfolg. Laeuft synchron (kann dauern)."""
    tmp = out + ".part"
    attempts = [
        ["-c:v", "h264_v4l2m2m", "-b:v", "4M"],                    # Hardware-Encoder (schnell)
        ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23"],  # Fallback: Software
    ]
    for enc in attempts:
        # -f mp4 explizit: die Tempdatei endet auf .part, sonst raet ffmpeg das
        # Ausgabeformat falsch und bricht ab.
        cmd = (["ffmpeg", "-y", "-i", src, "-vf", "scale=-2:720", "-an",
                "-movflags", "+faststart"] + enc + ["-f", "mp4", tmp])
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=3600)
        except Exception as e:
            log(f"  Transkodierung abgebrochen ({e}).")
            r = None
        if r is not None and r.returncode == 0 and os.path.isfile(tmp) and os.path.getsize(tmp) > 1000:
            os.replace(tmp, out)
            return True
        try:
            os.remove(tmp)
        except OSError:
            pass
    return False


def main():
    videos_url = os.environ.get("SIGNAGE_VIDEOS_URL") or (_device("heartbeatUrl").rstrip("/") + "/videos")
    web_dir = os.environ.get("SIGNAGE_WEB_DIR", "/opt/school-signage/web")
    if not videos_url or videos_url == "/videos":
        log("Keine videosUrl (heartbeatUrl fehlt) - nichts zu tun.")
        return 1

    content_dir = os.path.join(web_dir, "content")
    videos_dir = os.path.join(content_dir, "videos")
    src_dir = os.path.join(videos_dir, ".src")
    os.makedirs(src_dir, exist_ok=True)

    have_ffmpeg = subprocess.run(["sh", "-c", "command -v ffmpeg"], capture_output=True).returncode == 0

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

    for v in remote:
        name, url = v["name"], v["url"]
        size = int(v.get("size") or 0)
        src = os.path.join(src_dir, name)
        out = os.path.join(videos_dir, name)
        stamp = os.path.join(src_dir, name + ".stamp")

        # 2) Original laden, wenn fehlt/geaendert
        if not (os.path.isfile(src) and (size == 0 or os.path.getsize(src) == size)):
            try:
                blob = fetch(url)
            except Exception as e:
                log(f"Download fehlgeschlagen: {name} ({e})")
                continue
            if size and len(blob) != size:
                log(f"Groesse weicht ab: {name} - uebersprungen.")
                continue
            if len(blob) < 1000 or blob[:1] == b"<":
                log(f"Ungueltige Datei: {name} - uebersprungen.")
                continue
            dl = os.path.join(src_dir, name + ".dl")
            with open(dl, "wb") as f:
                f.write(blob)
            os.replace(dl, src)
            try:
                os.remove(stamp)          # Original neu -> Ausgabe neu erzeugen
            except OSError:
                pass
            log(f"Geladen: {name} ({len(blob)} Bytes)")

        # 3) Abspielbare <=720p-Fassung erzeugen (falls noch nicht aktuell)
        cur = None
        try:
            with open(stamp) as f:
                cur = f.read().strip()
        except OSError:
            pass
        if os.path.isfile(out) and cur == str(os.path.getsize(src)):
            continue                       # schon aktuell

        h = video_height(src) if have_ffmpeg else None
        if have_ffmpeg and h and h > MAXH:
            log(f"Transkodiere auf 720p: {name} (war {h}p) ...")
            if not to_720(src, out):
                log(f"  Transkodierung fehlgeschlagen: {name} - nutze Original.")
                _copy(src, out)
        else:
            if h and h > MAXH:
                log(f"WARNUNG: {name} ist {h}p, aber ffmpeg fehlt -> koennte ruckeln (apt install ffmpeg).")
            _copy(src, out)
        try:
            with open(stamp, "w") as f:
                f.write(str(os.path.getsize(src)))
        except OSError:
            pass

    # 4) Aufraeumen: was nicht mehr im Bucket ist, lokal entfernen
    for d in (videos_dir, src_dir):
        for fn in os.listdir(d):
            p = os.path.join(d, fn)
            if not os.path.isfile(p):
                continue
            if fn.endswith((".part", ".dl")):        # transiente Reste
                try:
                    os.remove(p)
                except OSError:
                    pass
                continue
            base = fn[:-6] if fn.endswith(".stamp") else fn   # Rohname des Videos
            if base not in remote_names:
                try:
                    os.remove(p)
                    if fn.endswith(".mp4"):
                        log(f"Entfernt (nicht mehr im Bucket): {fn}")
                except OSError:
                    pass

    # 5) playlist.json (nur fertige Dateien, alphabetisch)
    playlist = [
        {"name": v["name"], "url": "content/videos/" + v["name"]}
        for v in sorted(remote, key=lambda x: x["name"])
        if os.path.isfile(os.path.join(videos_dir, v["name"]))
    ]
    pl = os.path.join(content_dir, "playlist.json")
    tmp = pl + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(playlist, f, indent=2, ensure_ascii=False)
    os.replace(tmp, pl)
    log(f"Fertig: {len(playlist)} Video(s) spielbereit.")
    return 0


def _copy(src, out):
    tmp = out + ".part"
    with open(src, "rb") as a, open(tmp, "wb") as b:
        while True:
            chunk = a.read(1 << 20)
            if not chunk:
                break
            b.write(chunk)
    os.replace(tmp, out)


if __name__ == "__main__":
    sys.exit(main())
