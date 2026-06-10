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
        lastSeen: new Date().toISOString(),
      };
      // 7 Tage nach dem letzten Lebenszeichen automatisch vergessen
      await env.HEARTBEATS.put('p:' + id, JSON.stringify(rec), { expirationTtl: 604800 });
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

function resp(text, status) {
  return new Response(text, { status, headers: CORS });
}
function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status, headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}
