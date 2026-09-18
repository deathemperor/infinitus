import { assert, describe, it } from "@effect/vitest";

import {
  parseAddOauthLine,
  privateWindowFlag,
  resolveSwapdBinary,
} from "./infinitusSwapd.logic.ts";

const HOME = "/Users/me";
const BUNDLE = "/Applications/Infinitus.app";
const NESTED = `${BUNDLE}/Contents/Library/LoginItems/Infinitus Menu Bar.app/Contents/MacOS/swapd`;

const resolve = (input: {
  env?: Record<string, string | undefined>;
  desktopBundlePath?: string | null;
  present?: ReadonlyArray<string>;
}) =>
  resolveSwapdBinary({
    env: input.env ?? {},
    homeDirectory: HOME,
    desktopBundlePath: input.desktopBundlePath ?? null,
    exists: (path) => (input.present ?? []).includes(path),
  });

describe("resolveSwapdBinary (#1213)", () => {
  it("takes the first candidate that exists, homebrew before cargo", () => {
    assert.equal(
      resolve({ present: [`${HOME}/.cargo/bin/swapd`, "/opt/homebrew/bin/swapd"] }),
      "/opt/homebrew/bin/swapd",
    );
    assert.equal(resolve({ present: [`${HOME}/.cargo/bin/swapd`] }), `${HOME}/.cargo/bin/swapd`);
  });

  it("falls back to the menu-bar helper nested in the packaged bundle", () => {
    assert.equal(resolve({ desktopBundlePath: BUNDLE, present: [NESTED] }), NESTED);
  });

  it("is null when the engine is nowhere", () => {
    assert.equal(resolve({ desktopBundlePath: BUNDLE }), null);
  });

  it("is answered whole by the override: a set path, or none at all", () => {
    const present = ["/opt/homebrew/bin/swapd", "/tmp/swapd"];
    assert.equal(resolve({ env: { INFINITUS_SWAPD_CLI: "/tmp/swapd" }, present }), "/tmp/swapd");
    // An override pointing nowhere does not fall through to the usual dirs.
    assert.equal(resolve({ env: { INFINITUS_SWAPD_CLI: "/tmp/gone" }, present }), null);
    // Empty means "this machine has no engine", the dev run's simulation.
    assert.equal(resolve({ env: { INFINITUS_SWAPD_CLI: "" }, present }), null);
  });
});

describe("parseAddOauthLine (#1213)", () => {
  it("reads the URL line the loopback listener prints first", () => {
    assert.deepEqual(
      parseAddOauthLine('{"schemaVersion":1,"url":"https://claude.ai/oauth?x=1","port":54545}'),
      { kind: "url", url: "https://claude.ai/oauth?x=1" },
    );
  });

  it("reads the envelope the stored account prints second", () => {
    assert.deepEqual(
      parseAddOauthLine('{"schemaVersion":1,"slot":3,"email":"a@b.c","created":true}'),
      { kind: "added", slot: 3, email: "a@b.c" },
    );
  });

  it("reads the engine's own refusal, falling back to its code", () => {
    assert.deepEqual(
      parseAddOauthLine('{"error":{"code":"token-dead","message":"That account is dead."}}'),
      { kind: "error", message: "That account is dead." },
    );
    assert.deepEqual(parseAddOauthLine('{"error":{"code":"unsupported"}}'), {
      kind: "error",
      message: "unsupported",
    });
  });

  it("ignores anything else on stdout", () => {
    assert.equal(parseAddOauthLine(""), null);
    assert.equal(parseAddOauthLine("   "), null);
    assert.equal(parseAddOauthLine("not json"), null);
    assert.equal(parseAddOauthLine("[1,2]"), null);
    assert.equal(parseAddOauthLine('{"schemaVersion":1}'), null);
    // An envelope missing its slot is not an account that was stored.
    assert.equal(parseAddOauthLine('{"email":"a@b.c"}'), null);
  });
});

describe("privateWindowFlag", () => {
  it("knows the Chromium family's switches and nothing else", () => {
    assert.equal(privateWindowFlag("com.google.Chrome"), "--incognito");
    assert.equal(privateWindowFlag("com.microsoft.edgemac"), "--inprivate");
    assert.equal(privateWindowFlag("com.apple.Safari"), null);
    assert.equal(privateWindowFlag("org.mozilla.firefox"), null);
  });
});
