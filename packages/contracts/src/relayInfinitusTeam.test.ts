import * as Schema from "effect/Schema";
import { describe, expect, it } from "vite-plus/test";

import {
  DEFAULT_TEAM_SHARES,
  RelayInfinitusTeamRefusedError,
  TeamDocumentsPublish,
  TeamInviteCreate,
  TeamSnapshot,
  TeamTranscriptPublish,
  teamCommandNeedsTap,
  teamGrantAllows,
} from "./relayInfinitusTeam.ts";

describe("relayInfinitusTeam", () => {
  it("clamps invite days to 1..3650", () => {
    const decode = Schema.decodeUnknownSync(TeamInviteCreate);
    expect(() => decode({ days: 0, oneUse: false })).toThrow();
    expect(() => decode({ days: 3651, oneUse: false })).toThrow();
    expect(() => decode({ days: 1.5, oneUse: false })).toThrow();
    expect(decode({ days: 7, oneUse: true })).toEqual({ days: 7, oneUse: true });
  });

  it("refuses a transcript chunk over 1 MiB and an empty one", () => {
    const decode = Schema.decodeUnknownSync(TeamTranscriptPublish);
    const base = { userId: "user-1", threadId: "thread-1", seq: 0, rows: 1 };
    expect(() => decode({ ...base, lines: "x".repeat(1_048_577) })).toThrow();
    expect(() => decode({ ...base, rows: 0, lines: "" })).toThrow();
    expect(decode({ ...base, lines: "{}" }).seq).toBe(0);
  });

  it("caps a publish at forty documents", () => {
    const decode = Schema.decodeUnknownSync(TeamDocumentsPublish);
    const document = { kind: "stats", key: "2026-09-25", body: {} };
    expect(() => decode({ userId: "u", documents: Array.from({ length: 41 }, () => document) })).toThrow();
    expect(decode({ userId: "u", documents: [document] }).documents).toHaveLength(1);
  });

  it("every kind starts off", () => {
    expect(Object.values(DEFAULT_TEAM_SHARES).every((audience) => audience === "off")).toBe(true);
  });

  it("decodes a snapshot with an opaque now body", () => {
    const decode = Schema.decodeUnknownSync(TeamSnapshot);
    const snapshot = decode({
      teamId: "team-1",
      name: "Papaya",
      role: "leader",
      policy: { requests: "code" },
      me: { name: "Loc", shares: DEFAULT_TEAM_SHARES },
      members: [
        {
          userId: "user-1",
          name: "Loc",
          role: "leader",
          founder: true,
          since: "2026-09-25T00:00:00.000Z",
          machines: [{ environmentId: "env-1", label: "Mac", now: { at: 1 }, lastPublished: null }],
        },
      ],
      requests: [],
      invites: [],
      grants: [],
      pending: [],
      grantsToMe: [],
    });
    expect(snapshot.members[0]?.machines[0]?.now).toEqual({ at: 1 });
  });

  it("the refusal's message is its reason", () => {
    const error = new RelayInfinitusTeamRefusedError({
      code: "infinitus_team_refused",
      reason: "This invite was already used.",
      traceId: "trace",
    });
    expect(error.message).toBe("This invite was already used.");
  });
});

describe("teamGrantAllows", () => {
  const grant = {
    grantId: "g-1",
    environmentId: "env-1" as never,
    audience: "leaders" as const,
    threads: ["thread-1"] as never,
    capabilities: ["view", "send", "new"] as const,
    preauthorized: ["new"] as const,
    expiresAt: null,
  };
  const base = { fromUserId: "user-2", fromRole: "leader" as const, threadId: "thread-1", action: "send" as const, nowIso: "2026-09-25T00:00:00.000Z" };
  it("checks audience, capability, thread and expiry", () => {
    expect(teamGrantAllows(grant, base)).toBe(true);
    expect(teamGrantAllows(grant, { ...base, fromRole: "member" })).toBe(false);
    expect(teamGrantAllows(grant, { ...base, action: "interrupt" })).toBe(false);
    expect(teamGrantAllows(grant, { ...base, threadId: "thread-2" })).toBe(false);
    expect(teamGrantAllows({ ...grant, expiresAt: "2025-01-01T00:00:00.000Z" }, base)).toBe(false);
    expect(teamGrantAllows({ ...grant, audience: ["user-2"] }, { ...base, fromRole: "member" })).toBe(true);
  });
  it("new targets the machine, never a thread", () => {
    expect(teamGrantAllows(grant, { ...base, action: "new", threadId: "-" })).toBe(true);
    expect(teamGrantAllows(grant, { ...base, action: "new" })).toBe(false);
    expect(teamGrantAllows(grant, { ...base, threadId: "-" })).toBe(false);
  });
  it("interrupt and new need a tap unless preauthorized", () => {
    expect(teamCommandNeedsTap(grant, "new")).toBe(false);
    expect(teamCommandNeedsTap(grant, "interrupt")).toBe(true);
    expect(teamCommandNeedsTap(grant, "send")).toBe(false);
  });
});
