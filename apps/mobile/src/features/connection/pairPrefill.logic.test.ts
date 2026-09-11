import { describe, expect, it } from "vite-plus/test";

import { routePairingPrefill } from "./pairPrefill.logic";

const LINK = " https://example-words.trycloudflare.com/pair#token=fixture-token&for=phone ";

describe("routePairingPrefill", () => {
  it("fills the sheet for the Infinitus variant in a release build, but never auto-connects", () => {
    expect(
      routePairingPrefill({
        params: { pairingUrl: LINK, autoConnect: "1" },
        dev: false,
        appVariant: "infinitus",
      }),
    ).toEqual({ pairingUrl: LINK.trim(), autoConnect: false });
  });

  it("keeps upstream's refusal for the other variants outside development", () => {
    for (const appVariant of ["production", "preview", undefined]) {
      expect(
        routePairingPrefill({
          params: { pairingUrl: LINK, autoConnect: "true" },
          dev: false,
          appVariant,
        }),
      ).toEqual({ pairingUrl: "", autoConnect: false });
    }
  });

  it("keeps upstream's development behaviour: prefill for any variant, auto-connect on the flag", () => {
    expect(
      routePairingPrefill({
        params: { pairingUrl: LINK, autoConnect: "true" },
        dev: true,
        appVariant: "production",
      }),
    ).toEqual({ pairingUrl: LINK.trim(), autoConnect: true });
    expect(
      routePairingPrefill({ params: { pairingUrl: LINK }, dev: true, appVariant: "infinitus" }),
    ).toEqual({ pairingUrl: LINK.trim(), autoConnect: false });
    expect(
      routePairingPrefill({ params: { autoConnect: "1" }, dev: true, appVariant: "infinitus" }),
    ).toEqual({ pairingUrl: "", autoConnect: false });
  });

  it("is quiet with no params at all", () => {
    expect(routePairingPrefill({ params: undefined, dev: false, appVariant: "infinitus" })).toEqual(
      { pairingUrl: "", autoConnect: false },
    );
  });
});
