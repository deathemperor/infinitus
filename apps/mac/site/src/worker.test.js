import { test } from "node:test";
import assert from "node:assert/strict";
import worker, { latestRelease, downloadResponse } from "./worker.js";

const asset = (name, tag) => ({ name, browser_download_url: `https://github.com/deathemperor/infinitus/releases/download/${tag}/${name}` });
const release = (tag, extra = {}) => ({
  tag_name: tag, draft: false, prerelease: true,
  assets: [asset(`Infinitus-${tag.slice(1)}.zip`, tag), asset(`Infinitus-${tag.slice(1)}-arm64.dmg`, tag), asset("infinitus-tray-linux-x86_64", tag)],
  ...extra,
});

test("the newest v-tag wins; nightly and drafts never do", () => {
  const found = latestRelease([release("nightly"), release("v0.5.0-alpha.4", { draft: true }), release("v0.5.0-alpha.3"), release("v0.5.0-alpha.2")]);
  assert.equal(found.tag, "v0.5.0-alpha.3");
  assert.equal(found.version, "0.5.0-alpha.3");
  assert.equal(found.assets["Infinitus-0.5.0-alpha.3.zip"], "https://github.com/deathemperor/infinitus/releases/download/v0.5.0-alpha.3/Infinitus-0.5.0-alpha.3.zip");
  assert.equal(latestRelease([release("nightly")]), null);
  assert.equal(latestRelease([]), null);
});

test("a kind redirects to its asset, a missing asset is a 404", () => {
  const found = latestRelease([release("v0.5.0-alpha.3")]);
  const dmg = downloadResponse(found, "dmg");
  assert.equal(dmg.status, 302);
  assert.equal(dmg.headers.get("location"), "https://github.com/deathemperor/infinitus/releases/download/v0.5.0-alpha.3/Infinitus-0.5.0-alpha.3-arm64.dmg");
  assert.equal(downloadResponse(found, "mac").status, 302);
  assert.equal(downloadResponse(found, "linux-x86_64").status, 302);
  assert.equal(downloadResponse(found, "linux-aarch64").status, 404);
  assert.equal(downloadResponse(found, "windows").status, 404);
});

test("the worker serves /download from the cache, answers /download/version, and leaves other paths to the assets", async () => {
  const store = new Map();
  const env = {
    RENDEZVOUS: {
      get: async (k, type) => { const v = store.get(k); return v == null ? null : type === "json" ? JSON.parse(v) : v; },
      put: async (k, v) => { store.set(k, v); },
    },
    ASSETS: { fetch: async () => new Response("page") },
  };
  const realFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => { calls += 1; return new Response(JSON.stringify([release("nightly"), release("v0.5.0-alpha.3")])); };
  try {
    const version = await worker.fetch(new Request("https://infinitus.run/download/version"), env);
    assert.deepEqual(await version.json(), { version: "0.5.0-alpha.3", tag: "v0.5.0-alpha.3" });
    const mac = await worker.fetch(new Request("https://infinitus.run/download/mac"), env);
    assert.equal(mac.status, 302);
    assert.equal(calls, 1, "the second request came from KV");
    // Past freshness with GitHub refusing: the stale copy still answers.
    const stale = JSON.parse(store.get("download:latest"));
    store.set("download:latest", JSON.stringify({ ...stale, at: stale.at - 10 * 60 * 1000 }));
    globalThis.fetch = async () => new Response("rate limited", { status: 403 });
    assert.equal((await worker.fetch(new Request("https://infinitus.run/download/mac"), env)).status, 302);
    globalThis.fetch = async () => { throw new TypeError("network"); };
    assert.equal((await worker.fetch(new Request("https://infinitus.run/download/dmg"), env)).status, 302);
    // A cold namespace with nothing to fall back on is the one 503.
    store.clear();
    const down = await worker.fetch(new Request("https://infinitus.run/download/mac"), env);
    assert.equal(down.status, 503);
    assert.equal(await (await worker.fetch(new Request("https://infinitus.run/"), env)).text(), "page");
  } finally {
    globalThis.fetch = realFetch;
  }
});
