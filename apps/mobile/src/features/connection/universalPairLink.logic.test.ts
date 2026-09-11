import { describe, expect, it } from "vite-plus/test";

import {
  isUniversalPairLink,
  pairingUrlFromUniversalLink,
  resolvePairingLink,
} from "./universalPairLink.logic";

const link = (fragment: string) => `https://infinitus.run/pair#${fragment}`;

describe("pairingUrlFromUniversalLink", () => {
  it("rebuilds upstream's /pair link on the origin the fragment names", () => {
    expect(
      pairingUrlFromUniversalLink(link("token=abc-123&for=phone&to=https%3A%2F%2Fmac.example.com")),
    ).toBe("https://mac.example.com/pair#token=abc-123&for=phone");
    expect(
      pairingUrlFromUniversalLink(link("to=http%3A%2F%2F192.168.2.5%3A3773&for=phone&token=t")),
    ).toBe("http://192.168.2.5:3773/pair#token=t&for=phone");
    expect(
      pairingUrlFromUniversalLink(" https://infinitus.run/pair/#token=t&for=phone&to=https://a.b "),
    ).toBe("https://a.b/pair#token=t&for=phone");
  });

  it("refuses anything that is not the site's /pair with a token and the phone marker", () => {
    expect(
      pairingUrlFromUniversalLink("https://mac.example.com/pair#token=t&for=phone"),
    ).toBeNull();
    expect(
      pairingUrlFromUniversalLink("http://infinitus.run/pair#token=t&for=phone&to=https://a.b"),
    ).toBeNull();
    expect(
      pairingUrlFromUniversalLink("https://infinitus.run/docs#token=t&for=phone&to=https://a.b"),
    ).toBeNull();
    expect(pairingUrlFromUniversalLink(link("for=phone&to=https://a.b"))).toBeNull();
    expect(pairingUrlFromUniversalLink(link("token=t&to=https://a.b"))).toBeNull();
    expect(pairingUrlFromUniversalLink(link("token=t&for=phone"))).toBeNull();
    expect(pairingUrlFromUniversalLink("not a url")).toBeNull();
  });

  it("takes `to` as a bare origin only", () => {
    const bad = [
      "https://a.b/some/path",
      "https://a.b/?q=1",
      "https://a.b/#frag",
      "https://user:pw@a.b",
      "ftp://a.b",
      "javascript:alert(1)",
      "a.b",
    ];
    for (const to of bad) {
      expect(
        pairingUrlFromUniversalLink(link(`token=t&for=phone&to=${encodeURIComponent(to)}`)),
      ).toBeNull();
    }
    expect(
      pairingUrlFromUniversalLink(
        link(`token=t&for=phone&to=${encodeURIComponent("https://a.b/")}`),
      ),
    ).toBe("https://a.b/pair#token=t&for=phone");
  });

  it("leaves every other link alone", () => {
    expect(isUniversalPairLink("https://infinitus.run/pair")).toBe(true);
    expect(isUniversalPairLink("https://infinitus.run/")).toBe(false);
    expect(resolvePairingLink("https://mac.example.com/pair#token=t")).toBe(
      "https://mac.example.com/pair#token=t",
    );
    expect(resolvePairingLink(link("token=t&for=phone&to=https://a.b"))).toBe(
      "https://a.b/pair#token=t&for=phone",
    );
  });
});
