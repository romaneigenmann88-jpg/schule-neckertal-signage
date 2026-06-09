'use strict';

// Adminkonsole – statisch, liest groups.json + manifest.json von Pages.
// Einstellungen werden in groups/<id>/config.json gespeichert (über GitHub-Web).

const REPO = 'romaneigenmann88-jpg/schule-neckertal-signage';
const BRANCH = 'main';
const HEARTBEAT_URL = 'https://signage-heartbeat.schule-neckertal.workers.dev';
const ONLINE_MS = 12 * 60 * 1000;   // online, wenn vor < 12 Min gesehen
const rawConfigUrl = (gid) => `https://raw.githubusercontent.com/${REPO}/${BRANCH}/groups/${gid}/config.json`;
const editConfigUrl = (gid) => `https://github.com/${REPO}/edit/${BRANCH}/groups/${gid}/config.json`;

const DAYS = [
  ['monday', 'Montag'], ['tuesday', 'Dienstag'], ['wednesday', 'Mittwoch'],
  ['thursday', 'Donnerstag'], ['friday', 'Freitag'], ['saturday', 'Samstag'], ['sunday', 'Sonntag'],
];
const DAYS_SHORT = { monday: 'Mo', tuesday: 'Di', wednesday: 'Mi', thursday: 'Do', friday: 'Fr', saturday: 'Sa', sunday: 'So' };
const POSITIONS = [
  ['top-left', 'oben links'], ['top-center', 'oben Mitte'], ['top-right', 'oben rechts'],
  ['bottom-left', 'unten links'], ['bottom-center', 'unten Mitte'], ['bottom-right', 'unten rechts'],
];
const THEMES = [
  ['auto', 'automatisch – immer lesbar (empfohlen)'],
  ['dark', 'dunkler Kasten / weisse Schrift'],
  ['light', 'heller Kasten / schwarze Schrift'],
  ['transparent-dark', 'transparent / schwarze Schrift'],
  ['transparent-light', 'transparent / weisse Schrift'],
];
const OFFMODES = [['hdmi_off', 'HDMI aus (TV-Standby)'], ['black_screen', 'schwarzer Bildschirm']];

const $ = (id) => document.getElementById(id);

// ============================================================
//  Dashboard
// ============================================================
async function main() {
  let index;
  try {
    index = await fetchJson('groups.json');
  } catch (e) {
    $('empty').hidden = false;
    $('empty').textContent = 'groups.json konnte nicht geladen werden.';
    $('meta').textContent = '';
    return;
  }
  $('meta').textContent = `Stand: ${fmtDate(index.generated)} · ${index.groups.length} Gruppe(n)`;

  // Live-Status (Heartbeat) holen und nach Gruppe sortieren
  let beats = null;
  try {
    const hb = await (await fetch(`${HEARTBEAT_URL}?n=${Date.now()}`, { cache: 'no-store' })).json();
    beats = {};
    for (const p of (hb.players || [])) (beats[p.groupId] = beats[p.groupId] || []).push(p);
  } catch (e) { beats = null; }

  const container = $('groups');
  container.innerHTML = '';
  for (const gid of index.groups) {
    try {
      const m = await fetchJson(`groups/${gid}/manifest.json`);
      const players = beats ? (beats[gid] || []) : null;
      container.appendChild(card(gid, m, players));
    } catch (e) { /* überspringen */ }
  }
  if (!container.children.length) $('empty').hidden = false;
}

function card(gid, m, players) {
  const slides = (m.baseLayer && m.baseLayer.slides) || [];
  const thumb = slides.length ? `groups/${gid}/${slides[0].file}` : '';
  const el = document.createElement('div');
  el.className = 'card';
  el.innerHTML = `
    <div class="thumb"${thumb ? ` style="background-image:url('${thumb}')"` : ''}></div>
    <div class="body">
      <h2>${esc(m.title || gid)}</h2>
      <div class="sub">${esc(gid)}</div>
      <div class="stats"><span>🖼 ${slides.length} Folien</span><span>🕒 ${fmtDate(m.version)}</span></div>
      <div class="sched">🗓 ${esc(scheduleSummary(m.schedule || {}))}</div>
      ${liveStatusHtml(players, m.version)}
      ${warnHtml(m.warnings)}
      <div class="actions">
        <a class="btn edit" href="${esc(m.editUrl || '#')}" target="_blank" rel="noopener">✏️ Folien</a>
        <button class="btn settings">⚙️ Einstellungen</button>
        <button class="btn ghost preview">👁</button>
      </div>
      <button class="addscreen-link wide">➕ Bildschirm hinzufügen</button>
    </div>`;
  el.querySelector('.preview').addEventListener('click', () => openPreview(gid, m));
  el.querySelector('.settings').addEventListener('click', () => openSettings(gid, m));
  el.querySelector('.addscreen-link').addEventListener('click', () => openAddScreen(gid, m));
  return el;
}

function warnHtml(ws) {
  if (!ws || !ws.length) return '';
  return `<div class="warnings">⚠ ${ws.map(esc).join('<br>')}</div>`;
}

// Live-Status der real gemeldeten Bildschirme (aus dem Heartbeat)
function liveStatusHtml(players, currentVersion) {
  if (players === null) return '<div class="livestatus muted">⚪ Live-Status nicht erreichbar</div>';
  if (!players.length) return '<div class="livestatus muted">📺 Noch kein Bildschirm gemeldet</div>';
  const now = Date.now();
  const rows = players.slice().sort((a, b) => (a.playerId > b.playerId ? 1 : -1)).map((p) => {
    const seen = Date.parse(p.lastSeen);
    const online = (now - seen) < ONLINE_MS;
    const dot = online ? '🟢' : '🔴';
    const verNote = (p.version && currentVersion && p.version !== currentVersion) ? ' · ⚠ alte Version' : '';
    return `<div class="pl">${dot} <strong>${esc(p.playerId)}</strong> · ${online ? 'online' : 'offline'} · zuletzt ${relTime(seen)}${verNote}</div>`;
  }).join('');
  return `<div class="livestatus">${rows}</div>`;
}
function relTime(ms) {
  if (!ms) return '–';
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (s < 90) return 'gerade eben';
  const min = Math.round(s / 60);
  if (min < 90) return `vor ${min} Min`;
  const h = Math.round(min / 60);
  if (h < 36) return `vor ${h} Std`;
  return `vor ${Math.round(h / 24)} Tagen`;
}
function scheduleSummary(s) {
  if (!s || !Object.keys(s).length) return 'kein Zeitplan';
  const parts = [];
  for (const [k] of DAYS) {
    const d = s[k];
    if (d && d.active) parts.push(`${DAYS_SHORT[k]} ${d.from || ''}–${d.until || ''}`);
  }
  const off = s.offMode === 'hdmi_off' ? 'HDMI aus' : 'Black-Screen';
  return `${parts.join(' · ') || 'immer aus'} · ausserhalb: ${off}`;
}

// ============================================================
//  Vorschau
// ============================================================
const pv = { slides: [], i: 0, timer: null, clockTimer: null, base: '' };
const PV_POS = ['top-left', 'top-center', 'top-right', 'bottom-left', 'bottom-center', 'bottom-right'];
const PV_THEMES = ['auto', 'dark', 'light', 'transparent-dark', 'transparent-light'];

function openPreview(gid, m) {
  pv.slides = (m.baseLayer && m.baseLayer.slides) || [];
  pv.base = `groups/${gid}/`;
  $('preview-title').textContent = m.title || gid;
  applyPvOverlay(m);
  $('preview').hidden = false;
  showPv(0); autoAdvance(); startPvClock();
}
// Overlay (Layer 2) + Ticker (Layer 3) wie auf dem echten Player darstellen
function applyPvOverlay(m) {
  const o = m.overlayLayer || {};
  const theme = PV_THEMES.includes(o.theme) ? o.theme : 'auto';
  pvSetOverlay($('pv-date'), o.showDate, o.datePosition, 'top-center', theme);
  pvSetOverlay($('pv-clock'), o.showClock, o.clockPosition, 'top-right', theme);
  const t = m.tickerLayer || {};
  if (t.active && t.text) { $('pv-ticker-txt').textContent = t.text; $('pv-ticker').hidden = false; }
  else { $('pv-ticker').hidden = true; }
}
function pvSetOverlay(el, show, pos, fb, theme) {
  if (!show) { el.hidden = true; return; }
  el.hidden = false;
  el.className = 'pv-overlay pos-' + (PV_POS.includes(pos) ? pos : fb) + ' theme-' + theme;
}
function startPvClock() {
  clearInterval(pv.clockTimer);
  const tick = () => {
    const now = new Date();
    $('pv-clock-txt').textContent = now.toLocaleTimeString('de-CH', { hour: '2-digit', minute: '2-digit' });
    $('pv-date-txt').textContent = now.toLocaleDateString('de-CH', { weekday: 'long', day: '2-digit', month: 'long', year: 'numeric' });
  };
  tick(); pv.clockTimer = setInterval(tick, 1000);
}
function showPv(i) {
  if (!pv.slides.length) return;
  pv.i = (i + pv.slides.length) % pv.slides.length;
  const s = pv.slides[pv.i];
  $('preview-img').src = pv.base + s.file;
  $('preview-count').textContent = `${pv.i + 1} / ${pv.slides.length} · ${s.durationSeconds}s`;
}
function autoAdvance() {
  clearTimeout(pv.timer);
  const d = (pv.slides[pv.i] && pv.slides[pv.i].durationSeconds) || 5;
  pv.timer = setTimeout(() => { showPv(pv.i + 1); autoAdvance(); }, Math.min(d, 5) * 1000);
}
function closePv() { $('preview').hidden = true; clearTimeout(pv.timer); clearInterval(pv.clockTimer); }
$('preview-close').addEventListener('click', closePv);
document.querySelector('#preview .modal-bg').addEventListener('click', closePv);
$('preview-prev').addEventListener('click', () => { showPv(pv.i - 1); autoAdvance(); });
$('preview-next').addEventListener('click', () => { showPv(pv.i + 1); autoAdvance(); });

// ============================================================
//  Einstellungen
// ============================================================
let curGid = null;
let curConfig = null;

function openSettings(gid, m) {
  curGid = gid;
  curConfig = configFromManifest(gid, m);
  $('settings-title').textContent = 'Einstellungen – ' + (curConfig.title || gid);
  $('settings-form').innerHTML = buildForm(curConfig);
  $('settings').hidden = false;
}

// Aktuelle Konfiguration aus dem Manifest rekonstruieren (gleiche Struktur wie config.json).
function configFromManifest(gid, m) {
  const match = (m.editUrl || '').match(/\/d\/([^/]+)/);
  return {
    groupId: m.groupId || gid,
    title: m.title || gid,
    players: m.players || [],
    source: { googleSlidesId: match ? match[1] : '' },
    defaultSlideDurationSeconds: m.defaultSlideDurationSeconds || 12,
    schedule: m.schedule || {},
    overlayLayer: m.overlayLayer || {},
    tickerLayer: m.tickerLayer || { active: false, text: '' },
  };
}

function buildForm(c) {
  const ov = c.overlayLayer || {};
  const tk = c.tickerLayer || {};
  const sch = c.schedule || {};
  let dayRows = '';
  for (const [k, label] of DAYS) {
    const d = sch[k] || {};
    dayRows += `
      <div class="day">
        <label class="chk"><input type="checkbox" id="day-${k}" ${d.active ? 'checked' : ''}> ${label}</label>
        <input type="time" id="from-${k}" value="${attr(d.from || '07:00')}">
        <span>bis</span>
        <input type="time" id="until-${k}" value="${attr(d.until || '18:00')}">
      </div>`;
  }
  return `
    <fieldset><legend>Allgemein</legend>
      <label>Titel <input type="text" id="title" value="${attr(c.title || '')}"></label>
      <label>Standarddauer pro Folie (Sek.) <input type="number" id="defaultDur" min="1" value="${attr(c.defaultSlideDurationSeconds || 12)}"></label>
    </fieldset>

    <fieldset><legend>Zeitplan (Bildschirm an)</legend>
      ${dayRows}
      <label>Ausserhalb der Zeit: ${select('offMode', OFFMODES, sch.offMode || 'hdmi_off')}</label>
    </fieldset>

    <fieldset><legend>Overlay (Uhr & Datum)</legend>
      <label class="chk"><input type="checkbox" id="showClock" ${ov.showClock ? 'checked' : ''}> Uhr anzeigen</label>
      <label>Position Uhr: ${select('clockPos', POSITIONS, ov.clockPosition || 'top-right')}</label>
      <label class="chk"><input type="checkbox" id="showDate" ${ov.showDate ? 'checked' : ''}> Datum anzeigen</label>
      <label>Position Datum: ${select('datePos', POSITIONS, ov.datePosition || 'top-center')}</label>
      <label>Darstellung: ${select('theme', THEMES, ov.theme || 'transparent-dark')}</label>
    </fieldset>

    <fieldset><legend>Laufband / Eilmeldung</legend>
      <label class="chk"><input type="checkbox" id="tickerActive" ${tk.active ? 'checked' : ''}> Laufband anzeigen</label>
      <label>Text <input type="text" id="tickerText" value="${attr(tk.text || '')}"></label>
    </fieldset>`;
}

function readForm(c) {
  c.title = $('title').value.trim();
  c.defaultSlideDurationSeconds = parseInt($('defaultDur').value, 10) || 12;
  const sch = c.schedule || (c.schedule = {});
  for (const [k] of DAYS) {
    if ($('day-' + k).checked) sch[k] = { active: true, from: $('from-' + k).value, until: $('until-' + k).value };
    else sch[k] = { active: false };
  }
  sch.offMode = $('offMode').value;
  const ov = c.overlayLayer || (c.overlayLayer = {});
  ov.showClock = $('showClock').checked;
  ov.showDate = $('showDate').checked;
  ov.clockPosition = $('clockPos').value;
  ov.datePosition = $('datePos').value;
  ov.theme = $('theme').value;
  const tk = c.tickerLayer || (c.tickerLayer = {});
  tk.active = $('tickerActive').checked;
  tk.text = $('tickerText').value;
  return c;
}

function closeSettings() { $('settings').hidden = true; }
$('settings-close').addEventListener('click', closeSettings);
$('settings-cancel').addEventListener('click', closeSettings);
document.querySelector('#settings .modal-bg').addEventListener('click', closeSettings);

$('settings-save').addEventListener('click', async () => {
  if (!curConfig || !curGid) return;
  const updated = readForm(curConfig);
  const json = JSON.stringify(updated, null, 2) + '\n';
  try { await navigator.clipboard.writeText(json); } catch (e) { /* Fallback: Textarea */ }
  $('saveinfo-json').value = json;
  $('saveinfo-open').href = editConfigUrl(curGid);
  closeSettings();
  $('saveinfo').hidden = false;
  window.open(editConfigUrl(curGid), '_blank', 'noopener');
});
$('saveinfo-close').addEventListener('click', () => { $('saveinfo').hidden = true; });
document.querySelector('#saveinfo .modal-bg').addEventListener('click', () => { $('saveinfo').hidden = true; });

// ============================================================
//  Bildschirm (Pi) hinzufügen
// ============================================================
let addGid = null;
function openAddScreen(gid, m) {
  addGid = gid;
  const players = m.players || [];
  const last = players[players.length - 1];
  const suggest = last
    ? last.replace(/(\d+)$/, (s) => String(+s + 1).padStart(s.length, '0'))
    : gid.split('_')[0] + '_SCREEN_01';
  $('addscreen-group').textContent = m.title || gid;
  $('addscreen-player').value = suggest;
  updateAddCmd();
  $('addscreen').hidden = false;
}
function updateAddCmd() {
  const pid = ($('addscreen-player').value.trim() || 'SCREEN_01').replace(/\s+/g, '_');
  const manifestUrl = new URL(`groups/${addGid}/manifest.json`, location.href).href;
  const setupUrl = new URL('setup.sh', location.href).href;
  $('addscreen-cmd').value = `curl -fsSL ${setupUrl} | PLAYER_ID=${pid} MANIFEST_URL=${manifestUrl} bash`;
}
$('addscreen-player').addEventListener('input', updateAddCmd);
$('addscreen-copy').addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText($('addscreen-cmd').value);
    const b = $('addscreen-copy'); b.textContent = '✓ kopiert';
    setTimeout(() => { b.textContent = '📋 Befehl kopieren'; }, 1500);
  } catch (e) { /* Textarea bleibt zum manuellen Kopieren */ }
});
$('addscreen-close').addEventListener('click', () => { $('addscreen').hidden = true; });
document.querySelector('#addscreen .modal-bg').addEventListener('click', () => { $('addscreen').hidden = true; });

// ============================================================
//  Hilfen
// ============================================================
function select(id, opts, sel) {
  return `<select id="${id}">` +
    opts.map(([v, l]) => `<option value="${attr(v)}"${v === sel ? ' selected' : ''}>${esc(l)}</option>`).join('') +
    `</select>`;
}
async function fetchJson(path) {
  const res = await fetch(`${path}${path.includes('?') ? '&' : '?'}n=${Date.now()}`, { cache: 'no-store' });
  if (!res.ok) throw new Error('HTTP ' + res.status);
  return res.json();
}
function fmtDate(iso) {
  try {
    return new Date(iso).toLocaleString('de-CH', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });
  } catch (e) { return iso || '–'; }
}
function esc(s) { return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }
function attr(s) { return esc(s); }

main();
