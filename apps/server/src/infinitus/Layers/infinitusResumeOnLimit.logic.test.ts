import { RunId, ThreadId, type OrchestrationV2ThreadShell } from "@infinitus/contracts";
import type { InfinitusAccount, InfinitusSnapshot } from "@infinitus/contracts/infinitus";
import * as DateTime from "effect/DateTime";
import { describe, expect, it } from "vite-plus/test";

import {
  failedStopFromShell,
  limitStopSummary,
  proxyInstanceLabel,
  refusedAccount,
  RESET_MATCH_MS,
  resumeTarget,
  toWireStop,
  type LimitStop,
} from "./infinitusResumeOnLimit.logic.ts";

const STOPPED_AT = Date.parse("2026-10-11T02:22:49Z");
const PROBE_BEFORE = "2026-10-11T02:20:00Z";
const PROBE_AFTER = "2026-10-11T02:25:00Z";
/** hiep1's weekly reset: what the refusal of #1486 carried. */
const HIEP1_WEEKLY = "2026-10-15T08:00:00Z";
/** loctruongh's weekly reset, a day off. */
const LOC_WEEKLY = "2026-10-16T00:59:00Z";

const account = (
  email: string,
  overrides: Partial<InfinitusAccount> & { readonly usage?: unknown } = {},
): InfinitusAccount => ({
  number: 1,
  email,
  active: false,
  isOrganization: false,
  usageStatus: "ok",
  usageFetchedAt: PROBE_AFTER,
  ...overrides,
});

const snapshot = (
  accounts: ReadonlyArray<InfinitusAccount>,
  fleet: { engineID?: string; provider?: string } = {},
): InfinitusSnapshot => ({
  available: true,
  commands: [],
  fleets: [
    {
      key: `${fleet.engineID ?? "swapd"}/${fleet.provider ?? "claude"}`,
      engineID: fleet.engineID ?? "swapd",
      provider: fleet.provider ?? "claude",
      capabilities: [],
      accounts,
    },
  ],
});

const stop = (overrides: Partial<LimitStop> = {}): LimitStop => ({
  threadId: ThreadId.make("thread-1"),
  runId: RunId.make("run-1"),
  kind: "parked",
  stoppedAt: STOPPED_AT,
  fleetKey: "swapd/claude",
  account: "hiep1",
  resetsAt: Date.parse(HIEP1_WEEKLY),
  limitType: "seven_day",
  proxy: null,
  ...overrides,
});

describe("refusedAccount (#1486)", () => {
  const refusal = { rateLimitType: "seven_day" as const, resetsAt: Date.parse(HIEP1_WEEKLY) };

  it("names the active account when its reading of the window agrees with the refusal", () => {
    const fleet = snapshot([
      account("hiep1", { active: true, usage: { sevenDay: { pct: 100, resetsAt: HIEP1_WEEKLY } } }),
      account("loctruongh", { usage: { sevenDay: { pct: 34, resetsAt: LOC_WEEKLY } } }),
    ]);
    expect(refusedAccount(refusal, fleet)).toEqual({ fleetKey: "swapd/claude", account: "hiep1" });
  });

  it("names the one other account whose window matches when the active one's does not", () => {
    // 02:22:34 swapd swapped hiep1 → loctruongh; 02:22:49 the parked stop
    // landed with hiep1's weekly reset. loctruongh must not be reported.
    const fleet = snapshot([
      account("hiep1", { usage: { sevenDay: { pct: 100, resetsAt: HIEP1_WEEKLY } } }),
      account("loctruongh", {
        active: true,
        usage: { sevenDay: { pct: 34, resetsAt: LOC_WEEKLY } },
      }),
    ]);
    expect(refusedAccount(refusal, fleet)).toEqual({ fleetKey: "swapd/claude", account: "hiep1" });
  });

  it("names nobody when the active account disagrees and no single other one fits", () => {
    const fleet = snapshot([
      account("hiep1", { usage: { sevenDay: { pct: 100, resetsAt: HIEP1_WEEKLY } } }),
      account("hiep2", { usage: { sevenDay: { pct: 90, resetsAt: HIEP1_WEEKLY } } }),
      account("loctruongh", {
        active: true,
        usage: { sevenDay: { pct: 34, resetsAt: LOC_WEEKLY } },
      }),
    ]);
    expect(refusedAccount(refusal, fleet)).toEqual({ fleetKey: "swapd/claude", account: null });
    expect(
      refusedAccount(
        refusal,
        snapshot([
          account("loctruongh", {
            active: true,
            usage: { sevenDay: { pct: 34, resetsAt: LOC_WEEKLY } },
          }),
        ]),
      ),
    ).toEqual({ fleetKey: "swapd/claude", account: null });
  });

  it("keeps today's behaviour, the active account, when nothing can be compared", () => {
    const active = account("loctruongh", { active: true, usage: { fiveHour: { pct: 10 } } });
    const noReset = snapshot([active, account("hiep1")]);
    expect(refusedAccount(refusal, noReset)?.account).toBe("loctruongh");
    expect(refusedAccount({ ...refusal, resetsAt: null }, noReset)?.account).toBe("loctruongh");
    expect(
      refusedAccount({ rateLimitType: null, resetsAt: refusal.resetsAt }, noReset)?.account,
    ).toBe("loctruongh");
    // A reading rounded by the engine still matches within the slack.
    const rounded = snapshot([
      account("loctruongh", {
        active: true,
        usage: {
          sevenDay: {
            pct: 100,
            resetsAt: DateTime.formatIso(
              DateTime.makeUnsafe(Date.parse(HIEP1_WEEKLY) + RESET_MATCH_MS - 1),
            ),
          },
        },
      }),
    ]);
    expect(refusedAccount(refusal, rounded)?.account).toBe("loctruongh");
  });

  it("reads scoped windows by the model word and epoch-second resets", () => {
    const fleet = snapshot([
      account("hiep1", {
        active: true,
        usage: {
          sevenDay: { pct: 20, resetsAt: LOC_WEEKLY },
          scoped: [{ name: "Opus", pct: 100, resetsAt: Date.parse(HIEP1_WEEKLY) / 1000 }],
        },
      }),
    ]);
    expect(refusedAccount({ ...refusal, rateLimitType: "seven_day_opus" }, fleet)?.account).toBe(
      "hiep1",
    );
    // The plain weekly window disagrees, and no other account fits.
    expect(refusedAccount(refusal, fleet)?.account).toBeNull();
  });

  it("covers only the engine that writes the CLI's credentials", () => {
    expect(
      refusedAccount(refusal, snapshot([account("a", { active: true })], { engineID: "cliproxy" })),
    ).toBeNull();
    expect(
      refusedAccount(refusal, snapshot([account("a", { active: true })], { provider: "codex" })),
    ).toBeNull();
    expect(refusedAccount(refusal, snapshot([]))).toEqual({
      fleetKey: "swapd/claude",
      account: null,
    });
  });
});

describe("resumeTarget", () => {
  const now = STOPPED_AT + 60_000;

  it("waits for an active account that reads ok from a probe after the stop with room in the window", () => {
    const stale = snapshot([
      account("hiep2", {
        active: true,
        usageFetchedAt: PROBE_BEFORE,
        usage: { sevenDay: { pct: 10 } },
      }),
    ]);
    // A different account than the one at the stop counts on an older probe too.
    expect(resumeTarget(stop(), stale, now)).toEqual({
      fleetKey: "swapd/claude",
      account: "hiep2",
      from: "hiep1",
    });
    const sameStale = snapshot([
      account("hiep1", {
        active: true,
        usageFetchedAt: PROBE_BEFORE,
        usage: { sevenDay: { pct: 10 } },
      }),
    ]);
    expect(resumeTarget(stop(), sameStale, now)).toBeNull();
    const exhausted = snapshot([account("hiep2", { active: true, usageStatus: "exhausted" })]);
    expect(resumeTarget(stop(), exhausted, now)).toBeNull();
  });

  it("the same account counts on a reading under full, never on ok alone, or once its reset passed", () => {
    const full = snapshot([account("hiep1", { active: true, usage: { sevenDay: { pct: 100 } } })]);
    expect(resumeTarget(stop(), full, now)).toBeNull();
    expect(resumeTarget(stop(), full, Date.parse(HIEP1_WEEKLY) + 1)).toBeNull();
    const room = snapshot([account("hiep1", { active: true, usage: { sevenDay: { pct: 40 } } })]);
    expect(resumeTarget(stop(), room, now)?.account).toBe("hiep1");
    const noWindow = snapshot([
      account("hiep1", { active: true, usage: { fiveHour: { pct: 1 } } }),
    ]);
    expect(resumeTarget(stop(), noWindow, now)).toBeNull();
    expect(resumeTarget(stop(), noWindow, Date.parse(HIEP1_WEEKLY) + 1)?.account).toBe("hiep1");
  });

  it("a stop with no window or reset resumes on the same account once every window reads under full", () => {
    const bare = stop({ kind: "failed", resetsAt: null, limitType: null });
    const half = snapshot([
      account("hiep1", { active: true, usage: { fiveHour: { pct: 100 }, sevenDay: { pct: 20 } } }),
    ]);
    expect(resumeTarget(bare, half, now)).toBeNull();
    const under = snapshot([
      account("hiep1", { active: true, usage: { fiveHour: { pct: 20 }, sevenDay: { pct: 20 } } }),
    ]);
    expect(resumeTarget(bare, under, now)?.account).toBe("hiep1");
  });

  it("an unnamed stop takes any account with a fresh probe and a reading under full", () => {
    const unnamed = stop({ account: null, fleetKey: null });
    const fresh = snapshot([account("hiep1", { active: true, usage: { sevenDay: { pct: 40 } } })]);
    expect(resumeTarget(unnamed, fresh, now)?.account).toBe("hiep1");
    const stale = snapshot([
      account("hiep1", {
        active: true,
        usageFetchedAt: PROBE_BEFORE,
        usage: { sevenDay: { pct: 40 } },
      }),
    ]);
    expect(resumeTarget(unnamed, stale, now)).toBeNull();
  });

  it("a proxied stop (#1088) and another engine's fleet never resume, and the alias is preferred", () => {
    const alias = snapshot([
      account("x@y", { active: true, alias: "work", usage: { sevenDay: { pct: 1 } } }),
    ]);
    expect(resumeTarget(stop({ proxy: "cliproxy" }), alias, now)).toBeNull();
    expect(
      resumeTarget(
        stop(),
        snapshot([account("x", { active: true })], { engineID: "cliproxy" }),
        now,
      ),
    ).toBeNull();
    expect(resumeTarget(stop(), alias, now)?.account).toBe("work");
  });
});

describe("proxied instances (#1088)", () => {
  it("names the instance whose environment routes through a proxy, else nothing", () => {
    const instances = {
      plain: { driver: "claudeAgent", displayName: "Plain", environment: [] },
      proxied: {
        driver: "claudeAgent",
        displayName: "Through cliproxy",
        environment: [{ name: "ANTHROPIC_BASE_URL", value: "http://127.0.0.1:8317" }],
      },
      blank: {
        driver: "claudeAgent",
        environment: [{ name: "ANTHROPIC_BASE_URL", value: "  " }],
      },
    } as never;
    expect(proxyInstanceLabel(instances, { instanceId: "plain" as never })).toBeNull();
    expect(proxyInstanceLabel(instances, { instanceId: "proxied" as never })).toBe(
      "Through cliproxy",
    );
    expect(proxyInstanceLabel(instances, { instanceId: "blank" as never })).toBeNull();
    expect(proxyInstanceLabel(instances, { instanceId: "missing" as never })).toBeNull();
  });
});

describe("failedStopFromShell", () => {
  const shell = {
    id: ThreadId.make("thread-1"),
    status: "failed",
    lastErrorClass: "usage_limit",
    usageLimitResetAt: HIEP1_WEEKLY,
    latestRunId: RunId.make("run-1"),
    latestRunCompletedAt: null,
    archivedAt: null,
    settledOverride: null,
  } as unknown as OrchestrationV2ThreadShell;

  it("reads a failed limit run off the shell, the window from the refusal of the same run", () => {
    expect(failedStopFromShell(shell, STOPPED_AT, null)).toEqual({
      threadId: shell.id,
      runId: RunId.make("run-1"),
      kind: "failed",
      stoppedAt: STOPPED_AT,
      resetsAt: Date.parse(HIEP1_WEEKLY),
      limitType: null,
    });
    expect(
      failedStopFromShell(shell, STOPPED_AT, {
        runId: RunId.make("run-1"),
        rateLimitType: "seven_day",
      })?.limitType,
    ).toBe("seven_day");
    expect(
      failedStopFromShell(shell, STOPPED_AT, {
        runId: RunId.make("run-0"),
        rateLimitType: "seven_day",
      })?.limitType,
    ).toBeNull();
  });

  it("is nothing for any other failure, a settled or archived thread, or a thread still running", () => {
    expect(
      failedStopFromShell({ ...shell, lastErrorClass: "provider_error" }, STOPPED_AT, null),
    ).toBeNull();
    expect(failedStopFromShell({ ...shell, status: "running" }, STOPPED_AT, null)).toBeNull();
    expect(
      failedStopFromShell({ ...shell, settledOverride: "settled" }, STOPPED_AT, null),
    ).toBeNull();
    expect(
      failedStopFromShell(
        { ...shell, archivedAt: DateTime.makeUnsafe(STOPPED_AT) },
        STOPPED_AT,
        null,
      ),
    ).toBeNull();
    expect(
      failedStopFromShell({ ...shell, usageLimitResetAt: null }, STOPPED_AT, null)?.resetsAt,
    ).toBeNull();
  });
});

describe("the stop's line and wire shape", () => {
  it("names the account, the proxy, or nothing", () => {
    expect(limitStopSummary(stop())).toBe("Limit hit on hiep1");
    expect(limitStopSummary(stop({ account: null }))).toBe("Limit hit");
    expect(limitStopSummary(stop({ proxy: "cliproxy" }))).toBe(
      "Limit hit on the proxy instance cliproxy",
    );
    expect(toWireStop(stop({ proxy: "cliproxy" }))).toEqual({
      threadId: ThreadId.make("thread-1"),
      kind: "parked",
      since: "2026-10-11T02:22:49.000Z",
      account: "hiep1",
      resetsAt: "2026-10-15T08:00:00.000Z",
      proxy: "cliproxy",
    });
    expect(toWireStop(stop({ resetsAt: null }))).not.toHaveProperty("proxy");
  });
});
