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
import signal
import socket
import time
import urllib.request
from datetime import datetime, timezone

# IPv4 erzwingen: Auf manchen Standort-Netzen wird IPv6 zwar aufgeloest, hat aber
# keine Route -> getaddrinfo/urllib bleiben an der IPv6-Adresse haengen (5s-DNS-
# Timeouts). Wir liefern nur noch IPv4 zurueck (wie 'curl -4' in den Shell-Skripten).
_orig_getaddrinfo = socket.getaddrinfo
def _getaddrinfo_ipv4_only(host, port, family=0, type=0, proto=0, flags=0):
    return _orig_getaddrinfo(host, port, socket.AF_INET, type, proto, flags)
socket.getaddrinfo = _getaddrinfo_ipv4_only

CONFIG_PATH = os.environ.get("SIGNAGE_DEVICE_JSON", "/opt/school-signage/config/device.json")
BIN_DIR = os.path.dirname(os.path.abspath(__file__))
TIMEOUT = 30
GOOGLE = "https://docs.google.com/presentation/d/{id}/export/{fmt}"

# Selbst-Update: welche Repo-Dateien in bin/ gespiegelt werden (repo-Pfad ->
# (Zielname, ausfuehrbar?)). Nach einem git push zieht render-sync diese bei
# seinem naechsten Lauf nach -> ALLE online Pis reparieren sich ohne SSH selbst.
MANAGED_FILES = {
    "pi/render-sync.py":         ("render-sync.py", True),
    "pi/display-schedule.sh":    ("display-schedule.sh", True),
    "pi/display-watchdog.sh":    ("display-watchdog.sh", True),
    "pi/heartbeat.sh":           ("heartbeat.sh", True),
    "pi/command-poll.sh":        ("command-poll.sh", True),
    "tools/build_manifest.py":   ("build_manifest.py", False),
    "tools/normalize_slides.py": ("normalize_slides.py", False),
}

# Dasselbe fuer die Player-Dateien in web/. Ohne das koennte eine Korrektur am
# Player NUR per Neuinstallation auf die Pis - genau die Luecke, durch die der
# Bild-Cache-Fehler lange unbemerkt blieb.
MANAGED_WEB = {
    "player/app.js":     "app.js",
    "player/index.html": "index.html",
    "player/style.css":  "style.css",
}


def log(msg):
    print(f"[render-sync] {datetime.now(timezone.utc).isoformat()} {msg}", flush=True)


# Notbremse: Ein Lauf darf NIE ewig haengen. Passiert das trotzdem (haengendes
# pdftoppm, halb offene Verbindung), blockiert er sonst mit seiner Dateisperre
# alle folgenden Laeufe -> der Inhalt friert ein, bis jemand den Pi neu startet.
# Genau dieser Fall ist in der Praxis aufgetreten. SIGALRM beendet den Lauf hart;
# beim naechsten Timer-Lauf (3 Min) wird sauber neu versucht.
HARD_TIMEOUT = int(os.environ.get("SIGNAGE_SYNC_TIMEOUT", "240"))

# Wie oft die PPTX zusaetzlich geprueft wird (erkennt Ein-/Ausblenden und
# geaenderte "dauer:"-Notizen - beides ist im PDF NICHT sichtbar).
# Kleiner = schneller erkannt, aber mehr Datenvolumen (PPTX ~3 MB).
PPTX_CHECK_SEC = int(os.environ.get("SIGNAGE_PPTX_CHECK_SEC", "900"))   # 15 Min

# Mindestabstand zwischen zwei Render-VERSUCHEN (Google-Export holen + rendern).
# Der Timer feuert oefter; dazwischen wird nur self_update ausgefuehrt.
RENDER_MIN_SEC = int(os.environ.get("SIGNAGE_RENDER_MIN_SEC", "600"))   # 10 Min


def _watchdog_timeout(signum, frame):
    log(f"NOTBREMSE: Lauf haengt seit {HARD_TIMEOUT}s -> Abbruch. "
        "Aktuelle Anzeige bleibt aktiv, naechster Lauf versucht es erneut.")
    os._exit(2)          # hart raus: Sperre wird vom OS freigegeben


def arm_hard_timeout():
    try:
        signal.signal(signal.SIGALRM, _watchdog_timeout)
        signal.alarm(HARD_TIMEOUT)
    except (AttributeError, ValueError):
        pass             # z. B. Windows/Nicht-Hauptthread: dann eben ohne


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


def active_content_hash(web_dir):
    man = os.path.join(web_dir, "content", "manifest.json")
    try:
        with open(man, encoding="utf-8") as f:
            return json.load(f).get("contentHash")
    except Exception:
        return None


def _rmtree(path):
    import shutil
    shutil.rmtree(path, ignore_errors=True)


def ensure_content_hash(web_dir):
    """Fehlt dem AKTIVEN Manifest der Inhalts-Fingerabdruck (Altbestand), wird er
    nachtraeglich aus den vorhandenen Folien gebildet - ohne neu zu rendern.
    Sonst waere die naechste echte Aenderung nicht als solche erkennbar."""
    man_path = os.path.join(web_dir, "content", "manifest.json")
    try:
        with open(man_path, encoding="utf-8") as f:
            man = json.load(f)
    except Exception:
        return
    if man.get("contentHash"):
        return
    base = os.path.dirname(os.path.realpath(man_path))
    ch = hashlib.sha256()
    try:
        for s in man.get("baseLayer", {}).get("slides", []):
            with open(os.path.join(base, s["file"]), "rb") as f:
                ch.update(f.read())
            ch.update(str(s.get("durationSeconds", "")).encode())
    except Exception:
        return
    man["contentHash"] = ch.hexdigest()
    tmp = man_path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(man, f, indent=2, ensure_ascii=False)
        os.replace(tmp, man_path)
        log("Inhalts-Fingerabdruck fuer bestehenden Inhalt nachgetragen.")
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass


def _nocache(url):
    """Cache-Buster anhaengen. Ohne den kann ein Proxy/CDN dem Pi tagelang ein
    altes Google-Export ausliefern -> 'keine Aenderung', Bildschirm friert ein."""
    sep = "&" if "?" in url else "?"
    return f"{url}{sep}_cb={int(time.time())}"


def _pptx_state_path(data_dir):
    return os.path.join(data_dir, ".pptx-state.json")


def _load_pptx_state(data_dir):
    try:
        with open(_pptx_state_path(data_dir), encoding="utf-8") as f:
            d = json.load(f)
        return d.get("hash"), float(d.get("ts") or 0)
    except Exception:
        return None, 0.0


def _save_pptx_state(data_dir, pptx_hash):
    try:
        with open(_pptx_state_path(data_dir), "w", encoding="utf-8") as f:
            json.dump({"hash": pptx_hash, "ts": time.time()}, f)
    except OSError:
        pass


def _kill_stuck_siblings():
    """Haengende render-sync/pdftoppm-Prozesse beenden - OHNE sich selbst.
    (pkill -f 'render-sync.py' wuerde den eigenen Prozess mit treffen.)"""
    me = os.getpid()
    try:
        out = subprocess.run(["ps", "-eo", "pid=,etimes=,args="],
                             capture_output=True, text=True, timeout=15).stdout
    except Exception:
        return
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        try:
            pid, etimes = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        args = parts[2]
        if pid == me or pid == os.getppid():
            continue
        if etimes < 600:                       # nur wirklich alte Prozesse
            continue
        if "render-sync.py" in args or "pdftoppm" in args:
            try:
                os.kill(pid, signal.SIGKILL)
                log(f"  haengenden Prozess beendet: pid={pid} ({etimes}s alt)")
            except OSError:
                pass


def _repo_raw_base(config_url):
    """Aus der configUrl (.../main/groups/<gid>/config.json) die Repo-Raw-Basis
    (.../main) ableiten -> von dort holen wir die bin/-Skripte."""
    i = config_url.find("/groups/")
    return config_url[:i] if i != -1 else None


def _valid_source(repo_path, data):
    """Nur syntaktisch plausible Dateien uebernehmen (schuetzt vor kaputtem
    Teil-Download, der sonst die ganze Flotte lahmlegen koennte)."""
    if not data:
        return False
    if repo_path.endswith(".py"):
        try:
            compile(data.decode("utf-8"), repo_path, "exec")
        except Exception:
            return False
    elif repo_path.endswith(".sh"):
        if not data.lstrip().startswith(b"#!"):
            return False
    elif repo_path.endswith((".js", ".css", ".html")):
        # Player-Dateien: gegen abgeschnittene Downloads / Fehlerseiten schuetzen.
        # (Ein kaputtes app.js wuerde die Anzeige auf ALLEN Pis lahmlegen.)
        if len(data) < 200:
            return False
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            return False
        if repo_path.endswith(".js") and text.lstrip().startswith("<"):
            return False               # HTML-Fehlerseite statt JavaScript
        if repo_path.endswith(".html") and "<" not in text[:200]:
            return False
    return True


def _refresh_browser():
    """Player-Dateien haben sich geaendert -> Browser-Cache leeren und Chromium
    neu starten (der Autostart-Loop faengt ihn in ~3s wieder auf). Ohne das
    laedt Chromium das ALTE app.js aus seinem Cache weiter."""
    home = os.path.expanduser("~")
    for p in (".cache/chromium",
              ".config/chromium/Default/Cache",
              ".config/chromium/Default/Code Cache"):
        _rmtree(os.path.join(home, p))
    if os.path.exists("/tmp/signage-kiosk-stop"):
        return                       # Wartungsmodus: Finger weg
    subprocess.run(["pkill", "chromium"], check=False)
    log("Player aktualisiert -> Browser-Cache geleert und Chromium neu gestartet.")


def self_update(config_url, bin_dir, web_dir=None):
    """Spiegelt die MANAGED_FILES aus dem Repo nach bin/ (token-frei, IPv4).
    Jeder Fehler ist unkritisch: das File bleibt dann unveraendert, die Anzeige
    laeuft weiter. Aktualisiertes render-sync.py greift beim naechsten Lauf."""
    base = _repo_raw_base(config_url)
    if not base:
        return
    targets = [(rp, os.path.join(bin_dir, name), ex) for rp, (name, ex) in MANAGED_FILES.items()]
    web_changed = False
    if web_dir:
        targets += [(rp, os.path.join(web_dir, name), False) for rp, name in MANAGED_WEB.items()]
    for repo_path, target, execbit in targets:
        url = base + "/" + repo_path
        bust = ("&" if "?" in url else "?") + "t=" + str(int(time.time()))
        try:
            data = fetch(url + bust, timeout=15)
        except Exception:
            continue                       # Netz kurz weg -> spaeter erneut
        if not _valid_source(repo_path, data):
            continue
        name = os.path.basename(target)
        try:
            with open(target, "rb") as f:
                if f.read() == data:
                    continue               # schon aktuell
        except OSError:
            pass
        tmp = target + ".tmp"
        try:
            with open(tmp, "wb") as f:
                f.write(data)
            if execbit:
                os.chmod(tmp, 0o755)
            os.replace(tmp, target)        # atomar
            log(f"Selbst-Update: {name} aktualisiert ({len(data)} Bytes).")
            if web_dir and os.path.dirname(target) == os.path.normpath(web_dir):
                web_changed = True
        except OSError as e:
            log(f"Selbst-Update {name} fehlgeschlagen ({e}) - unveraendert.")
            try:
                os.remove(tmp)
            except OSError:
                pass

    if web_changed:
        _refresh_browser()


def main():
    arm_hard_timeout()          # Lauf kann sich nicht dauerhaft aufhaengen
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
    lock_path = os.path.join(data_dir, ".sync.lock")
    lock_file = open(lock_path, "w")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        # Sperre belegt. Normalfall: ein paralleler Lauf -> ueberspringen.
        # Alarmfall: ein Lauf haengt seit Ewigkeiten und blockiert alles (der
        # Inhalt friert dann ein). Das melden wir deutlich, statt es zu
        # verschweigen - so taucht es im Log/Heartbeat auf.
        try:
            stuck = time.time() - os.path.getmtime(lock_path)
        except OSError:
            stuck = 0
        if stuck > 600:
            log(f"WARNUNG: Sperre seit {stuck/60:.0f} Min belegt – ein Lauf haengt fest "
                "-> haengende Prozesse werden beendet, naechster Lauf raeumt auf.")
            _kill_stuck_siblings()
        else:
            log("Ein anderer Lauf ist aktiv – uebersprungen.")
        return 0

    # 0) Selbst-Update der bin/-Skripte aus dem Repo. So erreicht ein 'git push'
    #    ALLE online Pis automatisch (ohne SSH/Netzzugang zum Pi). Laeuft bei
    #    JEDEM Durchgang (schnelle Code-Verteilung), unabhaengig vom Render-Takt.
    self_update(config_url, BIN_DIR, web_dir)
    ensure_content_hash(web_dir)      # Altbestand nachtragen (einmalig je Pi)

    # Render-Bremse: Der systemd-Timer feuert alle ~3 Min, aber Google-Export
    # holen + rendern kostet CPU/Bandbreite. Weil echte Inhaltsaenderungen selten
    # sind, genuegt ein Render-VERSUCH alle RENDER_MIN_SEC (Standard 10 Min).
    stampf = os.path.join(data_dir, ".last-render-attempt")
    try:
        last_try = os.path.getmtime(stampf)
    except OSError:
        last_try = 0
    if time.time() - last_try < RENDER_MIN_SEC:
        return 0
    open(stampf, "w").close()          # Versuchszeitpunkt merken

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

    # 2) PDF holen. WICHTIG: mit Cache-Buster! Ohne den liefert ein Schul-Proxy
    #    (oder eine Google-Edge) tagelang ein altes PDF -> der Pi sieht "keine
    #    Aenderung" und der Bildschirm bleibt auf altem Stand haengen.
    try:
        pdf = fetch(_nocache(GOOGLE.format(id=gid_src, fmt="pdf")))
    except Exception as e:
        log(f"Google-PDF nicht erreichbar ({e}). Aktuelle Version bleibt aktiv.")
        return 1
    if not pdf.startswith(b"%PDF"):
        log("Google-PDF ungueltig (nicht oeffentlich freigegeben?). Aktuelle Version bleibt aktiv.")
        return 1

    # 2b) Die PPTX bestimmt, welche Folien SICHTBAR sind (show="0") und wie lange
    #     sie stehen (Notizen "dauer:"). Beides steht NICHT im PDF - ausgeblendete
    #     Folien sind im PDF enthalten. Ohne die PPTX bliebe ein Ein-/Ausblenden
    #     also unsichtbar und wuerde nie auf dem Bildschirm ankommen.
    #     Kompromiss fuers Datenvolumen: die PPTX nicht bei JEDEM Lauf laden,
    #     sondern hoechstens alle PPTX_CHECK_SEC (Standard 15 Min); dazwischen
    #     gilt der zuletzt bekannte PPTX-Hash.
    pptx = None
    pptx_hash, pptx_ts = _load_pptx_state(data_dir)
    if pptx_hash is None or (time.time() - pptx_ts) > PPTX_CHECK_SEC:
        try:
            pptx = fetch(_nocache(GOOGLE.format(id=gid_src, fmt="pptx")))
            if not pptx.startswith(b"PK"):
                raise RuntimeError("PPTX ungueltig")
            pptx_hash = hashlib.sha256(pptx).hexdigest()
            _save_pptx_state(data_dir, pptx_hash)
        except Exception as e:
            log(f"Google-PPTX nicht abrufbar ({e}) – nutze letzten bekannten Stand.")
            pptx = None
            if pptx_hash is None:
                return 1

    # 3) Aenderungserkennung: Hash aus PDF + Config + PPTX
    h = hashlib.sha256()
    h.update(pdf)
    h.update(config_raw)
    h.update(pptx_hash.encode())
    source_hash = h.hexdigest()
    if source_hash == active_source_hash(web_dir):
        log("Keine Aenderung (gleicher Inhalt) - nichts zu rendern.")
        return 0

    # Geaendert -> PPTX wird zum Rendern gebraucht (falls noch nicht geladen).
    if pptx is None:
        try:
            pptx = fetch(_nocache(GOOGLE.format(id=gid_src, fmt="pptx")))
        except Exception as e:
            log(f"Google-PPTX nicht erreichbar ({e}). Aktuelle Version bleibt aktiv.")
            return 1
        if not pptx.startswith(b"PK"):
            log("Google-PPTX ungueltig. Aktuelle Version bleibt aktiv.")
            return 1

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
        # timeout: haengendes pdftoppm darf den Lauf nicht blockieren
        subprocess.run(
            ["pdftoppm", "-png", "-scale-to-x", "1920", "-scale-to-y", "-1",
             pdf_path, os.path.join(slides_dir, "slide")],
            check=True, timeout=150,
        )
        subprocess.run([sys.executable, os.path.join(BIN_DIR, "normalize_slides.py"), slides_dir],
                       check=True, timeout=60)

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
            check=True, timeout=120,
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

        # Inhalts-Fingerabdruck: Hash ueber das, was der Betrachter WIRKLICH
        # sieht - die sichtbaren Folienbilder in ihrer Reihenfolge samt Dauer.
        # Unterscheidet eine echte Inhaltsaenderung von einem blossen Neu-Rendern
        # (z. B. weil sich die Hash-Formel oder eine Einstellung geaendert hat).
        ch = hashlib.sha256()
        for s in slides:
            with open(os.path.join(staging, s["file"]), "rb") as f:
                ch.update(f.read())
            ch.update(str(s.get("durationSeconds", "")).encode())
        man["contentHash"] = ch.hexdigest()
        with open(os.path.join(staging, "manifest.json"), "w", encoding="utf-8") as f:
            json.dump(man, f, indent=2, ensure_ascii=False)

        # ENTSCHEIDENDES TOR gegen die Schreibflut: Google-Exporte sind
        # byte-instabil (Zeitstempel im PDF) -> der source_hash aendert sich bei
        # JEDEM Abruf, auch wenn inhaltlich nichts anders ist. Ohne diesen
        # Vergleich wuerde der Pi endlos neue Versionen erzeugen -> jeder Heartbeat
        # feuert sofort + ein Ereignis pro Re-Render -> KV-Limit gesprengt.
        # Nur weiterschalten, wenn sich das SICHTBARE Bild wirklich geaendert hat.
        if man["contentHash"] == active_content_hash(web_dir):
            log("Neu gerendert, aber Bildinhalt unveraendert - keine neue Version.")
            _rmtree(staging)
            return 0
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
