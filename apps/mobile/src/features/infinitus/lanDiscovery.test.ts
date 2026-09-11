import { describe, expect, it } from "vite-plus/test";

import { discoverNearbyServers, type Probe } from "./lanDiscovery";

const descriptor = (label: string) => ({ environmentId: label, label, capabilities: {} });

describe("discoverNearbyServers", () => {
  it("reports every address that answers with a descriptor and tolerates the rest", async () => {
    const tried: string[] = [];
    const probe: Probe = async (url) => {
      tried.push(url);
      if (url.startsWith("http://192.168.2.19:")) return descriptor("HyperNovae");
      if (url.startsWith("http://192.168.2.7:")) throw new TypeError("Network request failed");
      if (url.startsWith("http://192.168.2.8:")) return "<html>";
      return null;
    };
    const found: string[] = [];
    let clock = 1_000;
    const report = await discoverNearbyServers({
      ownIp: "192.168.2.45",
      network: "Wi‑Fi",
      signal: new AbortController().signal,
      onFound: (server) => found.push(`${server.label}@${server.host}`),
      probe,
      now: () => (clock += 1_700),
    });
    expect(tried).toHaveLength(253);
    expect(found).toEqual(["HyperNovae@192.168.2.19:3773"]);
    // The report (#787): every address counted once, the transport's words kept.
    expect(report).toEqual({
      ownIp: "192.168.2.45",
      network: "Wi‑Fi",
      port: 3773,
      timeoutMs: 800,
      probed: 253,
      servers: 1,
      answeredOther: 251,
      timedOut: 0,
      failed: 1,
      failure: "Network request failed",
      aborted: false,
      elapsedMs: 1_700,
    });
  });

  it("counts a probe the timer cut off as a timeout, not a failure", async () => {
    const probe: Probe = (_url, signal) =>
      new Promise((_resolve, reject) => {
        signal.addEventListener("abort", () => reject(new Error("Aborted")));
      });
    const report = await discoverNearbyServers({
      ownIp: "10.0.0.2",
      signal: new AbortController().signal,
      onFound: () => {},
      probe,
      timeoutMs: 5,
    });
    expect(report.probed).toBe(253);
    expect(report.timedOut).toBe(253);
    expect(report.timeoutMs).toBe(5);
    expect(report.failed).toBe(0);
    expect(report.failure).toBeNull();
  });

  it("sweeps nothing for a link-local or tailnet address and says so in the report", async () => {
    let tried = 0;
    const probe: Probe = async () => {
      tried += 1;
      return null;
    };
    const report = await discoverNearbyServers({
      ownIp: "169.254.12.7",
      signal: new AbortController().signal,
      onFound: () => {},
      probe,
    });
    expect(tried).toBe(0);
    expect(report.probed).toBe(0);
    expect(report.ownIp).toBe("169.254.12.7");
  });

  it("stops at abort and reports nothing after it", async () => {
    const controller = new AbortController();
    let tried = 0;
    const probe: Probe = async () => {
      tried += 1;
      if (tried === 10) controller.abort();
      return descriptor("late");
    };
    const found: string[] = [];
    const report = await discoverNearbyServers({
      ownIp: "10.0.0.2",
      signal: controller.signal,
      onFound: (server) => found.push(server.host),
      probe,
    });
    expect(tried).toBeLessThan(253);
    expect(found.length).toBeLessThan(10);
    expect(report.aborted).toBe(true);
    expect(report.probed).toBe(tried);
  });
});
