import { EnvironmentId } from "@infinitus/contracts";
import type { TeamMemberRow } from "@infinitus/contracts/relayInfinitusTeam";
import { describe, expect, it } from "@effect/vitest";

import {
  buildJoinLink,
  machineIsOnline,
  machineNow,
  memberSummary,
  parseJoinInput,
  relativeTime,
  untilTime,
  threadsIndex,
  transcriptRows,
} from "./infinitusTeamLogic.ts";

const TOKEN = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_abcde";
const NOW = Date.parse("2026-09-25T07:00:00.000Z");

describe("parseJoinInput", () => {
  it.each([
    [TOKEN, TOKEN],
    [`  ${TOKEN}\n`, TOKEN],
    [`infinitus://join/${TOKEN}`, TOKEN],
    [`infinitus-dev://join/${TOKEN}`, TOKEN],
    [`https://infinitus.run/join#${TOKEN}`, TOKEN],
    [`https://infinitus.run/join#${encodeURIComponent(TOKEN)}`, TOKEN],
    ["https://infinitus.run/join", null],
    ["short", null],
    ["not a token at all", null],
    ["%E0%A4%A", null],
  ])("%s", (input, expected) => {
    expect(parseJoinInput(input)).toBe(expected);
  });

  it("builds the link the parser reads back", () => {
    expect(parseJoinInput(buildJoinLink(TOKEN))).toBe(TOKEN);
  });
});

const machine = (lastPublished: string | null, now?: unknown) => ({
  environmentId: EnvironmentId.make("env-1"),
  label: "Mac",
  lastPublished,
  ...(now === undefined ? {} : { now }),
});

describe("members", () => {
  it("a machine is online within ten minutes of its last publish", () => {
    expect(machineIsOnline(machine("2026-09-25T06:55:00.000Z"), NOW)).toBe(true);
    expect(machineIsOnline(machine("2026-09-25T06:40:00.000Z"), NOW)).toBe(false);
    expect(machineIsOnline(machine(null), NOW)).toBe(false);
  });

  it("reads live threads off now and shrugs at another shape", () => {
    expect(
      machineNow(machine(null, { live: [{ id: "t", title: "T", project: "p" }], blockers: ["x"] })),
    ).toEqual({ live: [{ id: "t", title: "T", project: "p" }], blockers: ["x"] });
    expect(machineNow(machine(null, { live: "no" }))).toEqual({ live: [], blockers: [] });
    expect(machineNow(machine(null))).toEqual({ live: [], blockers: [] });
  });

  it("summarises a member", () => {
    const member: TeamMemberRow = {
      userId: "u",
      name: "Loc",
      role: "leader",
      founder: true,
      since: "2026-09-01T00:00:00.000Z",
      machines: [
        machine("2026-09-25T06:56:00.000Z", { live: [{ id: "a", title: "A", project: "p" }] }),
        machine("2026-09-24T06:56:00.000Z", { live: [{ id: "b", title: "B", project: "p" }] }),
      ],
    };
    expect(memberSummary(member, NOW)).toBe("founder · 2 machines · 2 live · published 4 min ago");
    expect(memberSummary({ ...member, role: "member", founder: false, machines: [] }, NOW)).toBe(
      "member · 0 machines · published never",
    );
    expect(relativeTime("2026-09-23T07:00:00.000Z", NOW)).toBe("2 d ago");
  });

  it("untilTime counts forward and names a passed moment", () => {
    expect(untilTime("2026-10-02T07:00:00.000Z", NOW)).toBe("in 7 d");
    expect(untilTime("2026-09-25T09:30:00.000Z", NOW)).toBe("in 2 h");
    expect(untilTime("2026-09-25T07:05:00.000Z", NOW)).toBe("in 5 min");
    expect(untilTime("2026-09-25T06:00:00.000Z", NOW)).toBe("expired");
  });
});

describe("documents", () => {
  it("reads a threads index and a transcript chunk, skipping what it cannot", () => {
    expect(
      threadsIndex({
        at: 1,
        threads: [{ id: "t", title: "T", project: "p", status: "idle", updatedAt: 5, extra: 1 }],
      }),
    ).toEqual([{ id: "t", title: "T", project: "p", status: "idle", updatedAt: 5 }]);
    expect(threadsIndex("nope")).toEqual([]);
    expect(
      transcriptRows(
        '{"role":"user","text":"hi","at":1}\nnot json\n{"role":"assistant","text":"yo"}\n',
      ),
    ).toEqual([
      { role: "user", text: "hi", at: 1 },
      { role: "assistant", text: "yo" },
    ]);
  });
});
