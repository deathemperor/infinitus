import {
  EventId,
  type OrchestrationThreadActivity,
  type OrchestrationThreadShell,
  ProviderDriverKind,
  ProviderInstanceId,
  type ProviderInstanceConfigMap,
  type ProviderRuntimeEvent,
  ThreadId,
  TurnId,
} from "@infinitus/contracts";
import type { InfinitusAccount, InfinitusSnapshot } from "@infinitus/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";
import * as DateTime from "effect/DateTime";

import {
  activeClaudeAccounts,
  eventCancelsStop,
  LIMIT_MARKER_KIND,
  RESUME_MARKER_KIND,
  limitMarkerSummary,
  limitStopFromEvent,
  proxyInstanceLabel,
  proxyStop,
  resumeMarkerSummary,
  resumeTarget,
  restoreLimitStops,
  turnOvertookStop,
  type LimitStop,
} from "./infinitusResumeOnLimit.logic.ts";

const NOW = Date.parse("2026-09-11T10:00:00Z");
const threadId = ThreadId.make("thread-1");
const turnId = TurnId.make("turn-1");
const claude = ProviderDriverKind.make("claudeAgent");

const account = (
  number: number,
  email: string,
  overrides: Partial<InfinitusAccount> = {},
): InfinitusAccount => ({
  number,
  email,
  active: false,
  isOrganization: false,
  usageStatus: "ok",
  ...overrides,
});

const snapshotWith = (
  accounts: ReadonlyArray<InfinitusAccount>,
  provider = "claude",
): InfinitusSnapshot => ({
  available: true,
  fleets: [{ key: `swapd/${provider}`, engineID: "swapd", provider, capabilities: [], accounts }],
  commands: [],
});

const base = {
  eventId: EventId.make("evt-1"),
  provider: claude,
  createdAt: "2026-09-11T10:00:00Z",
  threadId,
  turnId,
};

const parkedWarning = {
  ...base,
  type: "runtime.warning" as const,
  payload: {
    message: "Claude usage limit reached. This turn is paused until the 5-hour limit resets in 2h.",
    detail: { status: "rejected", rateLimitType: "five_hour", resetsAt: 1_757_600_000 },
  },
};

const stopAt = (snapshot: InfinitusSnapshot, kind: LimitStop["kind"] = "parked"): LimitStop => ({
  threadId,
  turnId,
  kind,
  stoppedAt: NOW,
  activeAtStop: activeClaudeAccounts(snapshot),
  resetsAt: null,
  limitType: null,
  proxy: null,
});

describe("restoreLimitStops", () => {
  const createdAt = DateTime.formatIso(DateTime.makeUnsafe(NOW));
  const thread = {
    id: threadId,
    archivedAt: null,
    latestTurn: { turnId, state: "error" },
    session: { status: "error", activeTurnId: null },
    latestUserMessageAt: DateTime.formatIso(DateTime.makeUnsafe(NOW - 1000)),
  } as OrchestrationThreadShell;
  const marker: OrchestrationThreadActivity = {
    id: EventId.make("saved-limit"),
    tone: "info",
    kind: LIMIT_MARKER_KIND,
    summary: "Limit hit",
    turnId,
    createdAt,
    payload: {
      stop: "parked",
      accounts: ["one@example.com"],
      resetsAt: DateTime.formatIso(DateTime.makeUnsafe(NOW + 3600000)),
      proxy: null,
    },
  };

  it("recovers an old parked marker as a failed turn without changing its account", () => {
    expect(restoreLimitStops([thread], [marker], [])).toEqual([
      {
        threadId,
        turnId,
        kind: "failed",
        stoppedAt: NOW,
        activeAtStop: new Map([["swapd/claude", "one@example.com"]]),
        resetsAt: NOW + 3600000,
        limitType: null,
        proxy: null,
      },
    ]);
  });

  it("recovers a stop whose idle session the reaper stopped", () => {
    const reaped = { ...thread, session: { ...thread.session!, status: "stopped" as const } };
    expect(restoreLimitStops([reaped], [marker], [])).toHaveLength(1);
  });

  it("does not revive a resumed, cancelled, archived, active or superseded turn", () => {
    expect(
      restoreLimitStops([thread], [marker], [{ ...marker, kind: RESUME_MARKER_KIND }]),
    ).toEqual([]);
    for (const candidate of [
      { ...thread, archivedAt: createdAt },
      { ...thread, latestTurn: null },
      ...(["interrupted", "completed", "running"] as const).map((state) => ({
        ...thread,
        latestTurn: { ...thread.latestTurn!, state },
      })),
      { ...thread, latestTurn: { ...thread.latestTurn!, turnId: TurnId.make("new-turn") } },
      { ...thread, latestUserMessageAt: DateTime.formatIso(DateTime.makeUnsafe(NOW + 1000)) },
      { ...thread, session: null },
      { ...thread, session: { ...thread.session!, status: "ready" as const } },
      { ...thread, session: { ...thread.session!, activeTurnId: turnId } },
    ]) {
      expect(restoreLimitStops([candidate], [marker], [])).toEqual([]);
    }
  });

  it("ignores proxy stops and malformed markers, and retains the stored window", () => {
    for (const payload of [
      null,
      {},
      { stop: "failed", accounts: [] },
      { stop: "parked", accounts: [], resetsAt: "invalid" },
      { stop: "failed", accounts: [], proxy: "Router" },
    ]) {
      expect(restoreLimitStops([thread], [{ ...marker, payload }], [])).toEqual([]);
    }
    const updated = {
      ...marker,
      payload: { stop: "failed", accounts: ["original"], limitType: "seven_day_opus" },
      createdAt: DateTime.formatIso(DateTime.makeUnsafe(NOW + 1000)),
    };
    expect(restoreLimitStops([thread], [updated, marker], [])[0]).toMatchObject({
      limitType: "seven_day_opus",
      activeAtStop: new Map([["swapd/claude", "original"]]),
    });
  });
});

describe("limitStopFromEvent", () => {
  const snapshot = snapshotWith([account(1, "one@example.com", { active: true })]);

  it("reads a parked turn off the rejected rate-limit detail, never the text", () => {
    expect(limitStopFromEvent(parkedWarning, NOW, snapshot)).toEqual({
      threadId,
      turnId,
      kind: "parked",
      stoppedAt: NOW,
      activeAtStop: new Map([["swapd/claude", "one@example.com"]]),
      // The SDK's epoch seconds, kept as milliseconds.
      resetsAt: 1_757_600_000_000,
      limitType: "five_hour",
      proxy: null,
    });
    // A reset the SDK left out, or one that is not a number, is none.
    expect(
      limitStopFromEvent(
        { ...parkedWarning, payload: { ...parkedWarning.payload, detail: { status: "rejected" } } },
        NOW,
        snapshot,
      )?.resetsAt,
    ).toBeNull();
    expect(
      limitStopFromEvent(
        {
          ...parkedWarning,
          payload: { ...parkedWarning.payload, detail: { status: "rejected", resetsAt: "soon" } },
        },
        NOW,
        snapshot,
      )?.resetsAt,
    ).toBeNull();
    expect(
      limitStopFromEvent(
        { ...parkedWarning, payload: { message: "Reconnecting... 2/5", detail: { attempt: 2 } } },
        NOW,
        snapshot,
      ),
    ).toBeNull();
    expect(
      limitStopFromEvent(
        {
          ...parkedWarning,
          payload: { ...parkedWarning.payload, detail: { status: "allowed_warning" } },
        },
        NOW,
        snapshot,
      ),
    ).toBeNull();
  });

  // A CLI keeps the login it started on for a while after a swap. Fifteen
  // seconds after one, two turns were refused on the previous account's weekly
  // limit; blamed on the live account, a healthy one was reported spent until a
  // reset five days off and benched 70 s after the engine swapped to it.
  describe("names the account the refusal's own figures belong to", () => {
    const usage = (fiveHour: number, sevenDay: number) => ({
      fiveHour: { pct: fiveHour },
      sevenDay: { pct: sevenDay },
    });
    const refusal = (fiveHour: number, sevenDay: number) => ({
      ...parkedWarning,
      payload: {
        ...parkedWarning.payload,
        detail: {
          status: "rejected",
          rateLimitType: "seven_day_overage_included",
          resetsAt: 1_790_236_800,
          unifiedWindows: {
            five_hour: { utilization: fiveHour },
            seven_day: { utilization: sevenDay },
          },
        },
      },
    });
    const swappedTo = (previous: object, another: object = usage(0, 72)) =>
      snapshotWith([
        account(1, "previous@example.com", { usage: previous }),
        account(2, "live@example.com", { active: true, usage: usage(62, 33) }),
        account(3, "another@example.com", { usage: another }),
      ]);
    const named = (event: typeof parkedWarning, snapshot: InfinitusSnapshot) => [
      ...(limitStopFromEvent(event, NOW, snapshot)?.activeAtStop.values() ?? []),
    ];

    it("the live account when its reading agrees, or nothing can be compared", () => {
      expect(named(refusal(0.64, 0.34), swappedTo(usage(38, 72)))).toEqual(["live@example.com"]);
      expect(named(parkedWarning, swappedTo(usage(38, 72)))).toEqual(["live@example.com"]);
      expect(
        named(
          refusal(0.41, 0.73),
          snapshotWith([account(2, "live@example.com", { active: true })]),
        ),
      ).toEqual(["live@example.com"]);
    });

    it("the one other account whose reading agrees when the live one's does not", () => {
      expect(named(refusal(0.41, 0.73), swappedTo(usage(38, 72)))).toEqual([
        "previous@example.com",
      ]);
    });

    it("nobody when the live account's disagrees and no single other one fits", () => {
      expect(named(refusal(0.41, 0.73), swappedTo(usage(38, 72), usage(40, 73)))).toEqual([]);
      expect(named(refusal(0.41, 0.73), swappedTo(usage(5, 5)))).toEqual([]);
    });
  });

  it("reads a failed turn off the adapter's structured limit flag", () => {
    const failed = {
      ...base,
      type: "turn.completed" as const,
      payload: {
        state: "failed" as const,
        usageLimited: true,
        errorMessage: "Claude gave up after repeated API errors.",
      },
    };
    expect(limitStopFromEvent(failed, NOW, snapshot)).toMatchObject({
      kind: "failed",
      resetsAt: null,
      limitType: null,
    });
    expect(
      limitStopFromEvent(
        {
          ...failed,
          payload: { state: "failed", errorMessage: "Claude API is overloaded (529)." },
        },
        NOW,
        snapshot,
      ),
    ).toBeNull();
    expect(
      limitStopFromEvent({ ...failed, payload: { state: "completed" } }, NOW, snapshot),
    ).toBeNull();
  });

  // The CLI's context-window gate (`blocking_limit`) is not a usage limit, and
  // its wording used to say one. Nothing but the flag records a stop now.
  it("ignores a failed turn whose error merely reads like a limit", () => {
    expect(
      limitStopFromEvent(
        {
          ...base,
          type: "turn.completed" as const,
          payload: {
            state: "failed" as const,
            errorMessage: "Claude stopped: a usage limit blocked the request.",
          },
        },
        NOW,
        snapshot,
      ),
    ).toBeNull();
  });

  it("covers the Claude driver only", () => {
    expect(
      limitStopFromEvent(
        { ...parkedWarning, provider: ProviderDriverKind.make("codex") },
        NOW,
        snapshot,
      ),
    ).toBeNull();
  });
});

describe("turnOvertookStop (#1509)", () => {
  const stop = { turnId, stoppedAt: NOW };
  const latestTurn = (input: {
    turnId: TurnId;
    requestedAt: number;
    completedAt?: number;
  }): OrchestrationThreadShell["latestTurn"] =>
    ({
      turnId: input.turnId,
      state: input.completedAt === undefined ? "running" : "completed",
      requestedAt: DateTime.formatIso(DateTime.makeUnsafe(input.requestedAt)),
      startedAt: null,
      completedAt:
        input.completedAt === undefined
          ? null
          : DateTime.formatIso(DateTime.makeUnsafe(input.completedAt)),
      assistantMessageId: null,
    }) as OrchestrationThreadShell["latestTurn"];

  it("reads an open turn requested after the stop as another send's", () => {
    expect(
      turnOvertookStop(
        { latestTurn: latestTurn({ turnId: TurnId.make("turn-2"), requestedAt: NOW + 1_000 }) },
        stop,
      ),
    ).toBe(true);
  });

  it("is not the stop's own parked turn, a settled turn, or an older one", () => {
    expect(
      turnOvertookStop({ latestTurn: latestTurn({ turnId, requestedAt: NOW - 1_000 }) }, stop),
    ).toBe(false);
    expect(
      turnOvertookStop(
        {
          latestTurn: latestTurn({
            turnId: TurnId.make("turn-2"),
            requestedAt: NOW + 1_000,
            completedAt: NOW + 2_000,
          }),
        },
        stop,
      ),
    ).toBe(false);
    expect(
      turnOvertookStop(
        { latestTurn: latestTurn({ turnId: TurnId.make("turn-0"), requestedAt: NOW - 1_000 }) },
        stop,
      ),
    ).toBe(false);
    expect(turnOvertookStop({ latestTurn: null }, stop)).toBe(false);
  });
});

describe("eventCancelsStop", () => {
  const snapshot = snapshotWith([account(1, "one@example.com", { active: true })]);
  const parked = stopAt(snapshot);
  const failed = stopAt(snapshot, "failed");
  const event = (
    type: "turn.started" | "turn.aborted" | "session.exited" | "turn.completed",
  ): ProviderRuntimeEvent =>
    ({
      ...base,
      type,
      payload: type === "turn.completed" ? { state: "completed" } : {},
    }) as ProviderRuntimeEvent;

  it("drops the stop when the thread moves on or its session takes the parked turn", () => {
    expect(eventCancelsStop(event("turn.started"), parked)).toBe(true);
    expect(eventCancelsStop(event("turn.aborted"), parked)).toBe(true);
    expect(eventCancelsStop(event("session.exited"), parked)).toBe(true);
    expect(
      eventCancelsStop({ ...event("turn.started"), threadId: ThreadId.make("other") }, parked),
    ).toBe(false);
  });

  it("a failed stop outlives its session: the idle reaper stops it long before the reset", () => {
    expect(eventCancelsStop(event("session.exited"), failed)).toBe(false);
  });

  it("a completion ends a parked stop but is the failed stop's own record", () => {
    expect(eventCancelsStop(event("turn.completed"), parked)).toBe(true);
    expect(eventCancelsStop(event("turn.completed"), failed)).toBe(false);
  });
});

describe("resumeTarget", () => {
  const before = "2026-09-11T09:59:00Z";
  const after = "2026-09-11T10:00:30Z";
  const atStop = snapshotWith([
    account(1, "one@example.com", { active: true, usageStatus: "exhausted" }),
    account(2, "two@example.com"),
  ]);
  const stop = stopAt(atStop);
  const RESET = NOW + 60 * 60_000;
  const parked: LimitStop = { ...stop, resetsAt: RESET, limitType: "five_hour" };
  const usage = (fiveHour: number, scoped: ReadonlyArray<{ name: string; pct: number }> = []) => ({
    fiveHour: { pct: fiveHour },
    sevenDay: { pct: 10 },
    scoped,
  });

  it("waits for an active account that reads ok from a probe after the stop", () => {
    expect(
      resumeTarget(
        stop,
        snapshotWith([
          account(1, "one@example.com", {
            active: true,
            usageStatus: "ok",
            usageFetchedAt: before,
          }),
          account(2, "two@example.com"),
        ]),
        NOW,
      ),
    ).toBeNull();
    expect(
      resumeTarget(
        stop,
        snapshotWith([
          account(1, "one@example.com"),
          account(2, "two@example.com", { active: true, usageFetchedAt: after }),
        ]),
        NOW,
      ),
    ).toEqual({ fleetKey: "swapd/claude", account: "two@example.com", from: "one@example.com" });
  });

  // swapd rations the usage endpoint: the sweep that decides a swap reads
  // every account, then leaves the idle one it landed on alone for minutes. A
  // thread stopped a second after that sweep waited six minutes for a newer
  // reading while four stopped before it resumed at once.
  it("a swapped-to account counts on a reading from before the stop", () => {
    const swapped = (usageOf: object | undefined) =>
      snapshotWith([
        account(1, "one@example.com"),
        account(2, "two@example.com", {
          active: true,
          usageFetchedAt: before,
          ...(usageOf === undefined ? {} : { usage: usageOf }),
        }),
      ]);
    expect(resumeTarget(parked, swapped(usage(0)), NOW)?.account).toBe("two@example.com");
    expect(resumeTarget(stop, swapped(undefined), NOW)?.account).toBe("two@example.com");
    // Its own window full still holds it back.
    expect(resumeTarget(parked, swapped(usage(100)), NOW)).toBeNull();
  });

  // swapd's `ok` is a credential status, not headroom: the account that just
  // ran out reads `ok` on the very next poll. The same account only counts
  // once its window reset, or once a probe shows that window with room.
  it("the same account counts after its reset, once probed, never on ok alone", () => {
    const same = snapshotWith([
      account(1, "one@example.com", { active: true, usageFetchedAt: after }),
    ]);
    expect(resumeTarget(stop, same, NOW)).toBeNull();
    expect(resumeTarget(parked, same, RESET - 1)).toBeNull();
    expect(resumeTarget(parked, same, RESET)).toEqual({
      fleetKey: "swapd/claude",
      account: "one@example.com",
      from: "one@example.com",
    });
    const roomy = snapshotWith([
      account(1, "one@example.com", { active: true, usageFetchedAt: after, usage: usage(12) }),
    ]);
    expect(resumeTarget(parked, roomy, NOW)?.account).toBe("one@example.com");
  });

  // A turn the CLI failed outright names no window and no reset (the SDK
  // sent no rate-limit event, only its synthetic assistant error), so the
  // account it ran out on had no way back while it stayed the live one: a
  // thread stopped at 05:10 sat two hours past the window's reset with the
  // account reading 20 % on a fresh probe. Every window under full on a
  // reading after the stop is the evidence such a stop can get.
  it("a failed stop with no window resumes on the same account once every window reads under full", () => {
    const failed: LimitStop = { ...stop, kind: "failed" };
    const reading = (windows: object) =>
      snapshotWith([
        account(1, "one@example.com", { active: true, usageFetchedAt: after, usage: windows }),
      ]);
    expect(resumeTarget(failed, reading(usage(20, [{ name: "Fable", pct: 51 }])), NOW)).toEqual({
      fleetKey: "swapd/claude",
      account: "one@example.com",
      from: "one@example.com",
    });
    expect(resumeTarget(failed, reading(usage(100)), NOW)).toBeNull();
    expect(resumeTarget(failed, reading(usage(0, [{ name: "Fable", pct: 100 }])), NOW)).toBeNull();
    // A reading with no windows at all is no evidence; neither is one from
    // before the stop.
    expect(resumeTarget(failed, reading({ scoped: [] }), NOW)).toBeNull();
    expect(
      resumeTarget(
        failed,
        snapshotWith([
          account(1, "one@example.com", { active: true, usageFetchedAt: before, usage: usage(20) }),
        ]),
        NOW,
      ),
    ).toBeNull();
  });

  it("a probe still showing the stop's window full does not count, even after the reset", () => {
    const full = (pct: number, scoped: ReadonlyArray<{ name: string; pct: number }> = []) =>
      snapshotWith([
        account(1, "one@example.com"),
        account(2, "two@example.com", {
          active: true,
          usageFetchedAt: after,
          usage: usage(pct, scoped),
        }),
      ]);
    expect(resumeTarget(parked, full(100), RESET)).toBeNull();
    expect(resumeTarget(parked, full(99), NOW)?.account).toBe("two@example.com");
    const opus: LimitStop = { ...parked, limitType: "seven_day_opus" };
    expect(resumeTarget(opus, full(0, [{ name: "Opus", pct: 100 }]), NOW)).toBeNull();
    expect(resumeTarget(opus, full(0, [{ name: "Opus", pct: 40 }]), NOW)?.account).toBe(
      "two@example.com",
    );
    // A window the reading does not carry is no evidence either way.
    expect(resumeTarget(opus, full(0), NOW)?.account).toBe("two@example.com");
    const unknown: LimitStop = { ...parked, limitType: "seven_day_overage_included" };
    expect(resumeTarget(unknown, full(100), NOW)?.account).toBe("two@example.com");
  });

  it("only the engine that writes the CLI's credentials counts", () => {
    const proxyFleet: InfinitusSnapshot = {
      available: true,
      fleets: [
        {
          key: "cliproxy/claude",
          engineID: "cliproxy",
          provider: "claude",
          capabilities: [],
          accounts: [account(3, "three@example.com", { active: true, usageFetchedAt: after })],
        },
        {
          key: "swapd/claude",
          engineID: "swapd",
          provider: "claude",
          capabilities: [],
          accounts: [account(1, "one@example.com", { active: true, usageFetchedAt: after })],
        },
      ],
      commands: [],
    };
    expect(resumeTarget(stop, proxyFleet, NOW)).toBeNull();
    expect(activeClaudeAccounts(proxyFleet)).toEqual(
      new Map([["swapd/claude", "one@example.com"]]),
    );
  });

  it("without a probe time only a different account counts", () => {
    expect(
      resumeTarget(stop, snapshotWith([account(1, "one@example.com", { active: true })]), NOW),
    ).toBeNull();
    expect(
      resumeTarget(stop, snapshotWith([account(2, "two@example.com", { active: true })]), NOW)
        ?.account,
    ).toBe("two@example.com");
  });

  it("ignores exhausted accounts and other providers, prefers the alias", () => {
    expect(
      resumeTarget(
        stop,
        snapshotWith([
          account(2, "two@example.com", {
            active: true,
            usageStatus: "exhausted",
            usageFetchedAt: after,
          }),
        ]),
        NOW,
      ),
    ).toBeNull();
    expect(
      resumeTarget(
        stop,
        snapshotWith(
          [account(2, "two@example.com", { active: true, usageFetchedAt: after })],
          "openai",
        ),
        NOW,
      ),
    ).toBeNull();
    const target = resumeTarget(
      stop,
      snapshotWith([
        account(2, "two@example.com", { active: true, alias: "work", usageFetchedAt: after }),
      ]),
      NOW,
    );
    expect(target?.account).toBe("work");
    expect(resumeMarkerSummary(target!)).toBe("Turn resumed on work");
  });
});

describe("proxied instances (#1088)", () => {
  const instances: ProviderInstanceConfigMap = {
    [ProviderInstanceId.make("claudeAgent")]: { driver: ProviderDriverKind.make("claudeAgent") },
    [ProviderInstanceId.make("claudeAgent_router")]: {
      driver: ProviderDriverKind.make("claudeAgent"),
      displayName: "Router",
      environment: [
        { name: "ANTHROPIC_BASE_URL", value: "http://127.0.0.1:20128", sensitive: false },
        { name: "ANTHROPIC_AUTH_TOKEN", value: "", sensitive: true, valueRedacted: true },
      ],
    },
    [ProviderInstanceId.make("claudeAgent_blank")]: {
      driver: ProviderDriverKind.make("claudeAgent"),
      environment: [{ name: "ANTHROPIC_BASE_URL", value: " ", sensitive: false }],
    },
  };

  it("names the instance whose environment routes through a proxy, else nothing", () => {
    expect(
      proxyInstanceLabel(instances, { instanceId: ProviderInstanceId.make("claudeAgent") }),
    ).toBeNull();
    expect(
      proxyInstanceLabel(instances, { instanceId: ProviderInstanceId.make("gone") }),
    ).toBeNull();
    expect(
      proxyInstanceLabel(instances, { instanceId: ProviderInstanceId.make("claudeAgent_blank") }),
    ).toBeNull();
    expect(
      proxyInstanceLabel(instances, { instanceId: ProviderInstanceId.make("claudeAgent_router") }),
    ).toBe("Router");
    const unnamed = {
      ...instances,
      [ProviderInstanceId.make("claudeAgent_router")]: {
        driver: ProviderDriverKind.make("claudeAgent"),
        environment: [{ name: "ANTHROPIC_BASE_URL", value: "http://p", sensitive: false }],
      },
    };
    expect(
      proxyInstanceLabel(unnamed, { instanceId: ProviderInstanceId.make("claudeAgent_router") }),
    ).toBe("claudeAgent_router");
  });

  it("a proxied stop names no account and no rotation resumes it", () => {
    const snapshot = snapshotWith([account(1, "one@example.com", { active: true })]);
    const plain = stopAt(snapshot, "failed");
    expect(limitMarkerSummary(plain)).toBe("Limit hit on one@example.com");
    const proxied = proxyStop(plain, "Router");
    expect(proxied.activeAtStop.size).toBe(0);
    expect(limitMarkerSummary(proxied)).toBe("Limit hit on the proxy instance Router");
    const after = "2026-09-11T10:01:00Z";
    const live = snapshotWith([
      account(2, "two@example.com", { active: true, usageFetchedAt: after }),
    ]);
    expect(resumeTarget(plain, live, NOW)).not.toBeNull();
    expect(resumeTarget(proxied, live, NOW)).toBeNull();
  });
});
