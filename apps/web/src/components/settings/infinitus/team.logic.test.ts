import { InfinitusSecretRefused } from "@t3tools/contracts/infinitus";
import * as Cause from "effect/Cause";
import { describe, expect, it } from "vite-plus/test";

import {
  infinitusSecretFailure,
  NEVER_PREAUTHORIZED,
  parseTeamGrant,
  parseTeamGrants,
  parseTeamStatus,
  relativeUnix,
  teamCommandInput,
  teamCreateCommandInput,
  teamCreateDraft,
  teamCreateSecretArgs,
  teamCreateSupported,
  teamGrantAudienceLabel,
  teamGrantCapabilitiesLabel,
  teamGrantCommandInput,
  teamGrantDraftProblem,
  teamGrantExpiryLabel,
  teamGrantsCommandInput,
  teamGrantSessionsLabel,
  teamGrantsSupported,
  parseTeamHostnameReply,
  teamHostnameClearInput,
  teamHostnameDraft,
  teamHostnameSecretArgs,
  teamHostnameSupported,
  teamJoinSecretArgs,
  teamJoinSupported,
  teamMemberName,
  teamMemberSummary,
  teamRevokeCommandInput,
  teamStatusSupported,
  type TeamGrant,
} from "./team.logic";

const command = (name: string, stdin?: string) => ({
  name,
  args: [],
  options: [],
  effect: "write" as const,
  summary: "",
  replyShape: "",
  ...(stdin === undefined ? {} : { stdin }),
});

const NOW = 1_700_000_000_000;

describe("team.logic (#747)", () => {
  it("gates on team-status, and join on team-join taking stdin as a secret", () => {
    expect(teamStatusSupported([command("team-status")])).toBe(true);
    expect(teamStatusSupported([command("prefs")])).toBe(false);
    expect(teamJoinSupported([command("team-join", "secret")])).toBe(true);
    expect(teamJoinSupported([command("team-join")])).toBe(false);
  });

  it("reads team-status: null is no team, a snapshot decodes, anything else is refused", () => {
    expect(parseTeamStatus(null)).toEqual({ team: null });
    expect(parseTeamStatus(undefined)).toEqual({ team: null });
    const parsed = parseTeamStatus({
      id: "t1",
      name: "Alpha",
      remote: "github.com/…/alpha",
      kid: "k-me",
      role: "leader",
      rev: 3,
      members: [
        {
          kid: "k-me",
          name: "Me",
          role: "leader",
          isMe: true,
          founder: true,
          kinds: [],
          sessionsNow: 2,
          blockers: [],
          crashes: 0,
          todayUSD: 1.5,
          todayMessages: 40,
          todayCommits: 3,
        },
      ],
      requests: [
        { kid: "k-2", name: "Bo", platform: "macOS", devices: ["MBP"], at: 1_699_999_000 },
      ],
      lastFetch: 1_699_999_900,
      lastPublish: null,
      lastError: null,
    });
    expect(parsed?.team?.name).toBe("Alpha");
    expect(parsed?.team?.requests[0]?.name).toBe("Bo");
    expect(parseTeamStatus({ name: "Alpha" })).toBeNull();
  });

  it("builds the secret-free verbs", () => {
    expect(teamCommandInput({ type: "status" })).toEqual({
      command: "team-status",
      args: [],
      options: {},
    });
    expect(teamCommandInput({ type: "approve", kid: "k-2" })).toEqual({
      command: "team-approve",
      args: ["k-2"],
      options: {},
    });
    expect(teamCommandInput({ type: "decline", kid: "k-2" })).toEqual({
      command: "team-decline",
      args: ["k-2"],
      options: {},
    });
  });

  it("keys the join's name by the manifest's `<your name>` and keeps the code off it", () => {
    expect(teamJoinSecretArgs("Alice")).toEqual({
      command: "team-join",
      args: { "your name": "Alice" },
    });
    expect(teamMemberName("  Alice ")).toBe("Alice");
    expect(teamMemberName("   ")).toBeNull();
    expect(teamMemberName("a".repeat(129))).toBeNull();
  });

  it("words times and members", () => {
    expect(relativeUnix(null, NOW)).toBe("never");
    expect(relativeUnix(NOW / 1000 - 10, NOW)).toBe("just now");
    expect(relativeUnix(NOW / 1000 - 300, NOW)).toBe("5 min ago");
    expect(relativeUnix(NOW / 1000 - 7200, NOW)).toBe("2 h ago");
    expect(relativeUnix(NOW / 1000 - 172_800, NOW)).toBe("2 d ago");
    expect(
      teamMemberSummary(
        {
          kid: "k",
          name: "Me",
          role: "member",
          isMe: true,
          sessionsNow: 1,
          todayMessages: 4,
          todayCommits: 1,
          lastPublished: NOW / 1000 - 60,
          blockers: ["tests red"],
        },
        NOW,
      ),
    ).toBe(
      "Member · you · 1 session now · 4 messages · 1 commits today · published 1 min ago · blocked: tests red",
    );
  });

  it("words the server's secret refusals and passes the socket's error through", () => {
    expect(
      infinitusSecretFailure(
        Cause.fail(
          new InfinitusSecretRefused({
            command: "team-join",
            reason: "too_many_attempts",
            detail: "",
          }),
        ),
      ),
    ).toBe("Too many attempts; wait a minute and try again.");
    expect(infinitusSecretFailure(Cause.fail(new Error("team-join needs the team code")))).toBe(
      "team-join needs the team code",
    );
  });
});

describe("team.logic create (#747)", () => {
  it("gates on team-create taking stdin as a secret", () => {
    expect(teamCreateSupported([command("team-create", "secret")])).toBe(true);
    expect(teamCreateSupported([command("team-create")])).toBe(false);
  });

  it("trims the draft and refuses blanks and overlong fields", () => {
    expect(teamCreateDraft(" Alpha ", "Me", " git@host:o/r.git ")).toEqual({
      name: "Alpha",
      leader: "Me",
      remote: "git@host:o/r.git",
    });
    expect(teamCreateDraft("", "Me", "url")).toBeNull();
    expect(teamCreateDraft("Alpha", "Me", "u".repeat(129))).toBeNull();
  });

  it("keys the secret call by the manifest's names and keeps the token off the args", () => {
    const draft = { name: "Alpha", leader: "Me", remote: "https://host/o/r.git" };
    expect(teamCreateSecretArgs(draft)).toEqual({
      command: "team-create",
      args: { name: "Alpha", remote: "https://host/o/r.git", as: "Me" },
    });
    expect(teamCreateCommandInput(draft)).toEqual({
      command: "team-create",
      args: ["Alpha"],
      options: { remote: "https://host/o/r.git", as: "Me" },
    });
  });
});

describe("team.logic hostnames (#747)", () => {
  it("gates on team-hostname taking stdin as a secret", () => {
    expect(teamHostnameSupported([command("team-hostname", "secret")])).toBe(true);
    expect(teamHostnameSupported([command("team-hostname")])).toBe(false);
  });

  it("keys the save by the manifest's option names and clears over the plain verb", () => {
    expect(teamHostnameDraft(" example.com ", "team")).toEqual({
      zone: "example.com",
      label: "team",
    });
    expect(teamHostnameDraft("", "team")).toBeNull();
    expect(teamHostnameSecretArgs({ zone: "example.com", label: "team" })).toEqual({
      command: "team-hostname",
      args: { zone: "example.com", label: "team" },
    });
    expect(teamHostnameClearInput()).toEqual({
      command: "team-hostname",
      args: [],
      options: { clear: "true" },
    });
  });

  it("reads the reply after a save and after --clear", () => {
    expect(
      parseTeamHostnameReply({ zone: "example.com", label: "team", configured: true }),
    ).toEqual({
      zone: "example.com",
      label: "team",
      configured: true,
    });
    expect(parseTeamHostnameReply({ zone: null, label: null, configured: false })).toEqual({
      zone: null,
      label: null,
      configured: false,
    });
    expect(parseTeamHostnameReply({ ok: true })).toBeNull();
  });
});

describe("team.logic grants (#220)", () => {
  it("gates on all three grant verbs", () => {
    expect(
      teamGrantsSupported([command("team-grants"), command("team-grant"), command("team-revoke")]),
    ).toBe(true);
    expect(teamGrantsSupported([command("team-grants"), command("team-grant")])).toBe(false);
  });

  it("builds the write verbs, omitting a never-preauthorised capability from pre", () => {
    expect(
      teamGrantDraftProblem({
        audience: "team",
        kids: [],
        capabilities: [],
        preauthorized: [],
        sessions: [],
        expiresSeconds: null,
      }),
    ).toBe("Pick at least one capability.");
    expect(
      teamGrantDraftProblem({
        audience: "members",
        kids: [],
        capabilities: ["send"],
        preauthorized: [],
        sessions: [],
        expiresSeconds: null,
      }),
    ).toBe("Pick at least one member.");
    expect(
      teamGrantDraftProblem({
        audience: "team",
        kids: [],
        capabilities: ["send"],
        preauthorized: [],
        sessions: [],
        expiresSeconds: null,
      }),
    ).toBeNull();

    expect(
      teamGrantCommandInput({
        audience: "members",
        kids: ["k-2", "k-1"],
        capabilities: ["stop", "delete"],
        preauthorized: NEVER_PREAUTHORIZED,
        sessions: [],
        expiresSeconds: 3600,
      }),
    ).toEqual({
      command: "team-grant",
      args: ["k-2,k-1"],
      options: { cap: "delete,stop", expires: "3600" },
    });

    expect(
      teamGrantCommandInput({
        audience: "team",
        kids: [],
        capabilities: ["send"],
        preauthorized: [],
        sessions: [],
        expiresSeconds: null,
      }),
    ).toEqual({ command: "team-grant", args: ["team"], options: { cap: "send" } });

    expect(teamRevokeCommandInput("g-1")).toEqual({
      command: "team-revoke",
      args: ["g-1"],
      options: {},
    });
    expect(teamGrantsCommandInput()).toEqual({ command: "team-grants", args: [], options: {} });
  });

  it("reads team-grants leniently and rejects garbage", () => {
    const full: TeamGrant = {
      id: "g-1",
      audience: "leaders",
      sessions: "all",
      capabilities: ["stop"],
      preauthorized: ["stop"],
      since: 1_699_000_000,
      expires: 1_699_100_000,
    };
    const bare: TeamGrant = {
      id: "g-2",
      audience: "team",
      sessions: ["s-1"],
      capabilities: ["view"],
      since: 1_699_000_000,
    };
    expect(parseTeamGrants({ schema: 1, grants: [full, bare] })).toEqual([full, bare]);
    expect(parseTeamGrant(bare)).toEqual(bare);
    expect(parseTeamGrants({ grants: "nope" })).toBeNull();
    expect(parseTeamGrants(null)).toBeNull();
    expect(parseTeamGrant({ id: "g-1" })).toBeNull();
  });

  it("words audience, sessions, capabilities and expiry", () => {
    const members = [
      { kid: "k-1", name: "Ada", role: "leader", isMe: false },
      { kid: "k-2", name: "Bo", role: "member", isMe: false },
    ];
    const leadersGrant: TeamGrant = {
      id: "g-1",
      audience: "leaders",
      sessions: "all",
      capabilities: ["view", "send"],
      since: 1,
    };
    expect(teamGrantAudienceLabel(leadersGrant, members)).toBe("leaders");
    expect(teamGrantAudienceLabel({ ...leadersGrant, audience: "team" }, members)).toBe(
      "whole team",
    );
    expect(
      teamGrantAudienceLabel({ ...leadersGrant, audience: ["k-2", "k-1", "k-9999999"] }, members),
    ).toBe("Bo, Ada, k-999999");
    expect(teamGrantSessionsLabel(leadersGrant)).toBe("all sessions");
    expect(teamGrantSessionsLabel({ ...leadersGrant, sessions: ["s-1"] })).toBe("1 session");
    expect(teamGrantSessionsLabel({ ...leadersGrant, sessions: ["s-1", "s-2"] })).toBe(
      "2 sessions",
    );
    expect(teamGrantCapabilitiesLabel(leadersGrant)).toBe("send, view");
    expect(
      teamGrantCapabilitiesLabel({
        ...leadersGrant,
        capabilities: ["stop", "hold"],
        preauthorized: ["hold"],
      }),
    ).toBe("hold (no ask), stop (asks)");

    const NOW = 1_700_000_000_000;
    expect(teamGrantExpiryLabel(leadersGrant, NOW)).toBe("until revoked");
    expect(teamGrantExpiryLabel({ ...leadersGrant, expires: NOW / 1000 + 7500 }, NOW)).toBe(
      "expires in 2 h 05 m",
    );
    expect(teamGrantExpiryLabel({ ...leadersGrant, expires: NOW / 1000 - 10 }, NOW)).toBe(
      "expired",
    );
  });
});
