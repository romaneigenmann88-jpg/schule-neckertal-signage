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
        slideCount: Number.isFinite(+body.slideCount) ? Math.trunc(+body.slideCount) : null,                // Folien, die dieser Bildschirm zeigt
        lastSeen: new Date().toISOString(),
      };
      // Ereignisse erkennen: Vergleich mit dem vorherigen Stand. Nur bei einer
      // echten Aenderung wird protokolliert (spart KV-Schreibvorgaenge).
      const prevRaw = await env.HEARTBEATS.get('p:' + id);
      const prev = prevRaw ? JSON.parse(prevRaw) : null;
      const events = [];
      if (!prev) {
        events.push({ type: 'neu', text: 'Bildschirm zum ersten Mal gemeldet' });
      } else {
        if (prev.version && rec.version && prev.version !== rec.version) {
          events.push({ type: 'inhalt', text: `Neuer Inhalt aktiv (${rec.version})` });
        }
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

function resp(text, status) {
  return new Response(text, { status, headers: CORS });
}
function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status, headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}
