import { describe, expect, it } from "vite-plus/test";

import {
  nearbyServerFromDescriptor,
  pickedHostNeedsCode,
  preferredHost,
  probeUrl,
  subnetCandidates,
} from "./lanDiscovery.logic";

describe("subnetCandidates", () => {
  it("lists every other host of a private /24", () => {
    const hosts = subnetCandidates("192.168.2.45");
    expect(hosts).toHaveLength(253);
    expect(hosts).toContain("192.168.2.19");
    expect(hosts).not.toContain("192.168.2.45");
    expect(hosts).not.toContain("192.168.2.0");
    expect(hosts).not.toContain("192.168.2.255");
    expect(subnetCandidates("10.0.0.1")).toHaveLength(253);
    expect(subnetCandidates("172.31.4.4")).toHaveLength(253);
  });

  it("sweeps nothing off a public, carrier, IPv6 or missing address", () => {
    expect(subnetCandidates("8.8.8.8")).toEqual([]);
    expect(subnetCandidates("172.32.0.1")).toEqual([]);
    expect(subnetCandidates("fe80::1")).toEqual([]);
    expect(subnetCandidates("192.168.2.999")).toEqual([]);
    expect(subnetCandidates(null)).toEqual([]);
  });
});

describe("nearbyServerFromDescriptor", () => {
  it("reads a desktop server's public descriptor on the fork's port", () => {
    expect(probeUrl("192.168.2.19")).toBe("http://192.168.2.19:3773/.well-known/t3/environment");
    expect(
      nearbyServerFromDescriptor("192.168.2.19", {
        environmentId: "env-1",
        label: "HyperNovae",
        capabilities: { infinitus: true },
      }),
    ).toEqual({
      environmentId: "env-1",
      host: "192.168.2.19:3773",
      label: "HyperNovae",
      infinitus: true,
    });
    expect(
      nearbyServerFromDescriptor("192.168.2.19", { environmentId: "env-1", label: "Plain" }),
    ).toEqual({
      environmentId: "env-1",
      host: "192.168.2.19:3773",
      label: "Plain",
      infinitus: false,
    });
  });

  it("prefers the LAN address the server reports for itself (#757), else the one that answered", () => {
    expect(
      nearbyServerFromDescriptor("192.168.2.19", {
        environmentId: "env-1",
        label: "HyperNovae",
        lanHttpBaseUrls: ["http://192.168.2.5:3773", "http://10.0.0.5:3773"],
      })?.host,
    ).toBe("192.168.2.5:3773");
    expect(preferredHost("192.168.2.19", 3773, ["http://192.168.2.5"])).toBe("192.168.2.5:80");
    expect(preferredHost("192.168.2.19", 3773, ["https://mac.example.com:3773"])).toBe(
      "192.168.2.19:3773",
    );
    expect(preferredHost("192.168.2.19", 3773, [])).toBe("192.168.2.19:3773");
    expect(preferredHost("192.168.2.19", 3773, undefined)).toBe("192.168.2.19:3773");
  });

  it("ignores anything else listening on that port", () => {
    expect(nearbyServerFromDescriptor("192.168.2.7", null)).toBeNull();
    expect(nearbyServerFromDescriptor("192.168.2.7", "<html>")).toBeNull();
    expect(nearbyServerFromDescriptor("192.168.2.7", { label: "no id" })).toBeNull();
  });
});

describe("pickedHostNeedsCode", () => {
  it("waits for the code only while the Host is the one a found Mac filled", () => {
    const picked = "192.168.2.5:3773";
    expect(pickedHostNeedsCode({ pickedHost: picked, hostInput: picked, codeInput: "" })).toBe(
      true,
    );
    expect(pickedHostNeedsCode({ pickedHost: picked, hostInput: picked, codeInput: " abc " })).toBe(
      false,
    );
    expect(
      pickedHostNeedsCode({ pickedHost: picked, hostInput: "10.0.0.9:3773", codeInput: "" }),
    ).toBe(false);
    expect(pickedHostNeedsCode({ pickedHost: null, hostInput: picked, codeInput: "" })).toBe(false);
  });
});
