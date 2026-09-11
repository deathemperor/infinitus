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
const TUNNEL_URL = "https://example-words.trycloudflare.com";
// Not a credential the server ever minted; the URL tests only need a marker.
const link: PhonePairingLink = {
  id: "link-1",
  credential: "fixture-token",
  expiresAtMs: NOW + 299_400,
};

const tunnel = (state: string, url?: string) => ({
  enabled: state !== "off",
  port: 3773,
  state,
  ...(url === undefined ? {} : { url }),
});

describe("pairPhoneCardModel", () => {
  it("encodes the tunnel origin while the tunnel is up", () => {
    const model = pairPhoneCardModel({
      forkTunnel: tunnel("up", TUNNEL_URL),
      lanOrigin: null,
      reach: "tunnel",
      link,
      nowMs: NOW,
    });
    expect(model.tunnel).toBe("up");
    expect(model.tunnelNotice).toBeNull();
    expect(model.lanNotice).toBeNull();
    expect(model.reachChoice).toBe(false);
    expect(model.origin).toEqual({ kind: "tunnel", url: TUNNEL_URL });
    expect(model.link).toEqual({
      kind: "active",
      url: phonePairingUrl(TUNNEL_URL, "fixture-token"),
      host: "example-words.trycloudflare.com",
      secondsLeft: 300,
    });
  });

  it("offers the choice while the tunnel is up and the network reaches the server", () => {
    const input = {
      forkTunnel: tunnel("up", TUNNEL_URL),
      lanOrigin: "http://192.168.1.20:3773",
      link,
      nowMs: NOW,
    };
    const internet = pairPhoneCardModel({ ...input, reach: "tunnel" });
    expect(internet.reachChoice).toBe(true);
    expect(internet.origin).toEqual({ kind: "tunnel", url: TUNNEL_URL });
    expect(internet.lanNotice).toBeNull();

    const sameNetwork = pairPhoneCardModel({ ...input, reach: "lan" });
    expect(sameNetwork.origin).toEqual({ kind: "lan", url: "http://192.168.1.20:3773" });
    expect(sameNetwork.lanNotice).toMatch(/only works for phones on your Wi‑Fi/);
    expect(sameNetwork.link).toMatchObject({
      kind: "active",
      url: phonePairingUrl("http://192.168.1.20:3773", "fixture-token"),
      host: "192.168.1.20:3773",
    });
  });

  it("falls back to the LAN origin while the tunnel is off, and says so", () => {
    const model = pairPhoneCardModel({
      forkTunnel: tunnel("off"),
      lanOrigin: "http://192.168.1.20:3773",
      reach: "tunnel",
      link,
      nowMs: NOW,
    });
    expect(model.tunnel).toBe("off");
    expect(model.tunnelNotice).toMatch(/Turn on the Cloudflare quick tunnel/);
    expect(model.reachChoice).toBe(false);
    expect(model.origin).toEqual({ kind: "lan", url: "http://192.168.1.20:3773" });
    expect(model.lanNotice).toMatch(/only works for phones on your Wi‑Fi/);
    expect(model.link.kind).toBe("active");
  });

  it("offers no link at all, and points at Network access, when nothing on the network can be dialled", () => {
    const model = pairPhoneCardModel({
      forkTunnel: tunnel("off"),
      lanOrigin: null,
      reach: "tunnel",
      link,
      nowMs: NOW,
    });
    expect(model.origin).toBeNull();
    expect(model.lanNotice).toMatch(/Network access is on under Settings › Connections/);
    expect(model.link).toEqual({ kind: "none" });
  });

  it("explains every phase short of up", () => {
    const phases = ["invalidPort", "blocked", "unavailable", "starting", "stopped"] as const;
    for (const phase of phases) {
      const model = pairPhoneCardModel({
        forkTunnel: tunnel(phase),
        lanOrigin: null,
        reach: "tunnel",
        link: null,
        nowMs: NOW,
      });
      expect(model.tunnel).toBe(phase);
      expect(model.tunnelNotice).not.toBeNull();
      expect(model.origin).toBeNull();
    }
    expect(
      pairPhoneCardModel({
        forkTunnel: tunnel("invalidPort"),
        lanOrigin: null,
        reach: "tunnel",
        link: null,
        nowMs: NOW,
      }).tunnelNotice,
    ).toContain("3773");
  });

  it("treats a status without the tunnel as an older build", () => {
    const model = pairPhoneCardModel({
      forkTunnel: undefined,
      lanOrigin: "http://192.168.1.20:3773",
      reach: "tunnel",
      link: null,
      nowMs: NOW,
    });
    expect(model.tunnel).toBe("unsupported");
    expect(model.tunnelNotice).toMatch(/no fork tunnel/);
    // A LAN page can still pair on the network, tunnel or not.
    expect(model.origin?.kind).toBe("lan");
  });

  it("keeps a state a newer build adds out of the known phases", () => {
    const model = pairPhoneCardModel({
      forkTunnel: tunnel("reconnecting"),
      lanOrigin: null,
      reach: "tunnel",
      link: null,
      nowMs: NOW,
    });
    expect(model.tunnel).toBe("unknown");
    expect(model.tunnelNotice).toContain("reconnecting");
  });

  it("counts the link down and expires it", () => {
    const at = (nowMs: number) =>
      pairPhoneCardModel({
        forkTunnel: tunnel("up", TUNNEL_URL),
        lanOrigin: null,
        reach: "tunnel",
        link,
        nowMs,
      }).link;
    expect(at(NOW + 298_000)).toMatchObject({ kind: "active", secondsLeft: 2 });
    expect(at(NOW + 299_400)).toEqual({ kind: "expired" });
    expect(at(NOW + 400_000)).toEqual({ kind: "expired" });
  });

  it("drops the link when the tunnel goes down under it", () => {
    const model = pairPhoneCardModel({
      forkTunnel: tunnel("stopped"),
      lanOrigin: null,
      reach: "tunnel",
      link,
      nowMs: NOW,
    });
    expect(model.link).toEqual({ kind: "none" });
  });
});

describe("phonePairingUrl", () => {
  it("mints the site's universal link with token, marker and the Mac's origin in the fragment, never the query (#724)", () => {
    const url = new URL(phonePairingUrl(TUNNEL_URL, "fixture-token"));
    expect(url.origin + url.pathname).toBe("https://infinitus.run/pair");
    expect(url.search).toBe("");
    const fragment = new URLSearchParams(url.hash.slice(1));
    expect(fragment.get("token")).toBe("fixture-token");
    expect(fragment.get("for")).toBe("phone");
    expect(fragment.get("to")).toBe(new URL(TUNNEL_URL).origin);
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
    expect(isPhonePairingLink(new URL(phonePairingUrl(TUNNEL_URL, "fixture-token")))).toBe(true);
    expect(isPhonePairingLink(new URL(`${TUNNEL_URL}/pair#token=fixture-token&for=phone`))).toBe(
      true,
    );
    expect(isPhonePairingLink(new URL(`${TUNNEL_URL}/pair#token=fixture-token`))).toBe(false);
    expect(isPhonePairingLink(new URL(`${TUNNEL_URL}/pair?for=phone#token=fixture-token`))).toBe(
      false,
    );
    expect(isPhonePairingLink(new URL(`${TUNNEL_URL}/pair#for=laptop&token=fixture-token`))).toBe(
      false,
    );
    expect(isPhonePairingLink(new URL(`${TUNNEL_URL}/pair`))).toBe(false);
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
