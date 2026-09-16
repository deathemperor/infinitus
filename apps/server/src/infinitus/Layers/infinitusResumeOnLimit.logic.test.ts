import {
  EventId,
  ProviderDriverKind,
  ProviderInstanceId,
  type ProviderInstanceConfigMap,
  type ProviderRuntimeEvent,
  ThreadId,
  TurnId,
} from "@infinitus/contracts";
import type { InfinitusAccount, InfinitusSnapshot } from "@infinitus/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  activeClaudeAccounts,
  eventCancelsStop,
  limitMarkerSummary,
  limitStopFromEvent,
  proxyInstanceLabel,
  proxyStop,
  resumeMarkerSummary,
  resumeTarget,
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

  it("drops the stop when the thread moves on or its session goes", () => {
    expect(eventCancelsStop(event("turn.started"), parked)).toBe(true);
    expect(eventCancelsStop(event("turn.aborted"), parked)).toBe(true);
    expect(eventCancelsStop(event("session.exited"), failed)).toBe(true);
    expect(
      eventCancelsStop({ ...event("turn.started"), threadId: ThreadId.make("other") }, parked),
    ).toBe(false);
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
