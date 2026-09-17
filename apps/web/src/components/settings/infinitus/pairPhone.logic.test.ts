import { describe, expect, it } from "vite-plus/test";

import {
  formatCountdown,
  isPhonePairingLink,
  lanPairingOrigin,
  pairPhoneCardModel,
  phonePairingUrl,
  type PhonePairingLink,
} from "./pairPhone.logic";

const NOW = Date.UTC(2026, 8, 10, 12, 0, 0);
const LAN_URL = "http://192.168.1.20:3773";
/** Any public origin — the URL builders take one whatever route it came by. */
const REMOTE_URL = "https://code.example.com";
// Not a credential the server ever minted; the URL tests only need a marker.
const link: PhonePairingLink = {
  id: "link-1",
  credential: "fixture-token",
  expiresAtMs: NOW + 299_400,
};

describe("pairPhoneCardModel", () => {
  it("encodes the LAN origin and says the link only reaches that network", () => {
    const model = pairPhoneCardModel({ lanOrigin: LAN_URL, link, nowMs: NOW });
    expect(model.origin).toBe(LAN_URL);
    expect(model.lanNotice).toMatch(/only works for phones on your Wi‑Fi/);
    expect(model.lanNotice).toMatch(/Infinitus Connect/);
    expect(model.link).toEqual({
      kind: "active",
      url: phonePairingUrl(LAN_URL, "fixture-token"),
      host: "192.168.1.20:3773",
      secondsLeft: 300,
    });
  });

  it("offers no link at all, and points at Network access and Connect, when nothing on the network can be dialled", () => {
    const model = pairPhoneCardModel({ lanOrigin: null, link, nowMs: NOW });
    expect(model.origin).toBeNull();
    expect(model.lanNotice).toMatch(/Network access is on under Settings › Connections/);
    expect(model.lanNotice).toMatch(/Infinitus Connect/);
    expect(model.link).toEqual({ kind: "none" });
  });

  it("counts the link down and expires it", () => {
    const at = (nowMs: number) => pairPhoneCardModel({ lanOrigin: LAN_URL, link, nowMs }).link;
    expect(at(NOW + 298_000)).toMatchObject({ kind: "active", secondsLeft: 2 });
    expect(at(NOW + 299_400)).toEqual({ kind: "expired" });
    expect(at(NOW + 400_000)).toEqual({ kind: "expired" });
  });
});

describe("phonePairingUrl", () => {
  it("mints the site's universal link with token, marker and the Mac's origin in the fragment, never the query (#724)", () => {
    const url = new URL(phonePairingUrl(REMOTE_URL, "fixture-token"));
    expect(url.origin + url.pathname).toBe("https://infinitus.run/pair");
    expect(url.search).toBe("");
    const fragment = new URLSearchParams(url.hash.slice(1));
    expect(fragment.get("token")).toBe("fixture-token");
    expect(fragment.get("for")).toBe("phone");
    expect(fragment.get("to")).toBe(new URL(REMOTE_URL).origin);
  });

  it("hands a LAN origin the same way, port included", () => {
    const fragment = new URLSearchParams(
      new URL(phonePairingUrl("http://192.168.2.5:3773/settings", "t")).hash.slice(1),
    );
    expect(fragment.get("to")).toBe("http://192.168.2.5:3773");
  });
});

describe("isPhonePairingLink", () => {
  it("recognises the card's link and nothing else", () => {
    expect(isPhonePairingLink(new URL(phonePairingUrl(REMOTE_URL, "fixture-token")))).toBe(true);
    expect(isPhonePairingLink(new URL(`${REMOTE_URL}/pair#token=fixture-token&for=phone`))).toBe(
      true,
    );
    expect(isPhonePairingLink(new URL(`${REMOTE_URL}/pair#token=fixture-token`))).toBe(false);
    expect(isPhonePairingLink(new URL(`${REMOTE_URL}/pair?for=phone#token=fixture-token`))).toBe(
      false,
    );
    expect(isPhonePairingLink(new URL(`${REMOTE_URL}/pair#for=laptop&token=fixture-token`))).toBe(
      false,
    );
    expect(isPhonePairingLink(new URL(`${REMOTE_URL}/pair`))).toBe(false);
  });
});

describe("lanPairingOrigin", () => {
  const exposure = (mode: "local-only" | "network-accessible", endpointUrl: string | null) => ({
    mode,
    endpointUrl,
    advertisedHost: endpointUrl === null ? null : new URL(endpointUrl).hostname,
    tailscaleServeEnabled: false,
    tailscaleServePort: 3773,
  });

  it("takes the desktop server's advertised address while Network access is on", () => {
    expect(
      lanPairingOrigin({
        serverExposure: exposure("network-accessible", "http://192.168.1.20:3773"),
        serverLanOrigins: ["http://10.0.0.7:3773"],
        pageOrigin: null,
      }),
    ).toBe("http://192.168.1.20:3773");
  });

  it("takes the first address the server reports when there is no desktop bridge (#651)", () => {
    expect(
      lanPairingOrigin({
        serverExposure: null,
        serverLanOrigins: ["http://192.168.1.20:3773", "http://10.0.0.7:3773"],
        pageOrigin: "http://192.168.1.20:7422",
      }),
    ).toBe("http://192.168.1.20:3773");
  });

  it("falls back to the page's own origin when the server is local-only or unknown", () => {
    expect(
      lanPairingOrigin({
        serverExposure: exposure("local-only", null),
        serverLanOrigins: [],
        pageOrigin: "http://192.168.1.20:7422",
      }),
    ).toBe("http://192.168.1.20:7422");
    expect(
      lanPairingOrigin({ serverExposure: null, serverLanOrigins: [], pageOrigin: null }),
    ).toBeNull();
  });
});

describe("formatCountdown", () => {
  it("formats minutes and zero-padded seconds", () => {
    expect(formatCountdown(300)).toBe("5:00");
    expect(formatCountdown(61)).toBe("1:01");
    expect(formatCountdown(9)).toBe("0:09");
    expect(formatCountdown(-3)).toBe("0:00");
  });
});
