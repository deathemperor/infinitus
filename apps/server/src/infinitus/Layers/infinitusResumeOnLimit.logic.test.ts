import {
  EventId,
  ProviderDriverKind,
  type ProviderRuntimeEvent,
  ThreadId,
  TurnId,
} from "@t3tools/contracts";
import type { InfinitusAccount, InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  activeClaudeAccounts,
  eventCancelsStop,
  limitStopFromEvent,
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
  sessions: [],
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

  it("reads a failed turn off the adapter's usage-limit wording", () => {
    const failed = {
      ...base,
      type: "turn.completed" as const,
      payload: {
        state: "failed" as const,
        errorMessage: "Claude stopped: a usage limit blocked the request.",
      },
    };
    expect(limitStopFromEvent(failed, NOW, snapshot)).toMatchObject({
      kind: "failed",
      resetsAt: null,
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
      ),
    ).toBeNull();
    expect(
      resumeTarget(
        stop,
        snapshotWith([
          account(1, "one@example.com"),
          account(2, "two@example.com", { active: true, usageFetchedAt: after }),
        ]),
      ),
    ).toEqual({ fleetKey: "swapd/claude", account: "two@example.com", from: "one@example.com" });
  });

  it("the same account back after its reset counts, once probed", () => {
    expect(
      resumeTarget(
        stop,
        snapshotWith([account(1, "one@example.com", { active: true, usageFetchedAt: after })]),
      ),
    ).toEqual({ fleetKey: "swapd/claude", account: "one@example.com", from: "one@example.com" });
  });

  it("without a probe time only a different account counts", () => {
    expect(
      resumeTarget(stop, snapshotWith([account(1, "one@example.com", { active: true })])),
    ).toBeNull();
    expect(
      resumeTarget(stop, snapshotWith([account(2, "two@example.com", { active: true })]))?.account,
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
      ),
    ).toBeNull();
    expect(
      resumeTarget(
        stop,
        snapshotWith(
          [account(2, "two@example.com", { active: true, usageFetchedAt: after })],
          "openai",
        ),
      ),
    ).toBeNull();
    const target = resumeTarget(
      stop,
      snapshotWith([
        account(2, "two@example.com", { active: true, alias: "work", usageFetchedAt: after }),
      ]),
    );
    expect(target?.account).toBe("work");
    expect(resumeMarkerSummary(target!)).toBe("Turn resumed on work");
  });
});
