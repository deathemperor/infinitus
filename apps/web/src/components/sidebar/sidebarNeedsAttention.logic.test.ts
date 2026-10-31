import { EnvironmentId, ThreadId } from "@infinitus/contracts";
import type { InfinitusLimitStop } from "@infinitus/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import type { SidebarThreadSummary } from "../../types";
import {
  collectNeedsAttention,
  resolveAttentionRank,
  resolveNextAttentionThreadId,
} from "./sidebarNeedsAttention.logic";

const env = EnvironmentId.make("env-1");

function thread(
  id: string,
  overrides: Partial<SidebarThreadSummary> = {},
  environmentId: EnvironmentId = env,
): SidebarThreadSummary {
  return {
    environmentId,
    id: ThreadId.make(id),
    hasPendingApprovals: false,
    hasPendingUserInput: false,
    runtime: null,
    latestRun: null,
    lineage: { parentThreadId: null, relationshipToParent: null, rootThreadId: ThreadId.make(id) },
    archivedAt: null,
    updatedAt: "2026-09-12T10:00:00.000Z",
    ...overrides,
  } as SidebarThreadSummary;
}

const runtime = (status: string, lastErrorClass?: string) =>
  ({ status, lastErrorClass: lastErrorClass ?? null }) as SidebarThreadSummary["runtime"];

const describeStop = (stop: InfinitusLimitStop) => `Limit hit on ${stop.account}`;

describe("collectNeedsAttention (#269 D)", () => {
  it("lists only blocked threads: approvals, then input, then limits", () => {
    const stop: InfinitusLimitStop = {
      threadId: ThreadId.make("parked"),
      kind: "parked",
      since: "2026-09-12T08:00:00.000Z",
      account: "work",
      resetsAt: null,
    };
    const entries = collectNeedsAttention(
      [
        thread("parked", { runtime: runtime("running") }),
        thread("working", { runtime: runtime("running") }),
        thread("limited", { runtime: runtime("failed", "usage_limit") }),
        thread("input", { hasPendingUserInput: true }),
        thread("failed", { runtime: runtime("failed") }),
        thread("approval", { hasPendingApprovals: true }),
        thread("archived", { hasPendingApprovals: true, archivedAt: "2026-09-12T09:00:00.000Z" }),
        thread("subagent", {
          hasPendingApprovals: true,
          lineage: {
            parentThreadId: ThreadId.make("approval"),
            relationshipToParent: "subagent",
            rootThreadId: ThreadId.make("approval"),
          },
        }),
        thread("ready"),
      ],
      new Map([[`${env}:parked`, stop]]),
      describeStop,
      new Set(),
    );
    expect(entries.map((entry) => [entry.thread.id, entry.status, entry.summary])).toEqual([
      ["approval", "approval", null],
      ["input", "input", null],
      ["parked", "limited", "Limit hit on work"],
      ["limited", "limited", null],
    ]);
    expect(entries[2]?.since).toBe("2026-09-12T08:00:00.000Z");
  });

  it("orders the longest wait first within a status, across environments", () => {
    const other = EnvironmentId.make("env-2");
    const entries = collectNeedsAttention(
      [
        thread("later", { hasPendingUserInput: true, updatedAt: "2026-09-12T10:05:00.000Z" }),
        thread(
          "earlier",
          { hasPendingUserInput: true, updatedAt: "2026-09-12T09:55:00.000Z" },
          other,
        ),
      ],
      new Map(),
      describeStop,
      new Set(),
    );
    expect(entries.map((entry) => entry.thread.id)).toEqual(["earlier", "later"]);
  });
});

describe("resolveAttentionRank (#270 C)", () => {
  it("ranks approval, input, limit, failure, then an unseen completion", () => {
    expect(resolveAttentionRank({ status: "approval", isUnread: false })).toBe(0);
    expect(resolveAttentionRank({ status: "input", isUnread: false })).toBe(1);
    expect(resolveAttentionRank({ status: "limited", isUnread: false })).toBe(2);
    expect(resolveAttentionRank({ status: "failed", isUnread: false })).toBe(3);
    expect(resolveAttentionRank({ status: "ready", isUnread: true })).toBe(4);
    expect(resolveAttentionRank({ status: "ready", isUnread: false })).toBeNull();
    expect(resolveAttentionRank({ status: "working", isUnread: true })).toBeNull();
    expect(resolveAttentionRank({ status: "waiting", isUnread: true })).toBeNull();
  });
});

describe("resolveNextAttentionThreadId (#270 C)", () => {
  const entries = [
    { id: "a", rank: 1 },
    { id: "b", rank: null },
    { id: "c", rank: 0 },
    { id: "d", rank: 1 },
    { id: "e", rank: 4 },
  ];

  it("lands on the lowest rank, wherever it sits", () => {
    expect(resolveNextAttentionThreadId({ entries, currentThreadId: null })).toBe("c");
    expect(resolveNextAttentionThreadId({ entries, currentThreadId: "e" })).toBe("c");
  });

  it("walks the ties in sidebar order after the current thread and wraps", () => {
    const ties = [
      { id: "a", rank: 1 },
      { id: "b", rank: 1 },
      { id: "c", rank: 1 },
    ];
    expect(resolveNextAttentionThreadId({ entries: ties, currentThreadId: "b" })).toBe("c");
    expect(resolveNextAttentionThreadId({ entries: ties, currentThreadId: "c" })).toBe("a");
  });

  it("never answers the current thread and answers null when nothing waits", () => {
    expect(
      resolveNextAttentionThreadId({ entries: [{ id: "a", rank: 0 }], currentThreadId: "a" }),
    ).toBeNull();
    expect(
      resolveNextAttentionThreadId({ entries: [{ id: "a", rank: null }], currentThreadId: null }),
    ).toBeNull();
  });
});
