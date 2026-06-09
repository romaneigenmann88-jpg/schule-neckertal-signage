'use strict';

// Adminkonsole – statisch, liest groups.json + je Gruppe manifest.json von Pages.
const DAYS = [
  ['monday', 'Mo'], ['tuesday', 'Di'], ['wednesday', 'Mi'], ['thursday', 'Do'],
  ['friday', 'Fr'], ['saturday', 'Sa'], ['sunday', 'So'],
];

const $ = (id) => document.getElementById(id);

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

  const container = $('groups');
  for (const gid of index.groups) {
    try {
      const m = await fetchJson(`groups/${gid}/manifest.json`);
      container.appendChild(card(gid, m));
    } catch (e) { /* Gruppe ohne Manifest überspringen */ }
  }
  if (!container.children.length) $('empty').hidden = false;
}

function card(gid, m) {
  const slides = (m.baseLayer && m.baseLayer.slides) || [];
  const thumb = slides.length ? `groups/${gid}/${slides[0].file}` : '';
  const el = document.createElement('div');
  el.className = 'card';
  el.innerHTML = `
    <div class="thumb"${thumb ? ` style="background-image:url('${thumb}')"` : ''}></div>
    <div class="body">
      <h2>${esc(m.title || gid)}</h2>
      <div class="sub">${esc(gid)}</div>
      <div class="stats">
        <span>🖼 ${slides.length} Folien</span>
        <span>🕒 ${fmtDate(m.version)}</span>
      </div>
      <div class="sched">🗓 ${esc(scheduleSummary(m.schedule || {}))}</div>
      <div class="players">📺 ${esc((m.players || []).join(', ') || '–')}</div>
      ${warnHtml(m.warnings)}
      <div class="actions">
        <a class="btn edit" href="${esc(m.editUrl || '#')}" target="_blank" rel="noopener">✏️ Bearbeiten</a>
        <button class="btn preview">👁 Vorschau</button>
      </div>
    </div>`;
  el.querySelector('.preview').addEventListener('click', () => openPreview(gid, m));
  return el;
}

function warnHtml(ws) {
  if (!ws || !ws.length) return '';
  return `<div class="warnings">⚠ ${ws.map(esc).join('<br>')}</div>`;
}

function scheduleSummary(s) {
  if (!s || !Object.keys(s).length) return 'kein Zeitplan';
  const parts = [];
  for (const [k, short] of DAYS) {
    const d = s[k];
    if (d && d.active) parts.push(`${short} ${d.from || ''}–${d.until || ''}`);
  }
  const off = s.offMode === 'hdmi_off' ? 'HDMI aus' : 'Black-Screen';
  return `${parts.join(' · ') || 'immer aus'} · ausserhalb: ${off}`;
}

// ---------- Vorschau-Modal ----------
const pv = { slides: [], i: 0, timer: null, base: '' };

function openPreview(gid, m) {
  pv.slides = (m.baseLayer && m.baseLayer.slides) || [];
  pv.base = `groups/${gid}/`;
  $('preview-title').textContent = m.title || gid;
  $('preview').hidden = false;
  showPv(0);
  autoAdvance();
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
function closePv() { $('preview').hidden = true; clearTimeout(pv.timer); }

$('preview-close').addEventListener('click', closePv);
document.querySelector('#preview .modal-bg').addEventListener('click', closePv);
$('preview-prev').addEventListener('click', () => { showPv(pv.i - 1); autoAdvance(); });
$('preview-next').addEventListener('click', () => { showPv(pv.i + 1); autoAdvance(); });

// ---------- Hilfen ----------
async function fetchJson(path) {
  const res = await fetch(`${path}?n=${Date.now()}`, { cache: 'no-store' });
  if (!res.ok) throw new Error('HTTP ' + res.status);
  return res.json();
}
function fmtDate(iso) {
  try {
    return new Date(iso).toLocaleString('de-CH',
      { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });
  } catch (e) { return iso || '–'; }
}
function esc(s) {
  return String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

main();
