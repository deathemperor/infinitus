import { InfinitusSecretRefused } from "@t3tools/contracts/infinitus";
import * as Cause from "effect/Cause";
import { describe, expect, it } from "vite-plus/test";

import {
  infinitusSecretFailure,
  parseTeamCode,
  parseTeamStatus,
  relativeUnix,
  teamCommandInput,
  teamCreateCommandInput,
  teamCreateDraft,
  teamCreateSecretArgs,
  teamCreateSupported,
  teamExclusionSlug,
  teamJoinLink,
  teamJoinSecretArgs,
  teamJoinSupported,
  teamMemberName,
  teamMemberSummary,
  teamStatusSupported,
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

describe("team.logic (#1313)", () => {
  it("gates on team-status, join and create on their verbs taking stdin as a secret", () => {
    expect(teamStatusSupported([command("team-status")])).toBe(true);
    expect(teamStatusSupported([command("prefs")])).toBe(false);
    expect(teamJoinSupported([command("team-join", "secret")])).toBe(true);
    expect(teamJoinSupported([command("team-join")])).toBe(false);
    expect(teamCreateSupported([command("team-create", "secret")])).toBe(true);
    expect(teamCreateSupported([command("team-create")])).toBe(false);
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
          threadsNow: 2,
        },
      ],
      requests: [
        { kid: "k-2", name: "Bo", platform: "macos", devices: ["MBP"], at: 1_699_999_000 },
      ],
      shares: { transcripts: "off" },
      exclusions: ["secret-repo"],
      lockEnabled: false,
      lastFetch: 1_699_999_900,
      lastPublish: null,
      lastError: null,
    });
    expect(parsed?.team?.name).toBe("Alpha");
    expect(parsed?.team?.requests?.[0]?.name).toBe("Bo");
    expect(parsed?.team?.shares?.transcripts).toBe("off");
    expect(parseTeamStatus({ name: "Alpha" })).toBeNull();
    expect(parseTeamCode({ code: "infinitus://join/abc", expires: 1 })?.code).toBe(
      "infinitus://join/abc",
    );
    expect(parseTeamCode({ nope: 1 })).toBeNull();
  });

  it("builds every secret-free verb", () => {
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
    expect(teamCommandInput({ type: "remove", kid: "k-2" }).command).toBe("team-remove");
    expect(teamCommandInput({ type: "promote", kid: "k-2" }).command).toBe("team-promote");
    expect(teamCommandInput({ type: "leave" })).toEqual({
      command: "team-leave",
      args: [],
      options: { yes: "true" },
    });
    expect(teamCommandInput({ type: "share", kind: "transcripts", target: "off" })).toEqual({
      command: "team-share",
      args: ["transcripts", "off"],
      options: {},
    });
    expect(teamCommandInput({ type: "exclude", slug: "secret-repo", on: true }).args).toEqual([
      "add",
      "secret-repo",
    ]);
    expect(teamCommandInput({ type: "exclude", slug: "secret-repo", on: false }).args).toEqual([
      "remove",
      "secret-repo",
    ]);
    expect(teamCommandInput({ type: "policy", requests: "off" }).args).toEqual(["requests", "off"]);
    expect(teamCommandInput({ type: "code", days: 7, invite: false })).toEqual({
      command: "team-code",
      args: [],
      options: { days: "7" },
    });
    expect(teamCommandInput({ type: "code", days: 1, invite: true }).options).toEqual({
      days: "1",
      invite: "true",
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
    expect(teamExclusionSlug(" secret-repo ")).toBe("secret-repo");
    expect(teamExclusionSlug("/Users/me/repo")).toBeNull();
  });

  it("keys the create call by the manifest's names and keeps the token off the args", () => {
    expect(teamCreateDraft(" Alpha ", "Me", " git@host:o/r.git ")).toEqual({
      name: "Alpha",
      leader: "Me",
      remote: "git@host:o/r.git",
    });
    expect(teamCreateDraft("", "Me", "url")).toBeNull();
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

  it("puts the code in the site link's fragment", () => {
    expect(teamJoinLink("infinitus://join/a b")).toBe(
      "https://infinitus.run/join#infinitus%3A%2F%2Fjoin%2Fa%20b",
    );
  });

  it("words times and members", () => {
    expect(relativeUnix(null, NOW)).toBe("never");
    expect(relativeUnix(NOW / 1000 - 300, NOW)).toBe("5 min ago");
    expect(relativeUnix(NOW / 1000 - 172_800, NOW)).toBe("2 d ago");
    expect(
      teamMemberSummary(
        {
          kid: "k",
          name: "Me",
          role: "member",
          isMe: true,
          threadsNow: 1,
          todayMessages: 4,
          todayCommits: 1,
          lastPublished: NOW / 1000 - 60,
          blockers: ["aws: papaya"],
        },
        NOW,
      ),
    ).toBe(
      "Member · you · 1 thread now · 4 messages · 1 commits today · published 1 min ago · blocked: aws: papaya",
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
