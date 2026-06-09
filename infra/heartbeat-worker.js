// Schule Neckertal – Signage Heartbeat (Cloudflare Worker)
// ------------------------------------------------------------
// Winziger, gratis Sammelpunkt für den Bildschirm-Status.
//   POST { playerId, groupId, version, hostname }  -> speichert mit Zeitstempel
//   GET                                            -> { players: [...] }
// Benötigt eine KV-Namespace-Bindung mit dem Variablennamen  HEARTBEATS
// Keine Authentifizierung nötig (unkritische Statusdaten); CORS offen.

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') return new Response(null, { headers: CORS });

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
    return new Response(JSON.stringify({ players }), {
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  },
};

function resp(text, status) {
  return new Response(text, { status, headers: CORS });
}
