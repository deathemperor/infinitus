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
    await discoverNearbyServers({
      ownIp: "192.168.2.45",
      signal: new AbortController().signal,
      onFound: (server) => found.push(`${server.label}@${server.host}`),
      probe,
    });
    expect(tried).toHaveLength(253);
    expect(found).toEqual(["HyperNovae@192.168.2.19:3773"]);
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
    await discoverNearbyServers({
      ownIp: "10.0.0.2",
      signal: controller.signal,
      onFound: (server) => found.push(server.host),
      probe,
    });
    expect(tried).toBeLessThan(253);
    expect(found.length).toBeLessThan(10);
  });
});
