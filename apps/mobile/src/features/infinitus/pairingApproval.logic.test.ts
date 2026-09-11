import { describe, expect, it } from "vite-plus/test";

import {
  approvalOrigin,
  createdFromReply,
  deviceLabel,
  EXPIRY_GRACE_MS,
  outcomeMessage,
  pollReplyFromBody,
} from "./pairingApproval.logic";

describe("approvalOrigin", () => {
  it("uses http for an IP literal and https for a name, like the pairing URL", () => {
    expect(approvalOrigin("192.168.2.19:3773")).toBe("http://192.168.2.19:3773");
    expect(approvalOrigin(" mac.tail1234.ts.net ")).toBe("https://mac.tail1234.ts.net");
    expect(approvalOrigin("http://mac.local:3773/")).toBe("http://mac.local:3773");
  });

  it("is null for an empty or unparsable host", () => {
    expect(approvalOrigin("")).toBeNull();
    expect(approvalOrigin("   ")).toBeNull();
    expect(approvalOrigin("not a host")).toBeNull();
  });
});

describe("deviceLabel", () => {
  it("trims, falls back to iPhone, and stays within the contract's 64 characters", () => {
    expect(deviceLabel("  Loc's iPhone ")).toBe("Loc's iPhone");
    expect(deviceLabel(undefined)).toBe("iPhone");
    expect(deviceLabel("   ")).toBe("iPhone");
    expect(deviceLabel("x".repeat(80))).toHaveLength(64);
  });
});

describe("createdFromReply", () => {
  it("reads the id, the match code and a deadline with grace past expiresAt", () => {
    const created = createdFromReply({
      id: "req-1",
      matchCode: "AB12",
      expiresAt: "2026-09-11T10:02:00.000Z",
    });
    expect(created).toEqual({
      id: "req-1",
      matchCode: "AB12",
      deadlineMillis: Date.parse("2026-09-11T10:02:00.000Z") + EXPIRY_GRACE_MS,
    });
  });

  it("is null for anything else", () => {
    expect(createdFromReply(null)).toBeNull();
    expect(createdFromReply({ id: "req-1" })).toBeNull();
    expect(createdFromReply("<html>")).toBeNull();
  });
});

describe("pollReplyFromBody", () => {
  it("keeps the credential only on approval", () => {
    expect(pollReplyFromBody({ state: "pending" })).toEqual({ state: "pending" });
    expect(pollReplyFromBody({ state: "denied" })).toEqual({ state: "denied" });
    expect(
      pollReplyFromBody({
        state: "approved",
        credential: "cred-1",
        expiresAt: "2026-09-11T10:02:00.000Z",
      }),
    ).toEqual({ state: "approved", credential: "cred-1" });
    expect(pollReplyFromBody({ state: "approved" })).toBeNull();
    expect(pollReplyFromBody({ state: "maybe" })).toBeNull();
  });
});

describe("outcomeMessage", () => {
  it("says nothing on approval or cancel and names the host when nothing answered", () => {
    expect(outcomeMessage({ kind: "approved", credential: "c" }, "h")).toBeNull();
    expect(outcomeMessage({ kind: "cancelled" }, "h")).toBeNull();
    expect(outcomeMessage({ kind: "unreachable" }, " 192.168.2.19:3773 ")).toContain(
      "192.168.2.19:3773",
    );
    expect(outcomeMessage({ kind: "denied" }, "h")).toBe("The Mac declined this request.");
  });
});
