import type {
  OrchestrationMessage,
  OrchestrationShellSnapshot,
  OrchestrationThreadShell,
} from "@infinitus/contracts";
import { EnvironmentId } from "@infinitus/contracts";
import type { InfinitusFleet, InfinitusSnapshot } from "@infinitus/contracts/infinitus";
import type { TeamGrant, TeamQueuedCommand } from "@infinitus/contracts/relayInfinitusTeam";
import { makeRedactor } from "@infinitus/shared/infinitusTeamRedaction";
import { describe, expect, it } from "@effect/vitest";

import {
  buildFleetDocument,
  buildNowDocument,
  buildThreadsDocument,
  chunkLines,
  dayDigest,
  decideCommand,
  transcriptRows,
  viewText,
} from "./infinitusTeamRelay.logic.ts";

const NOW = 1_790_000_000;
const RESET_AT = Math.floor(Date.parse("2026-09-25T09:00:00.000Z") / 1000);

const shellThread = (input: {
  id: string;
  projectId?: string;
  title?: string;
  updatedAt?: string;
  turnState?: "running" | "completed" | "error" | "interrupted";
  sessionStatus?: "idle" | "starting" | "running";
  approvals?: boolean;
  input?: boolean;
  archived?: boolean;
}): OrchestrationThreadShell =>
  ({
    id: input.id,
    projectId: input.projectId ?? "p-1",
    title: input.title ?? `Thread ${input.id}`,
    createdAt: "2026-09-25T06:00:00.000Z",
    updatedAt: input.updatedAt ?? "2026-09-25T07:00:00.000Z",
    archivedAt: input.archived === true ? "2026-09-25T07:30:00.000Z" : null,
    latestTurn:
      input.turnState === undefined
        ? null
        : {
            turnId: "turn-1",
            state: input.turnState,
            requestedAt: "2026-09-25T06:59:00.000Z",
            startedAt: "2026-09-25T06:59:30.000Z",
            completedAt: null,
            assistantMessageId: null,
          },
    session:
      input.sessionStatus === undefined
        ? null
        : { threadId: input.id, status: input.sessionStatus, activeTurnId: null },
    hasPendingApprovals: input.approvals === true,
    hasPendingUserInput: input.input === true,
    usage: { turns: 3, inputTokens: 100, outputTokens: 40, costUsd: 0.5, models: ["opus"] },
  }) as never;

const shell = (threads: ReadonlyArray<OrchestrationThreadShell>): OrchestrationShellSnapshot =>
  ({
    snapshotSequence: 1,
    updatedAt: "2026-09-25T07:00:00.000Z",
    projects: [
      { id: "p-1", title: "Limitless", workspaceRoot: "/Users/loc/death/limitless" },
      { id: "p-2", title: "Secret", workspaceRoot: "/Users/loc/death/secret-thing" },
    ],
    threads,
  }) as never;

describe("buildThreadsDocument", () => {
  it("lists running and waiting threads as live rows with their lines", () => {
    const built = buildThreadsDocument(
      shell([
        shellThread({ id: "t-run", turnState: "running" }),
        shellThread({ id: "t-wait", approvals: true }),
        shellThread({ id: "t-input", input: true }),
        shellThread({ id: "t-idle", turnState: "completed" }),
        shellThread({ id: "t-start", sessionStatus: "starting" }),
      ]),
      { now: NOW, exclusions: [] },
    );
    expect(built.live.map((row) => [row.id, row.activityLine ?? null])).toEqual([
      ["t-run", null],
      ["t-wait", "Waiting for approval"],
      ["t-input", "Waiting for input"],
      ["t-start", null],
    ]);
    expect(built.live[0]?.startedAt).toBe(Math.floor(Date.parse("2026-09-25T06:59:30.000Z") / 1000));
    expect(Object.fromEntries(built.document.threads.map((row) => [row.id, row.status]))).toEqual({
      "t-run": "running",
      "t-wait": "waiting",
      "t-input": "waiting",
      "t-idle": "idle",
      "t-start": "starting",
    });
  });

  it("indexes newest first, capped, with basenames only", () => {
    const threads = Array.from({ length: 520 }, (_, i) =>
      shellThread({
        id: `t-${String(i).padStart(3, "0")}`,
        updatedAt: `2026-09-${String(1 + (i % 25)).padStart(2, "0")}T00:00:00.000Z`,
      }),
    );
    const built = buildThreadsDocument(shell(threads), { now: NOW, exclusions: [] });
    expect(built.document.threads).toHaveLength(500);
    expect(built.document.threads[0]?.updatedAt).toBeGreaterThanOrEqual(
      built.document.threads[499]?.updatedAt ?? 0,
    );
    expect(built.document.threads.every((row) => row.project === "limitless")).toBe(true);
    expect(built.document.threads[0]?.usage).toEqual({
      inputTokens: 100,
      outputTokens: 40,
      costUsd: 0.5,
      models: ["opus"],
    });
  });

  it("drops an excluded project's threads and live rows", () => {
    const built = buildThreadsDocument(
      shell([
        shellThread({ id: "t-open", turnState: "running" }),
        shellThread({ id: "t-secret", projectId: "p-2", turnState: "running" }),
      ]),
      { now: NOW, exclusions: ["-Users-loc-death-secret-thing".slice(0, 0) + "secret-thing"] },
    );
    expect(built.document.threads.map((row) => row.id)).toEqual(["t-open"]);
    expect(built.live.map((row) => row.id)).toEqual(["t-open"]);
    expect(built.projectOf.has("t-secret")).toBe(false);
  });
});

const fleet = (accounts: ReadonlyArray<Record<string, unknown>>, active?: number): InfinitusFleet =>
  ({
    key: "claude",
    engineID: "claude",
    provider: "anthropic",
    capabilities: [],
    activeNumber: active,
    accounts,
  }) as never;

describe("fleet documents", () => {
  const accounts = [
    {
      number: 1,
      alias: "work",
      email: "loc@example.com",
      plan: "Max 20x",
      active: true,
      isOrganization: false,
      usageStatus: "ok",
      usage: { fiveHour: { pct: 42.4, resetsAt: "2026-09-25T09:00:00.000Z" }, sevenDay: { pct: 91 } },
    },
    {
      number: 2,
      email: "second@example.com",
      active: false,
      isOrganization: false,
      usageStatus: "relogin_required",
    },
    {
      number: 3,
      email: "third@example.com",
      active: false,
      isOrganization: false,
      usageStatus: "ok",
      disabled: true,
      usage: { fiveHour: { pct: 100 } },
    },
  ];

  it("never carries an email", () => {
    const document = buildFleetDocument([fleet(accounts, 1)], NOW);
    expect(document.fleets[0]?.accounts.map((row) => [row.label, row.status])).toEqual([
      ["work", "limited"],
      ["#2", "expiredLogin"],
      ["#3", "held"],
    ]);
    expect(document.fleets[0]?.active).toBe("work");
    expect(document.fleets[0]?.accounts[0]?.windows).toEqual([
      { label: "5h", pct: 42, resetsAt: RESET_AT },
      { label: "7d", pct: 91 },
    ]);
    const text = `${dayDigest(document)}${Object.values(document.fleets[0]?.accounts ?? []).map((row) => row.label).join()}`;
    expect(text).not.toContain("@");
  });

  it("now carries the active account's windows and the blockers", () => {
    const snapshot: InfinitusSnapshot = {
      available: true,
      fleets: [fleet(accounts, 1), fleet([accounts[1]!])],
      awsLogins: [{ profile: "papaya", flow: "sso" }],
      commands: [],
    } as never;
    const now = buildNowDocument({ at: NOW, machine: "Loc's Mac", live: [], snapshot });
    expect(now.fleets).toEqual([
      {
        engine: "claude",
        account: "work",
        windows: [{ label: "5h", pct: 42, resetsAt: RESET_AT }, { label: "7d", pct: 91 }],
      },
      { engine: "claude", account: null, windows: [] },
    ]);
    expect(now.blockers).toEqual(["AWS login: papaya", "claude: every account limited"]);
    expect(buildNowDocument({ at: NOW, machine: "m", live: [], snapshot: null }).fleets).toEqual([]);
  });
});

const message = (role: string, text: string, i: number): OrchestrationMessage =>
  ({
    id: `m-${i}`,
    role,
    text,
    turnId: null,
    streaming: false,
    createdAt: "2026-09-25T07:00:00.000Z",
    updatedAt: "2026-09-25T07:00:00.000Z",
  }) as never;

describe("transcripts", () => {
  const redact = makeRedactor({ home: "/Users/loc" });

  it("chunks never split a line and stay under the cap", () => {
    const rows = transcriptRows(
      Array.from({ length: 30 }, (_, i) => message(i % 2 === 0 ? "user" : "assistant", "x".repeat(400), i)),
    );
    const chunks = chunkLines(rows, redact, 1000);
    expect(chunks.reduce((sum, chunk) => sum + chunk.rows, 0)).toBe(30);
    for (const chunk of chunks) {
      expect(chunk.lines.length).toBeLessThanOrEqual(1000);
      expect(chunk.lines.endsWith("\n")).toBe(true);
      expect(chunk.lines.split("\n").length - 1).toBe(chunk.rows);
    }
    const [big] = chunkLines([{ role: "user", text: "y".repeat(5000) }], redact, 1000);
    expect(big?.rows).toBe(1);
  });

  it("redacts every line and skips streaming or empty messages", () => {
    const rows = transcriptRows([
      message("user", "cd /Users/loc/x && export KEY=sk-abcdefghijklmnopqrstuvwxyz", 0),
      { ...message("assistant", "", 1) },
      { ...message("assistant", "half", 2), streaming: true } as never,
    ]);
    expect(rows).toHaveLength(1);
    const [chunk] = chunkLines(rows, redact);
    expect(chunk?.lines).toBe('{"role":"user","text":"cd ~/x && export KEY=[redacted-key]","at":1790319600}\n');
    expect(viewText([message("user", "token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234", 0)], redact)).toBe(
      "user: token [redacted-key]",
    );
    expect(viewText([message("user", "a".repeat(5000), 0)], redact)).toHaveLength(4096);
  });

  it("day digest ignores key order", () => {
    expect(dayDigest({ a: 1, b: { c: [1, 2] } })).toBe(dayDigest({ b: { c: [1, 2] }, a: 1 }));
    expect(dayDigest({ a: 1 })).not.toBe(dayDigest({ a: 2 }));
  });
});

describe("decideCommand", () => {
  const grant: TeamGrant = {
    grantId: "g-1",
    environmentId: EnvironmentId.make("env-1"),
    audience: "team",
    threads: "all",
    capabilities: ["view", "send", "interrupt", "new"],
    preauthorized: ["interrupt"],
    expiresAt: null,
  };
  const command = (input: Partial<TeamQueuedCommand>): TeamQueuedCommand =>
    ({
      commandId: "c-1",
      teamId: "team-1",
      fromUserId: "user-2",
      threadId: "t-1",
      action: "send",
      text: "hello",
      expiresAt: "2026-09-25T08:00:00.000Z",
      grant,
      ...input,
    }) as never;
  const live = new Set(["t-1"]);
  const nowIso = "2026-09-25T07:00:00.000Z";

  const cases: Array<
    [string, TeamQueuedCommand, { grants: ReadonlyArray<TeamGrant>; liveThreadIds: ReadonlySet<string> }, Record<string, unknown>]
  > = [
    ["runs a send on a live thread", command({}), { grants: [grant], liveThreadIds: live }, { run: true }],
    ["refuses a revoked grant", command({}), { grants: [], liveThreadIds: live }, { run: false, outcome: "refused" }],
    [
      "noGrant past expiry",
      command({}),
      { grants: [{ ...grant, expiresAt: "2026-09-25T06:00:00.000Z" }], liveThreadIds: live },
      { run: false, outcome: "noGrant" },
    ],
    [
      "noGrant for a thread outside the selector",
      command({ threadId: "t-9" }),
      { grants: [{ ...grant, threads: ["t-1"] as never }], liveThreadIds: new Set(["t-9"]) },
      { run: false, outcome: "noGrant" },
    ],
    ["notLive", command({ threadId: "t-1" }), { grants: [grant], liveThreadIds: new Set() }, { run: false, outcome: "notLive" }],
    ["badRequest with nothing to send", command({ text: " " }), { grants: [grant], liveThreadIds: live }, { run: false, outcome: "badRequest" }],
    ["interrupt preauthorized runs", command({ action: "interrupt" }), { grants: [grant], liveThreadIds: live }, { run: true }],
    ["new waits for the tap", command({ action: "new", threadId: "-", text: "go", project: "Limitless" }), { grants: [grant], liveThreadIds: live }, { run: false, outcome: "pending" }],
    ["view needs no live thread", command({ action: "view" }), { grants: [grant], liveThreadIds: new Set() }, { run: true }],
  ];
  it.each(cases)("%s", (_name, input, context, expected) => {
    expect(decideCommand(input, { ...context, nowIso })).toMatchObject(expected);
  });
});
