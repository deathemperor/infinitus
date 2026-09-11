import { describe, expect, it } from "vite-plus/test";

import {
  type SweepReport,
  nearbyServerFromDescriptor,
  networkWord,
  pickedHostNeedsCode,
  preferredHost,
  probeUrl,
  subnetCandidates,
  subnetLabel,
  shouldRetrySweep,
  sweepSummary,
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

const report = (overrides: Partial<SweepReport> = {}): SweepReport => ({
  ownIp: "192.168.2.45",
  network: "Wi‑Fi",
  port: 3773,
  timeoutMs: 800,
  probed: 253,
  servers: 0,
  answeredOther: 0,
  timedOut: 250,
  failed: 3,
  failure: "Network request failed",
  aborted: false,
  elapsedMs: 8_640,
  ...overrides,
});

describe("sweepSummary", () => {
  it("is one line with the subnet, the port, the phone's address and the counts (#787)", () => {
    expect(sweepSummary(report())).toBe(
      "Swept 192.168.2.0/24 on :3773 from 192.168.2.45 on Wi‑Fi: 253 probed, 0 answered, 250 timed out (800 ms), 3 failed, 8.6 s. First failure: Network request failed.",
    );
  });

  it("names what else answered and an early stop, and copes without a network word", () => {
    expect(
      sweepSummary(
        report({
          network: null,
          servers: 1,
          answeredOther: 2,
          timedOut: 0,
          failed: 0,
          failure: null,
          aborted: true,
          elapsedMs: 1_040,
        }),
      ),
    ).toBe(
      "Swept 192.168.2.0/24 on :3773 from 192.168.2.45: 253 probed, 1 answered, 0 timed out (800 ms), 0 failed, 2 not a server, 1.0 s. Stopped early.",
    );
  });

  it("says why nothing was swept: a link-local or tailnet address, or none at all", () => {
    expect(sweepSummary(report({ ownIp: "169.254.12.7", probed: 0 }))).toBe(
      "Nothing swept: 169.254.12.7 on Wi‑Fi is not a private Wi‑Fi address.",
    );
    expect(sweepSummary(report({ ownIp: "100.101.5.9", network: null, probed: 0 }))).toBe(
      "Nothing swept: 100.101.5.9 is not a private Wi‑Fi address.",
    );
    expect(sweepSummary(report({ ownIp: null, network: "cellular", probed: 0 }))).toBe(
      "Nothing swept: the phone reported no address on cellular.",
    );
  });
});

describe("subnetLabel", () => {
  it("is the /24 for a private address and null otherwise", () => {
    expect(subnetLabel("10.1.2.3")).toBe("10.1.2.0/24");
    expect(subnetLabel("169.254.1.1")).toBeNull();
    expect(subnetLabel(null)).toBeNull();
  });
});

describe("networkWord", () => {
  it("turns expo-network's type into a word, absent when unknown", () => {
    expect(networkWord("WIFI")).toBe("Wi‑Fi");
    expect(networkWord("CELLULAR")).toBe("cellular");
    expect(networkWord("ETHERNET")).toBe("ethernet");
    expect(networkWord(undefined)).toBeNull();
  });
});

describe("shouldRetrySweep (#787)", () => {
  const report = (over: Partial<import("./lanDiscovery.logic").SweepReport>) => ({
    ownIp: "192.168.2.45",
    network: "Wi‑Fi",
    port: 3773,
    timeoutMs: 800,
    probed: 253,
    servers: 0,
    answeredOther: 0,
    timedOut: 250,
    failed: 3,
    failure: "Network request failed",
    aborted: false,
    elapsedMs: 8_600,
    ...over,
  });

  it("retries the session's first silent sweep once", () => {
    expect(shouldRetrySweep({ report: report({}), firstSweepOfSession: true })).toBe(true);
    expect(shouldRetrySweep({ report: report({}), firstSweepOfSession: false })).toBe(false);
    expect(shouldRetrySweep({ report: report({ retried: true }), firstSweepOfSession: true })).toBe(
      false,
    );
  });

  it("never retries a sweep that found a Mac, probed nothing, or was stopped", () => {
    expect(shouldRetrySweep({ report: report({ servers: 1 }), firstSweepOfSession: true })).toBe(
      false,
    );
    expect(shouldRetrySweep({ report: report({ probed: 0 }), firstSweepOfSession: true })).toBe(
      false,
    );
    expect(shouldRetrySweep({ report: report({ aborted: true }), firstSweepOfSession: true })).toBe(
      false,
    );
  });

  it("says in the line that the sweep was the second one", () => {
    expect(sweepSummary(report({ retried: true }))).toContain(
      "Second sweep, 2 s after the first found nothing.",
    );
    expect(sweepSummary(report({}))).not.toContain("Second sweep");
  });
});
