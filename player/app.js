'use strict';

/* Schule Neckertal – Signage Player (Phase 1: lokaler Player)
 *
 * Aufgaben:
 *  - manifest.json lesen
 *  - Folienbilder als Endlos-Slideshow abspielen (Dauer pro Folie aus Manifest)
 *  - Overlay mit Uhr/Datum anzeigen (Layer 2)
 *  - optionalen Ticker anzeigen (Layer 3)
 *  - ausserhalb der Betriebszeit Black-Screen zeigen (Zeitplan)
 *  - robust mit Fehlern umgehen (fehlendes Manifest, fehlende Bilder)
 *
 * Bewusst NICHT in dieser Phase: Netzwerk-Sync, API, Heartbeat, current/next/previous.
 * Der Player liest nur die lokale manifest.json.
 */

// ---------- Logging ----------
const ts = () => new Date().toISOString();
const log  = (...a) => console.log('[Player]', ts(), ...a);
const warn = (...a) => console.warn('[Player]', ts(), ...a);
const fail = (...a) => console.error('[Player]', ts(), ...a);

// ---------- Entwicklungs-Schalter ----------
// ?ignoreSchedule=1  -> Inhalte unabhaengig vom Zeitplan zeigen (zum Testen tagsueber/nachts)
const params = new URLSearchParams(location.search);
const IGNORE_SCHEDULE = params.get('ignoreSchedule') === '1';

// Inhalte (manifest + Folien) liegen unter content/. Auf dem Pi ist content/
// ein Symlink, den der Sync-Agent atomar auf die aktuelle Version umschaltet.
const CONTENT_BASE = 'content/';
const MANIFEST_URL = CONTENT_BASE + 'manifest.json';

// Wie oft der Player die lokale manifest-Version prüft (der Sync-Agent
// aktualisiert content/ im Hintergrund; bei neuer Version lädt der Player neu).
const VERSION_CHECK_INTERVAL_MS = 60 * 1000;

// ---------- Zustand ----------
let manifest = null;
let loadedVersion = null;
let slides = [];
let currentIndex = -1;
let activeLayerIsA = false;     // welche der beiden Bild-Ebenen ist gerade sichtbar
let slideTimer = null;
let scheduleActive = true;

// ---------- DOM ----------
const dom = {};
function cacheDom() {
  dom.slideA      = document.getElementById('slide-a');
  dom.slideB      = document.getElementById('slide-b');
  dom.overlayClock = document.getElementById('overlay-clock');
  dom.overlayDate  = document.getElementById('overlay-date');
  dom.clock    = document.getElementById('clock');
  dom.date     = document.getElementById('date');
  dom.ticker   = document.getElementById('ticker');
  dom.tickerTx = document.getElementById('ticker-text');
  dom.black    = document.getElementById('blackscreen');
  dom.message  = document.getElementById('message');
}

// ============================================================
//  Start
// ============================================================
async function start() {
  cacheDom();
  log('Player startet.', IGNORE_SCHEDULE ? '(Zeitplan wird ignoriert)' : '');

  startClock();                 // Uhr laeuft unabhaengig von der Slideshow

  const ok = await loadManifest();
  if (!ok) return;              // Fehlermeldung wurde bereits gezeigt

  applyOverlayConfig();
  applyTickerConfig();
  await preloadSlides();

  // Zeitplan einmal pruefen und danach jede Minute erneut
  evaluateSchedule();
  setInterval(evaluateSchedule, 30 * 1000);

  // Auf neue Inhalte vom Sync-Agent reagieren
  startUpdateChecker();
}

// ============================================================
//  Manifest laden
// ============================================================
async function loadManifest() {
  try {
    const res = await fetch(MANIFEST_URL, { cache: 'no-store' });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    manifest = await res.json();
  } catch (e) {
    fail('Manifest konnte nicht geladen werden:', e.message);
    showMessage('Inhalte konnten nicht geladen werden.\nManifest fehlt oder ist ungültig.');
    return false;
  }

  slides = (manifest.baseLayer && Array.isArray(manifest.baseLayer.slides))
    ? manifest.baseLayer.slides
    : [];

  if (slides.length === 0) {
    fail('Manifest enthält keine Folien.');
    showMessage('Keine Folien im Manifest vorhanden.');
    return false;
  }

  loadedVersion = manifest.version;
  log(`Manifest geladen. Version ${manifest.version}, ${slides.length} Folien, ` +
      `Standarddauer ${manifest.defaultSlideDurationSeconds}s.`);
  return true;
}

// Prüft periodisch, ob der Sync-Agent eine neue Version aktiviert hat,
// und lädt die Seite dann neu (frische Folien + Manifest). Offline-tolerant.
function startUpdateChecker() {
  setInterval(async () => {
    try {
      const res = await fetch(MANIFEST_URL, { cache: 'no-store' });
      if (!res.ok) return;
      const m = await res.json();
      if (m.version && m.version !== loadedVersion) {
        log(`Neue Version erkannt (${m.version} statt ${loadedVersion}) – lade neu.`);
        location.reload();
      }
    } catch (e) {
      /* offline / Server kurz weg – ignorieren, lokale Anzeige läuft weiter */
    }
  }, VERSION_CHECK_INTERVAL_MS);
}

// Dauer einer Folie bestimmen: gueltiger Folienwert > Standarddauer.
function durationFor(slide) {
  const def = Number(manifest.defaultSlideDurationSeconds) || 12;
  const d = Number(slide.durationSeconds);
  if (!Number.isFinite(d) || d <= 0) {
    if (slide.durationSeconds !== undefined) {
      warn(`Ungültige Dauer "${slide.durationSeconds}" für ${slide.file} – Standarddauer ${def}s.`);
    }
    return def;
  }
  return d;
}

// ============================================================
//  Bilder vorladen (damit Uebergaenge ruckelfrei sind)
// ============================================================
function preloadSlides() {
  const loaders = slides.map(s => new Promise(resolve => {
    const img = new Image();
    img.onload  = () => resolve();
    img.onerror = () => { warn('Bild fehlt/defekt beim Vorladen:', s.file); resolve(); };
    img.src = CONTENT_BASE + s.file;
  }));
  return Promise.all(loaders).then(() => log('Folien vorgeladen.'));
}

// ============================================================
//  Slideshow
// ============================================================
function startSlideshow() {
  if (slideTimer) return;       // laeuft schon
  log('Slideshow startet.');
  showNextSlide();
}

function stopSlideshow() {
  if (slideTimer) { clearTimeout(slideTimer); slideTimer = null; }
}

function showNextSlide() {
  currentIndex = (currentIndex + 1) % slides.length;
  const slide = slides[currentIndex];
  const seconds = durationFor(slide);

  // inaktive Bild-Ebene mit der naechsten Folie belegen, dann einblenden
  const showEl = activeLayerIsA ? dom.slideB : dom.slideA;
  const hideEl = activeLayerIsA ? dom.slideA : dom.slideB;

  showEl.onerror = () => {
    warn('Folie kann nicht angezeigt werden, wird übersprungen:', slide.file);
  };
  showEl.src = CONTENT_BASE + slide.file;
  showEl.classList.add('active');
  hideEl.classList.remove('active');
  activeLayerIsA = !activeLayerIsA;

  log(`Folie ${currentIndex + 1}/${slides.length}: ${slide.file} (${seconds}s)`);
  slideTimer = setTimeout(showNextSlide, seconds * 1000);
}

// ============================================================
//  Layer 2: Overlay (Uhr / Datum)
// ============================================================
function applyOverlayConfig() {
  const o = manifest.overlayLayer || {};
  const POSITIONS = ['top-left', 'top-center', 'top-right',
                     'bottom-left', 'bottom-center', 'bottom-right'];
  const THEMES = ['auto', 'dark', 'light', 'transparent-dark', 'transparent-light'];
  const theme = THEMES.includes(o.theme) ? o.theme : 'auto';

  // Uhr und Datum werden unabhaengig voneinander positioniert.
  positionOverlayItem(dom.overlayDate,  o.showDate,  o.datePosition,  'top-center', theme, POSITIONS);
  positionOverlayItem(dom.overlayClock, o.showClock, o.clockPosition, 'top-right',  theme, POSITIONS);
}

function positionOverlayItem(el, show, position, fallbackPos, theme, allowedPositions) {
  if (!el) return;
  if (!show) { el.hidden = true; return; }
  el.hidden = false;
  el.className = 'overlay-item';
  el.classList.add('pos-' + (allowedPositions.includes(position) ? position : fallbackPos));
  el.classList.add('theme-' + theme);
}

function startClock() {
  const tick = () => {
    const now = new Date();
    if (dom.clock) {
      dom.clock.textContent = now.toLocaleTimeString('de-CH',
        { hour: '2-digit', minute: '2-digit' });
    }
    if (dom.date) {
      dom.date.textContent = now.toLocaleDateString('de-CH',
        { weekday: 'long', day: '2-digit', month: 'long', year: 'numeric' });
    }
  };
  tick();
  setInterval(tick, 1000);
}

// ============================================================
//  Layer 3: Ticker
// ============================================================
function applyTickerConfig() {
  const t = manifest.tickerLayer || {};
  if (t.active && t.text) {
    dom.tickerTx.textContent = t.text;
    dom.ticker.hidden = false;
    log('Ticker aktiv:', t.text);
  } else {
    dom.ticker.hidden = true;
  }
}

// ============================================================
//  Zeitplan / Black-Screen
// ============================================================
const DAYS = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];

function isWithinSchedule(now) {
  if (IGNORE_SCHEDULE) return true;
  const sch = manifest.schedule;
  if (!sch) return true;        // ohne Zeitplan immer aktiv

  const day = sch[DAYS[now.getDay()]];
  if (!day || !day.active) return false;
  if (!day.from || !day.until) return true;   // aktiv ohne Zeitfenster = ganztags

  const cur = now.getHours() * 60 + now.getMinutes();
  const [fh, fm] = day.from.split(':').map(Number);
  const [uh, um] = day.until.split(':').map(Number);
  return cur >= (fh * 60 + fm) && cur < (uh * 60 + um);
}

function evaluateSchedule() {
  const active = isWithinSchedule(new Date());
  if (active === scheduleActive && slideTimer) return;   // keine Aenderung
  scheduleActive = active;

  if (active) {
    log('Innerhalb Betriebszeit → Anzeige aktiv.');
    dom.black.hidden = true;
    startSlideshow();
  } else {
    const mode = (manifest.schedule && manifest.schedule.offMode) || 'black_screen';
    log(`Ausserhalb Betriebszeit → ${mode}.`);
    // Im Browser-Player bedeuten black_screen und hdmi_off beide: schwarzes Bild.
    // hdmi_off / browser_stop werden spaeter auf dem Raspberry Pi systemseitig umgesetzt.
    stopSlideshow();
    dom.black.hidden = false;
  }
}

// ============================================================
//  Hilfen
// ============================================================
function showMessage(text) {
  if (!dom.message) return;
  dom.message.textContent = text;
  dom.message.hidden = false;
}

// Los geht's, sobald das DOM bereit ist.
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', start);
} else {
  start();
}
