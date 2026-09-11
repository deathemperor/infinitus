import { describe, expect, it } from "vite-plus/test";

import { nearbyServerFromDescriptor, probeUrl, subnetCandidates } from "./lanDiscovery.logic";

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
    ).toEqual({ host: "192.168.2.19:3773", label: "HyperNovae", infinitus: true });
    expect(
      nearbyServerFromDescriptor("192.168.2.19", { environmentId: "env-1", label: "Plain" }),
    ).toEqual({ host: "192.168.2.19:3773", label: "Plain", infinitus: false });
  });

  it("ignores anything else listening on that port", () => {
    expect(nearbyServerFromDescriptor("192.168.2.7", null)).toBeNull();
    expect(nearbyServerFromDescriptor("192.168.2.7", "<html>")).toBeNull();
    expect(nearbyServerFromDescriptor("192.168.2.7", { label: "no id" })).toBeNull();
  });
});
