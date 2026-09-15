import { describe, expect, it } from "vite-plus/test";

import {
  parseTeamStatus,
  teamCommandInput,
  teamJoinCode,
  teamJoinLinkCode,
  teamJoinSecretArgs,
  teamJoinSupported,
  teamLeads,
  teamMemberSummary,
  teamStatusSupported,
} from "./team.logic";

describe("teamJoinLinkCode", () => {
  it("takes the fragment of the site's /join as the code", () => {
    expect(teamJoinLinkCode("https://infinitus.run/join#abc-123")).toBe("abc-123");
    expect(teamJoinLinkCode(" https://infinitus.run/join/#abc%2B1 ")).toBe("abc+1");
  });

  it("refuses any other host, path or scheme, and an empty fragment", () => {
    expect(teamJoinLinkCode("https://example.com/join#abc")).toBeNull();
    expect(teamJoinLinkCode("http://infinitus.run/join#abc")).toBeNull();
    expect(teamJoinLinkCode("https://infinitus.run/pair#abc")).toBeNull();
    expect(teamJoinLinkCode("https://infinitus.run/join")).toBeNull();
    expect(teamJoinLinkCode("https://infinitus.run/join#")).toBeNull();
    expect(teamJoinLinkCode("not a url")).toBeNull();
  });

  it("teamJoinCode passes a bare code through trimmed", () => {
    expect(teamJoinCode("  abc-123 ")).toBe("abc-123");
    expect(teamJoinCode("https://infinitus.run/join#abc-123")).toBe("abc-123");
  });
});

describe("manifest gates", () => {
  const command = (name: string, stdin?: string) => ({
    name,
    args: [],
    options: [],
    effect: "write" as const,
    summary: "",
    replyShape: "",
    ...(stdin === undefined ? {} : { stdin }),
  });
  const commands = [command("team-status"), command("team-join", "secret")];
  it("need team-status, and team-join with the code on stdin", () => {
    expect(teamStatusSupported(commands)).toBe(true);
    expect(teamJoinSupported(commands)).toBe(true);
    expect(teamStatusSupported([])).toBe(false);
    expect(teamJoinSupported([command("team-join")])).toBe(false);
  });
});

describe("team-status and the verbs", () => {
  const team = {
    id: "t1",
    name: "Ops",
    remote: "git@example.com:ops.git",
    kid: "k-ann",
    role: "leader",
    members: [
      { kid: "k-ann", name: "Ann", role: "leader", isMe: true, threadsNow: 2, lastPublished: 90 },
      { kid: "k-bo", name: "Bo", role: "member", isMe: false, blockers: ["awaiting review"] },
    ],
  };

  it("reads null as no team and the contract's shape as a team", () => {
    expect(parseTeamStatus(null)).toEqual({ team: null });
    expect(parseTeamStatus(team)?.team?.name).toBe("Ops");
    expect(parseTeamStatus({ nope: true })).toBeNull();
  });

  it("names the verbs and their arguments", () => {
    expect(teamCommandInput({ type: "fetch" })).toEqual({
      command: "team-fetch",
      args: [],
      options: {},
    });
    expect(teamCommandInput({ type: "approve", kid: "k-bo" }).args).toEqual(["k-bo"]);
    expect(teamCommandInput({ type: "decline", kid: "k-bo" }).command).toBe("team-decline");
    expect(teamJoinSecretArgs("Bo")).toEqual({ command: "team-join", args: { "your name": "Bo" } });
  });

  it("summarises a member and knows who leads", () => {
    const parsed = parseTeamStatus(team)!.team!;
    expect(teamMemberSummary(parsed.members[0]!, 200_000)).toBe(
      "Leader · you · 2 threads now · published 1 min ago",
    );
    expect(teamMemberSummary(parsed.members[1]!, 200_000)).toBe(
      "Member · 0 threads now · published never · blocked: awaiting review",
    );
    expect(teamLeads(parsed)).toBe(true);
    expect(teamLeads({ ...parsed, members: [{ ...parsed.members[1]!, isMe: true }] })).toBe(false);
  });
});
