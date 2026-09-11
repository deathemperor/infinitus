import type { PairingApprovalRequest } from "@t3tools/contracts/infinitusPairing";
import * as DateTime from "effect/DateTime";
import { describe, expect, it } from "vite-plus/test";

import { decisionNotice, pairingRequestRows, unseenRequests } from "./pairingRequests.logic";

const NOW_MS = Date.parse("2026-09-11T10:00:30Z");

function request(overrides: Partial<PairingApprovalRequest> = {}): PairingApprovalRequest {
  return {
    id: "req-1",
    deviceName: "Titan",
    os: "iOS 26",
    remoteAddress: "192.168.1.20",
    matchCode: "AB12",
    createdAt: DateTime.makeUnsafe("2026-09-11T10:00:00Z"),
    expiresAt: DateTime.makeUnsafe("2026-09-11T10:02:00Z"),
    ...overrides,
  };
}

describe("pairingRequestRows", () => {
  it("carries the name, the match code and the time left", () => {
    expect(pairingRequestRows([request()], NOW_MS)).toEqual([
      {
        id: "req-1",
        deviceName: "Titan",
        detail: "iOS 26 · 192.168.1.20",
        matchCode: "AB12",
        secondsLeft: 90,
      },
    ]);
  });

  it("shows whichever of os and address the request carried, and no detail without either", () => {
    const { os: _os, ...withoutOs } = request();
    const { remoteAddress: _address, ...withoutAddress } = request();
    const { os: _o, remoteAddress: _a, ...bare } = request();
    expect(pairingRequestRows([withoutOs], NOW_MS)[0]?.detail).toBe("192.168.1.20");
    expect(pairingRequestRows([withoutAddress], NOW_MS)[0]?.detail).toBe("iOS 26");
    expect(pairingRequestRows([bare], NOW_MS)[0]?.detail).toBeNull();
  });

  it("floors an expired request at zero seconds", () => {
    expect(pairingRequestRows([request()], NOW_MS + 10 * 60_000)[0]?.secondsLeft).toBe(0);
  });
});

describe("decisionNotice", () => {
  it("says nothing when the server took the decision", () => {
    expect(
      decisionNotice({ approve: true, outcome: { kind: "decided", decided: true } }),
    ).toBeNull();
  });

  it("tells the user when the request was already gone", () => {
    expect(decisionNotice({ approve: true, outcome: { kind: "decided", decided: false } })).toBe(
      "That request had already expired.",
    );
  });

  it("names the failed verb and the reason", () => {
    expect(
      decisionNotice({ approve: false, outcome: { kind: "failed", message: "not allowed" } }),
    ).toBe("Could not deny that request: not allowed");
  });
});

describe("unseenRequests", () => {
  it("keeps stream order and drops the ids already toasted", () => {
    const first = request({ id: "req-1" });
    const second = request({ id: "req-2" });
    expect(unseenRequests([first, second], new Set(["req-1"]))).toEqual([second]);
    expect(unseenRequests([first, second], new Set())).toEqual([first, second]);
  });
});
