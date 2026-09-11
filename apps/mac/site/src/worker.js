// infinitus.run — the landing page (static assets) plus one tiny API:
// the pairing rendezvous (#9 remote access, user 2026-09-03 "can the
// domain be reused for other users?" → option 1).
//
// A Mac on the free quick tunnel gets a new *.trycloudflare.com URL every
// start, which used to mean rescanning the QR. Now the Mac PUTs its
// current URL here under a key only it and its paired phones can derive
// (SHA-256 of the pairing token), and a phone whose saved tunnel URL
// stopped answering GETs the fresh one. The URL alone opens nothing —
// every mirror request still needs the bearer token — and the key is
// unguessable, so there is no account, no listing, no auth here.
//
//   PUT /rendezvous/<64 hex>   body {"url":"https://….trycloudflare.com"}
//   GET /rendezvous/<64 hex>   → {"url":…} | 404
//
// Entries expire after a week of silence (the Mac re-PUTs every start).

const KEY = /^\/rendezvous\/([0-9a-f]{64})$/;
const TTL_SECONDS = 7 * 24 * 3600;
const NO_STORE = { "cache-control": "no-store", "content-type": "application/json" };

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const match = KEY.exec(url.pathname);
    if (!match) return env.ASSETS.fetch(request);
    const key = match[1];

    if (request.method === "GET") {
      const stored = await env.RENDEZVOUS.get(key);
      if (!stored) return new Response('{"error":"unknown"}', { status: 404, headers: NO_STORE });
      return new Response(JSON.stringify({ url: stored }), { headers: NO_STORE });
    }

    if (request.method === "PUT") {
      let body;
      try { body = await request.json(); } catch { body = null; }
      const target = typeof body?.url === "string" ? body.url : "";
      let parsed;
      try { parsed = new URL(target); } catch { parsed = null; }
      // Only what the quick tunnel hands out — this is not a URL shortener.
      if (!parsed || parsed.protocol !== "https:" || !parsed.hostname.endsWith(".trycloudflare.com")
          || target.length > 200) {
        return new Response('{"error":"bad url"}', { status: 400, headers: NO_STORE });
      }
      await env.RENDEZVOUS.put(key, parsed.origin, { expirationTtl: TTL_SECONDS });
      return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
    }

    return new Response('{"error":"method"}', { status: 405, headers: { ...NO_STORE, allow: "GET, PUT" } });
  },
};
