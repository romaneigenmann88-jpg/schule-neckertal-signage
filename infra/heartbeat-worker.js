// Schule Neckertal – Signage Worker (Cloudflare)
// ------------------------------------------------------------
// Winziger, gratis Sammelpunkt mit zwei Aufgaben:
//
//  1) Heartbeat (Bildschirm-Status)
//     POST /            { playerId, groupId, version, hostname }  -> speichert mit Zeitstempel
//     GET  /                                                      -> { players: [...] }
//
//  2) Einstellungen (Zeiten / Laufband / Uhr-Anzeige, je Gruppe)
//     POST /settings    { groupId, settings }                    -> speichert die Einstellungen
//     GET  /settings/<groupId>                                   -> die gespeicherten Einstellungen ({} wenn keine)
//
// Speicher: KV-Namespace-Bindung mit dem Variablennamen  HEARTBEATS
//   p:<playerId>  Heartbeats (7 Tage TTL)
//   s:<groupId>   Einstellungen (dauerhaft, kein Ablauf)
//
// Keine Authentifizierung (interne, unkritische Daten); CORS offen.
// Damit braucht es im Alltag KEINE Tokens – Admin speichert per POST,
// der Pi liest per GET.

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') return new Response(null, { headers: CORS });

    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, '');   // ohne Schraegstrich am Ende

    // ----------------------------------------------------------
    //  Video-Schaukasten (R2-Bucket signage-videos)
    //  GET /videos        -> { videos: [{name,size,uploaded,url}] } (Playlist)
    //  GET /video/<name>  -> streamt die Datei (mit Range/Seek-Unterstuetzung)
    //  Getrennt vom bestehenden System: eigener Bucket, eigene Routen.
    // ----------------------------------------------------------
    // Passwortgeschuetzte Upload-Seite (Video hochladen/loeschen ohne Cloudflare-Login)
    if (path === '/uploader' || path === '/upload') {
      return new Response(uploaderPage(), { headers: { ...CORS, 'Content-Type': 'text/html; charset=utf-8' } });
    }

    if (path === '/videos') {
      if (!env.VIDEOS) return json({ videos: [] });
      const listed = await env.VIDEOS.list({ limit: 1000 });
      const vids = (listed.objects || [])
        .filter((o) => /\.(mp4|webm|mov|m4v)$/i.test(o.key))
        .sort((a, b) => (a.key > b.key ? 1 : -1))
        .map((o) => ({
          name: o.key,
          size: o.size,
          uploaded: o.uploaded,
          url: url.origin + '/video/' + encodeURIComponent(o.key),
        }));
      return json({ videos: vids });
    }

    if (path.startsWith('/video/')) {
      if (!env.VIDEOS) return resp('kein Bucket', 404);
      const key = decodeURIComponent(path.slice('/video/'.length));

      // Hochladen (PUT) / Loeschen (DELETE): passwortgeschuetzt (Worker-Secret
      // UPLOAD_PW; per 'wrangler secret put UPLOAD_PW' setzen). GET bleibt offen
      // (der Pi muss die Videos token-frei laden koennen).
      if (request.method === 'PUT' || request.method === 'DELETE') {
        if (!env.UPLOAD_PW || request.headers.get('x-upload-password') !== env.UPLOAD_PW) {
          return resp('Passwort falsch oder nicht gesetzt', 401);
        }
        const safe = key.replace(/[\\/]/g, '').replace(/^\.+/, '');
        if (!safe) return resp('ungueltiger Name', 400);
        if (request.method === 'DELETE') {
          await env.VIDEOS.delete(safe);
          return json({ ok: true, deleted: safe });
        }
        if (!/\.(mp4|webm|mov|m4v)$/i.test(safe)) return resp('nur Video-Dateien (.mp4 …)', 400);
        const ct = request.headers.get('content-type') || 'video/mp4';
        await env.VIDEOS.put(safe, request.body, { httpMetadata: { contentType: ct } });
        return json({ ok: true, name: safe });
      }

      const range = request.headers.get('range');
      let mm;
      if (range && (mm = /bytes=(\d*)-(\d*)/.exec(range))) {
        const head = await env.VIDEOS.head(key);
        if (!head) return resp('nicht gefunden', 404);
        const total = head.size;
        let start = mm[1] ? parseInt(mm[1], 10) : 0;
        let end = mm[2] ? parseInt(mm[2], 10) : total - 1;
        if (isNaN(start) || start < 0) start = 0;
        if (isNaN(end) || end >= total) end = total - 1;
        if (start > end) {
          return new Response('range', { status: 416, headers: { ...CORS, 'Content-Range': `bytes */${total}` } });
        }
        const obj = await env.VIDEOS.get(key, { range: { offset: start, length: end - start + 1 } });
        const h = new Headers(CORS);
        obj.writeHttpMetadata(h);
        h.set('Content-Type', (obj.httpMetadata && obj.httpMetadata.contentType) || 'video/mp4');
        h.set('Accept-Ranges', 'bytes');
        h.set('Content-Range', `bytes ${start}-${end}/${total}`);
        h.set('Content-Length', String(end - start + 1));
        h.set('Cache-Control', 'public, max-age=3600');
        return new Response(obj.body, { status: 206, headers: h });
      }
      const obj = await env.VIDEOS.get(key);
      if (!obj) return resp('nicht gefunden', 404);
      const h = new Headers(CORS);
      obj.writeHttpMetadata(h);
      h.set('Content-Type', (obj.httpMetadata && obj.httpMetadata.contentType) || 'video/mp4');
      h.set('Accept-Ranges', 'bytes');
      h.set('Content-Length', String(obj.size));
      h.set('Cache-Control', 'public, max-age=3600');
      return new Response(obj.body, { status: 200, headers: h });
    }

    // ----------------------------------------------------------
    //  Fernwartungs-Befehle je Bildschirm (Postfach)
    //  POST /command {playerId, action}  -> legt einen Befehl ab
    //  GET  /command/<playerId>          -> {action, ts} (der Pi pollt das)
    //  Erlaubte Aktionen: kiosk-off, kiosk-on, reboot
    // ----------------------------------------------------------
    if (path === '/command' || path.startsWith('/command/')) {
      const ALLOWED = ['kiosk-off', 'kiosk-on', 'reboot'];
      if (request.method === 'POST') {
        let body;
        try { body = await request.json(); } catch { return resp('bad json', 400); }
        const pid = String(body.playerId || '').slice(0, 100);
        const action = String(body.action || '');
        if (!pid) return resp('playerId fehlt', 400);
        if (!ALLOWED.includes(action)) return resp('unbekannte Aktion', 400);
        const rec = { action, ts: Date.now() };
        // 1 Tag aufheben (falls der Pi offline ist, holt er den Befehl beim Start)
        await env.HEARTBEATS.put('c:' + pid, JSON.stringify(rec), { expirationTtl: 86400 });
        return json({ ok: true, playerId: pid, action, ts: rec.ts });
      }
      const pid = path.startsWith('/command/') ? decodeURIComponent(path.slice('/command/'.length)) : '';
      if (!pid) return json({ action: null, ts: 0 });
      const v = await env.HEARTBEATS.get('c:' + pid);
      if (!v) return json({ action: null, ts: 0 });
      return new Response(v, { headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    // ----------------------------------------------------------
    //  Bildschirm aus der Liste entfernen (alten/neu geflashten Pi loeschen)
    //  POST /delete-player {playerId}  -> loescht den Heartbeat-Eintrag.
    //  Hinweis: Sendet der Pi noch Heartbeats, taucht er beim naechsten
    //  (spaetestens nach ~10 Min) wieder auf -> dann ist er eben noch aktiv.
    // ----------------------------------------------------------
    if (path === '/delete-player') {
      if (request.method !== 'POST') return resp('POST noetig', 405);
      let body;
      try { body = await request.json(); } catch { return resp('bad json', 400); }
      const pid = String(body.playerId || '').slice(0, 100);
      if (!pid) return resp('playerId fehlt', 400);
      await env.HEARTBEATS.delete('p:' + pid);
      await env.HEARTBEATS.delete('c:' + pid);   // evtl. offenen Befehl mitloeschen
      return json({ ok: true, playerId: pid, deleted: true });
    }

    // ----------------------------------------------------------
    //  Einstellungen je Gruppe
    // ----------------------------------------------------------
    if (path === '/settings' || path.startsWith('/settings/')) {
      // groupId aus dem Pfad (/settings/<gid>) oder Query (?group=<gid>)
      let gid = path.startsWith('/settings/') ? decodeURIComponent(path.slice('/settings/'.length)) : '';

      if (request.method === 'POST') {
        let body;
        try { body = await request.json(); } catch { return resp('bad json', 400); }
        gid = String(body.groupId || gid || '').slice(0, 100);
        if (!gid) return resp('groupId fehlt', 400);
        const settings = body.settings && typeof body.settings === 'object' ? body.settings : {};
        const rec = { groupId: gid, settings, updated: new Date().toISOString() };
        await env.HEARTBEATS.put('s:' + gid, JSON.stringify(rec));   // kein Ablauf
        return json({ ok: true, groupId: gid, updated: rec.updated });
      }

      // GET -> gespeicherte Einstellungen (oder leeres Objekt)
      gid = String(gid || url.searchParams.get('group') || '').slice(0, 100);
      if (!gid) return json({});
      const v = await env.HEARTBEATS.get('s:' + gid);
      if (!v) return json({ groupId: gid, settings: {}, updated: null });
      return new Response(v, { headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    // ----------------------------------------------------------
    //  Ereignis-Protokoll (was ist wann passiert)
    //  GET /events  -> { events: [ {ts, playerId, type, text}, ... ] }
    //  Geschrieben wird NUR bei echten Aenderungen (siehe below) - das schont
    //  das KV-Schreibbudget (Gratis-Tarif: 1000 Schreibvorgaenge/Tag).
    // ----------------------------------------------------------
    if (path === '/events') {
      const v = await env.HEARTBEATS.get('log:events');
      return new Response(v || '{"events":[]}', {
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    // ----------------------------------------------------------
    //  Heartbeat (Status der Bildschirme)
    // ----------------------------------------------------------
    if (request.method === 'POST') {
      let body;
      try { body = await request.json(); } catch { return resp('bad json', 400); }
      const id = String(body.playerId || '').slice(0, 100);
      if (!id) return resp('playerId fehlt', 400);
      const rec = {
        playerId: id,
        groupId: String(body.groupId || '').slice(0, 100),
        version: String(body.version || '').slice(0, 60),
        hostname: String(body.hostname || '').slice(0, 100),
        ip: String(body.ip || '').slice(0, 60),        // aktive lokale IP
        conn: String(body.conn || '').slice(0, 20),    // LAN / WLAN
        iface: String(body.iface || '').slice(0, 20),  // eth0 / wlan0
        ssid: String(body.ssid || '').slice(0, 40),    // WLAN-Name (nur bei WLAN)
        displayFreshSec: Number.isFinite(+body.displayFreshSec) ? Math.trunc(+body.displayFreshSec) : null, // Sek. seit letzter Browser-Anfrage (Bild lebt?)
        syncAgeSec: Number.isFinite(+body.syncAgeSec) ? Math.trunc(+body.syncAgeSec) : null,               // Sek. seit letztem erfolgreichen render-sync
        syncStuck: body.syncStuck ? 1 : 0,                                                                  // 1 = Sync-Sperre haengt fest
        slideCount: Number.isFinite(+body.slideCount) ? Math.trunc(+body.slideCount) : null,                // Folien bzw. (Video-Modus) Anzahl Videos
        mode: String(body.mode || 'slides').slice(0, 10),                                                   // slides | video
        contentHash: String(body.contentHash || '').slice(0, 80),                                           // Fingerabdruck der sichtbaren Folien
        lastSeen: new Date().toISOString(),
      };
      // Ereignisse erkennen: Vergleich mit dem vorherigen Stand. Nur bei einer
      // echten Aenderung wird protokolliert (spart KV-Schreibvorgaenge).
      const prevRaw = await env.HEARTBEATS.get('p:' + id);
      const prev = prevRaw ? JSON.parse(prevRaw) : null;
      const events = [];
      // Wann wurde der INHALT zuletzt wirklich veraendert? Der contentHash
      // beschreibt die sichtbaren Folien. Aendert sich nur die Version (Pi hat
      // neu gerendert, z. B. nach einer Einstellungsaenderung), ist das KEINE
      // Inhaltsaenderung - und darf auch nicht als solche protokolliert werden.
      rec.contentChangedAt = prev ? (prev.contentChangedAt || null) : null;
      if (!prev) {
        events.push({ type: 'neu', text: 'Bildschirm zum ersten Mal gemeldet' });
      } else {
        const hadHash = !!prev.contentHash;
        if (hadHash && rec.contentHash && prev.contentHash !== rec.contentHash) {
          rec.contentChangedAt = rec.lastSeen;
          events.push({ type: 'inhalt', text: 'Folien geändert – neuer Inhalt wird angezeigt' });
        }
        // Ein blosses Neu-Rendern bei gleichem Bildinhalt wird NICHT protokolliert
        // (das erzeugte frueher eine Schreibflut ins KV-Log).
        const gap = (Date.parse(rec.lastSeen) - Date.parse(prev.lastSeen)) / 60000;
        if (Number.isFinite(gap) && gap > 45) {
          events.push({ type: 'zurueck', text: `Wieder online nach ${Math.round(gap)} Min Pause` });
        }
        if (rec.syncStuck && !prev.syncStuck) {
          events.push({ type: 'problem', text: 'Inhalts-Sync haengt fest' });
        }
        if (!rec.syncStuck && prev.syncStuck) {
          events.push({ type: 'ok', text: 'Inhalts-Sync laeuft wieder' });
        }
      }
      // 7 Tage nach dem letzten Lebenszeichen automatisch vergessen
      await env.HEARTBEATS.put('p:' + id, JSON.stringify(rec), { expirationTtl: 604800 });
      if (events.length) await appendEvents(env, id, rec.groupId, events);
      return resp('ok', 200);
    }

    // GET -> Status aller bekannten Player
    const list = await env.HEARTBEATS.list({ prefix: 'p:' });
    const players = [];
    for (const k of list.keys) {
      const v = await env.HEARTBEATS.get(k.name);
      if (v) players.push(JSON.parse(v));
    }
    return json({ players });
  },
};

// Ereignisse an das Protokoll anhaengen (neueste zuerst, max. 200 Eintraege).
// Ein KV-Schreibvorgang pro Aufruf - passiert nur, wenn wirklich etwas geschah.
async function appendEvents(env, playerId, groupId, events) {
  let log = { events: [] };
  try {
    const raw = await env.HEARTBEATS.get('log:events');
    if (raw) log = JSON.parse(raw);
    if (!Array.isArray(log.events)) log.events = [];
  } catch { log = { events: [] }; }
  const ts = new Date().toISOString();
  for (const e of events) {
    log.events.unshift({ ts, playerId, groupId: groupId || '', type: e.type, text: e.text });
  }
  log.events = log.events.slice(0, 200);
  await env.HEARTBEATS.put('log:events', JSON.stringify(log));
}

// Passwortgeschuetzte Upload-Seite (vom Worker ausgeliefert, gleiche Domain).
// Inline-JS bewusst OHNE Template-Literals/${...}, damit es nicht mit diesem
// aeusseren Template-String kollidiert.
function uploaderPage() {
  return `<!doctype html><html lang="de"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Schaukasten – Videos</title>
<style>
  :root{color-scheme:light dark}
  body{font:16px/1.5 system-ui,sans-serif;max-width:680px;margin:0 auto;padding:1.2rem;background:#0b1020;color:#e5e7eb}
  h1{font-size:1.3rem} h2{font-size:1.05rem;margin-top:1.6rem}
  input[type=password]{padding:.5rem;border-radius:8px;border:1px solid #475569;background:#111827;color:#e5e7eb;width:100%;max-width:280px}
  #drop{margin:1rem 0;padding:2rem 1rem;border:2px dashed #64748b;border-radius:14px;text-align:center;cursor:pointer;background:#111827}
  #drop.over{border-color:#22d3ee;background:#0e2130}
  #status{margin:.8rem 0;min-height:1.4em;color:#93c5fd}
  ul{list-style:none;padding:0} li{padding:.5rem .2rem;border-bottom:1px solid #334155;display:flex;justify-content:space-between;gap:.5rem;align-items:center}
  button{padding:.4rem .7rem;border-radius:8px;border:1px solid #64748b;background:#1f2937;color:#e5e7eb;cursor:pointer}
  .hint{color:#94a3b8;font-size:.9rem}
</style></head><body>
<h1>🎬 Schaukasten – Videos</h1>
<p class="hint">Passwort eingeben, dann Videos hochladen. Sie erscheinen in wenigen Minuten am Bildschirm (grosse Videos werden automatisch auf 720p gebracht). Reihenfolge nach Dateiname (z.&nbsp;B. 01-…, 02-…).</p>
<label>Passwort<br><input type="password" id="pw" placeholder="Upload-Passwort"></label>
<div id="drop">Video hierher ziehen &nbsp;·&nbsp; oder klicken zum Auswählen</div>
<input type="file" id="file" accept="video/*" multiple hidden>
<div id="status"></div>
<h2>Aktuelle Videos</h2>
<ul id="list"></ul>
<script>
'use strict';
var pwEl=document.getElementById('pw');
pwEl.value=localStorage.getItem('schaukasten_pw')||'';
pwEl.addEventListener('change',function(){localStorage.setItem('schaukasten_pw',pwEl.value);});
function st(t){document.getElementById('status').textContent=t;}
function mb(b){return (b/1048576).toFixed(1)+' MB';}
function loadList(){
  fetch('/videos?t='+Date.now()).then(function(r){return r.json();}).then(function(d){
    var ul=document.getElementById('list');ul.innerHTML='';
    var vs=d.videos||[];
    if(!vs.length){ul.innerHTML='<li>Noch keine Videos.</li>';return;}
    vs.forEach(function(v){
      var li=document.createElement('li');
      var s=document.createElement('span');s.textContent=v.name+'  ('+mb(v.size||0)+')';
      var b=document.createElement('button');b.textContent='löschen';
      b.onclick=function(){delVid(v.name);};
      li.appendChild(s);li.appendChild(b);ul.appendChild(li);
    });
  }).catch(function(){st('Liste nicht erreichbar.');});
}
function delVid(name){
  if(!confirm('Löschen: '+name+' ?'))return;
  fetch('/video/'+encodeURIComponent(name),{method:'DELETE',headers:{'x-upload-password':pwEl.value}})
   .then(function(r){if(!r.ok)throw 0;st('Gelöscht: '+name);loadList();})
   .catch(function(){st('Löschen fehlgeschlagen – Passwort?');});
}
function upload(file){
  var x=new XMLHttpRequest();
  x.open('PUT','/video/'+encodeURIComponent(file.name));
  x.setRequestHeader('x-upload-password',pwEl.value);
  x.setRequestHeader('content-type',file.type||'video/mp4');
  x.upload.onprogress=function(e){if(e.lengthComputable)st('Lade '+file.name+' … '+Math.round(e.loaded/e.total*100)+'%');};
  x.onload=function(){if(x.status===200){st('✓ Hochgeladen: '+file.name+' – erscheint in wenigen Minuten.');loadList();}else if(x.status===401){st('Passwort falsch oder nicht gesetzt.');}else{st('Upload-Fehler ('+x.status+').');}};
  x.onerror=function(){st('Upload-Fehler (Netzwerk).');};
  x.send(file);
}
function handle(files){for(var i=0;i<files.length;i++)upload(files[i]);}
var f=document.getElementById('file'),d=document.getElementById('drop');
d.onclick=function(){f.click();};
f.onchange=function(){handle(f.files);};
d.ondragover=function(e){e.preventDefault();d.classList.add('over');};
d.ondragleave=function(){d.classList.remove('over');};
d.ondrop=function(e){e.preventDefault();d.classList.remove('over');handle(e.dataTransfer.files);};
loadList();
</script></body></html>`;
}

function resp(text, status) {
  return new Response(text, { status, headers: CORS });
}
function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status, headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}
