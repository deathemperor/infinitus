import { describe, expect, it } from "vite-plus/test";

import {
  formatCountdown,
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
      pageOrigin: null,
      link,
      nowMs: NOW,
    });
    expect(model.tunnel).toBe("up");
    expect(model.tunnelNotice).toBeNull();
    expect(model.origin).toEqual({ kind: "tunnel", url: TUNNEL_URL });
    expect(model.link).toEqual({
      kind: "active",
      url: `${TUNNEL_URL}/pair#token=fixture-token`,
      secondsLeft: 300,
    });
  });

  it("prefers the tunnel over the page's LAN origin", () => {
    const model = pairPhoneCardModel({
      forkTunnel: tunnel("up", TUNNEL_URL),
      pageOrigin: "http://192.168.1.20:3773",
      link: null,
      nowMs: NOW,
    });
    expect(model.origin?.kind).toBe("tunnel");
  });

  it("falls back to a LAN origin while the tunnel is off, and says so", () => {
    const model = pairPhoneCardModel({
      forkTunnel: tunnel("off"),
      pageOrigin: "http://192.168.1.20:3773",
      link,
      nowMs: NOW,
    });
    expect(model.tunnel).toBe("off");
    expect(model.tunnelNotice).toMatch(/Turn on the Cloudflare quick tunnel/);
    expect(model.origin).toEqual({ kind: "lan", url: "http://192.168.1.20:3773" });
    expect(model.link.kind).toBe("active");
  });

  it("offers no link at all from a loopback page with the tunnel off", () => {
    const model = pairPhoneCardModel({
      forkTunnel: tunnel("off"),
      pageOrigin: null,
      link,
      nowMs: NOW,
    });
    expect(model.origin).toBeNull();
    expect(model.link).toEqual({ kind: "none" });
  });

  it("explains every phase short of up", () => {
    const phases = ["invalidPort", "blocked", "unavailable", "starting", "stopped"] as const;
    for (const phase of phases) {
      const model = pairPhoneCardModel({
        forkTunnel: tunnel(phase),
        pageOrigin: null,
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
        pageOrigin: null,
        link: null,
        nowMs: NOW,
      }).tunnelNotice,
    ).toContain("3773");
  });

  it("treats a status without the tunnel as an older build", () => {
    const model = pairPhoneCardModel({
      forkTunnel: undefined,
      pageOrigin: "http://192.168.1.20:3773",
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
      pageOrigin: null,
      link: null,
      nowMs: NOW,
    });
    expect(model.tunnel).toBe("unknown");
    expect(model.tunnelNotice).toContain("reconnecting");
  });

  it("counts the link down and expires it", () => {
    const at = (nowMs: number) =>
      pairPhoneCardModel({ forkTunnel: tunnel("up", TUNNEL_URL), pageOrigin: null, link, nowMs })
        .link;
    expect(at(NOW + 298_000)).toMatchObject({ kind: "active", secondsLeft: 2 });
    expect(at(NOW + 299_400)).toEqual({ kind: "expired" });
    expect(at(NOW + 400_000)).toEqual({ kind: "expired" });
  });

  it("drops the link when the tunnel goes down under it", () => {
    const model = pairPhoneCardModel({
      forkTunnel: tunnel("stopped"),
      pageOrigin: null,
      link,
      nowMs: NOW,
    });
    expect(model.link).toEqual({ kind: "none" });
  });
});

describe("phonePairingUrl", () => {
  it("puts the token in the fragment of the /pair page, never the query", () => {
    const url = new URL(phonePairingUrl(TUNNEL_URL, "fixture-token"));
    expect(url.pathname).toBe("/pair");
    expect(url.search).toBe("");
    expect(url.hash).toBe("#token=fixture-token");
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
