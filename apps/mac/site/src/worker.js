// infinitus.run — the landing page (static assets) plus one tiny API,
// the download links (#823 layer 3): the page never names a version.
//
//   GET /download/<kind>      → 302 to that asset of the newest release
//   GET /download/version     → {"version":"0.5.0-alpha.3","tag":"v0.5.0-alpha.3"}
//
// "Newest release" is the first non-draft `v…` tag in the GitHub releases
// list — never `releases/latest`, which stays pinned to the last one-app
// build until the first plain 0.5.0 (#924), and never the rolling
// `nightly` tag. The answer is kept in KV: fresh for five minutes, and
// served stale when GitHub does not answer (its unauthenticated limit is
// per source IP, which Workers share), so only a cold namespace refuses.

const NO_STORE = { "cache-control": "no-store", "content-type": "application/json" };

const RELEASES_API = "https://api.github.com/repos/deathemperor/infinitus/releases?per_page=10";
const RELEASE_CACHE_KEY = "download:latest";
const RELEASE_FRESH_MS = 5 * 60 * 1000;
const DOWNLOAD = /^\/download\/([a-z0-9_-]+)$/;
// Route → the asset's file name for version v (the release workflow's names).
const DOWNLOADS = {
  // `mac` was the standalone menu bar zip until #1238; the menu bar app
  // ships only inside the desktop DMG now, so both routes name it.
  mac: (v) => `Infinitus-${v}-arm64.dmg`,
  dmg: (v) => `Infinitus-${v}-arm64.dmg`,
  "linux-x86_64": () => "infinitus-tray-linux-x86_64",
  "linux-aarch64": () => "infinitus-tray-linux-aarch64",
  omarchy: () => "infinitus-omarchy.tar.gz",
};

/// The newest versioned release of the list GitHub answers (newest first):
/// not a draft, tagged `v<version>` — so `nightly` and anything else never
/// count. null when there is none.
export function latestRelease(releases) {
  for (const release of releases) {
    if (release?.draft) continue;
    const tag = typeof release?.tag_name === "string" ? release.tag_name : "";
    if (!/^v\d/.test(tag)) continue;
    const assets = Array.isArray(release.assets) ? release.assets : [];
    return {
      tag,
      version: tag.slice(1),
      assets: Object.fromEntries(
        assets.filter((a) => typeof a?.name === "string" && typeof a?.browser_download_url === "string")
          .map((a) => [a.name, a.browser_download_url]),
      ),
    };
  }
  return null;
}

/// What /download/<kind> answers for a resolved release: a redirect to the
/// asset, or a 404 when the release lacks it (a workflow that changed its
/// names, a Linux build that failed) — never a guessed URL.
export function downloadResponse(release, kind) {
  const name = DOWNLOADS[kind]?.(release.version);
  const target = name && release.assets[name];
  if (!target) return new Response("no such download in " + release.tag, { status: 404, headers: { "cache-control": "no-store" } });
  return Response.redirect(target, 302);
}

async function fetchLatest() {
  try {
    const reply = await fetch(RELEASES_API, {
      headers: { accept: "application/vnd.github+json", "user-agent": "infinitus.run download links" },
    });
    return reply.ok ? latestRelease(await reply.json()) : null;
  } catch {
    return null;
  }
}

async function resolveLatest(env, now = Date.now()) {
  const cached = await env.RENDEZVOUS.get(RELEASE_CACHE_KEY, "json");
  if (cached && now - cached.at < RELEASE_FRESH_MS) return cached.release;
  const release = await fetchLatest();
  if (!release) return cached?.release ?? null;
  await env.RENDEZVOUS.put(RELEASE_CACHE_KEY, JSON.stringify({ at: now, release }));
  return release;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const download = DOWNLOAD.exec(url.pathname);
    if (download) {
      if (request.method !== "GET" && request.method !== "HEAD") {
        return new Response('{"error":"method"}', { status: 405, headers: { ...NO_STORE, allow: "GET, HEAD" } });
      }
      const release = await resolveLatest(env);
      if (!release) return new Response("release list unavailable, try https://github.com/deathemperor/infinitus/releases", { status: 503, headers: { "cache-control": "no-store", "retry-after": "60" } });
      if (download[1] === "version") {
        return new Response(JSON.stringify({ version: release.version, tag: release.tag }), { headers: NO_STORE });
      }
      return downloadResponse(release, download[1]);
    }
    return env.ASSETS.fetch(request);
  },
};
