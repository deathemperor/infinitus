import type { InfinitusFleet, InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  fleetProviderForDriver,
  headroomVerdict,
  holdMarkerSummary,
  releaseMarkerSummary,
} from "./infinitusSessionHold.logic.ts";

const fleet = (
  key: string,
  provider: string,
  overrides: Partial<InfinitusFleet> = {},
): InfinitusFleet => ({
  key,
  engineID: key.split("/")[0] ?? key,
  provider,
  capabilities: [],
  accounts: [
    { number: 1, email: "one@example.com", active: true, isOrganization: false, usageStatus: "ok" },
  ],
  ...overrides,
});

const snapshot = (fleets: ReadonlyArray<InfinitusFleet>): InfinitusSnapshot => ({
  available: true,
  fleets,
  sessions: [],
  commands: [],
});

describe("fleetProviderForDriver", () => {
  it("maps the Claude and Codex drivers to their fleet providers and nothing else", () => {
    expect(fleetProviderForDriver("claudeAgent")).toBe("claude");
    expect(fleetProviderForDriver("codex")).toBe("codex");
    expect(fleetProviderForDriver("opencode")).toBeNull();
  });
});

describe("headroomVerdict", () => {
  it("is unknown with no fleet for the provider", () => {
    expect(headroomVerdict(snapshot([fleet("cswap/claude", "claude")]), "codex")).toEqual({
      verdict: "unknown",
    });
  });

  it("is unknown while the fleet publishes no headroom (mode off, older build)", () => {
    expect(headroomVerdict(snapshot([fleet("cswap/claude", "claude")]), "claude")).toEqual({
      verdict: "unknown",
    });
  });

  it("holds on low and on critical, naming the fleet", () => {
    const low = fleet("cswap/claude", "claude", {
      headroom: { state: "low", window: "5h", pct: 84 },
    });
    expect(headroomVerdict(snapshot([low]), "claude")).toEqual({ verdict: "hold", fleet: low });
    const critical = fleet("cswap/claude", "claude", { headroom: { state: "critical" } });
    expect(headroomVerdict(snapshot([critical]), "claude")).toEqual({
      verdict: "hold",
      fleet: critical,
    });
  });

  it("releases on abundant", () => {
    const abundant = fleet("cswap/claude", "claude", { headroom: { state: "abundant" } });
    expect(headroomVerdict(snapshot([abundant]), "claude")).toEqual({
      verdict: "release",
      fleet: abundant,
    });
  });

  it("with two fleets for one provider holds only when every one reads low, releases when any reads abundant", () => {
    const low = fleet("cswap/claude", "claude", { headroom: { state: "low" } });
    const silent = fleet("swapd/claude", "claude");
    const abundant = fleet("swapd/claude", "claude", { headroom: { state: "abundant" } });
    const alsoLow = fleet("swapd/claude", "claude", { headroom: { state: "critical" } });

    expect(headroomVerdict(snapshot([low, silent]), "claude")).toEqual({ verdict: "unknown" });
    expect(headroomVerdict(snapshot([low, abundant]), "claude")).toEqual({
      verdict: "release",
      fleet: abundant,
    });
    expect(headroomVerdict(snapshot([low, alsoLow]), "claude")).toEqual({
      verdict: "hold",
      fleet: low,
    });
  });

  it("ignores a fleet with no active account", () => {
    const idle = fleet("swapd/claude", "claude", {
      headroom: { state: "low" },
      accounts: [
        {
          number: 1,
          email: "x@example.com",
          active: false,
          isOrganization: false,
          usageStatus: "ok",
        },
      ],
    });
    expect(headroomVerdict(snapshot([idle]), "claude")).toEqual({ verdict: "unknown" });
  });
});

describe("marker summaries", () => {
  it("names the fleet and the binding window when known", () => {
    expect(
      holdMarkerSummary(
        fleet("cswap/claude", "claude", { headroom: { state: "low", window: "5h", pct: 84 } }),
      ),
    ).toBe("Held for headroom on claude, 5h window 84 %");
    expect(holdMarkerSummary(fleet("cswap/claude", "claude", { headroom: { state: "low" } }))).toBe(
      "Held for headroom on claude",
    );
  });

  it("says why a thread was released", () => {
    expect(releaseMarkerSummary("abundant", "claude")).toBe(
      "Released: headroom abundant on claude",
    );
    expect(releaseMarkerSummary("pinned", "claude")).toBe("Released: pinned");
    expect(releaseMarkerSummary("user", "claude")).toBe("Released: run now");
    expect(releaseMarkerSummary("off", "claude")).toBe("Released: no headroom verdict on claude");
  });
});
