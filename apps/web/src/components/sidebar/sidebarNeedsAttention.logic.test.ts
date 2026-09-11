import { EnvironmentId, ThreadId } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import type { SidebarThreadSummary } from "../../types";
import { collectNeedsAttention } from "./sidebarNeedsAttention.logic";

const env = EnvironmentId.make("env-1");
const other = EnvironmentId.make("env-2");

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
    session: null,
    backgroundLiveness: null,
    updatedAt: "2026-09-12T10:00:00.000Z",
    ...overrides,
  } as SidebarThreadSummary;
}

describe("collectNeedsAttention (#269 D)", () => {
  it("lists only blocked threads: approvals, then input, then holds, then limits", () => {
    const holds = new Map([
      [
        env,
        [
          { threadId: ThreadId.make("held"), since: "2026-09-12T09:00:00.000Z", summary: "Held" },
          {
            threadId: ThreadId.make("limited"),
            since: "2026-09-12T08:00:00.000Z",
            summary: "Limit hit",
            kind: "limited" as const,
          },
        ],
      ],
    ]);
    const entries = collectNeedsAttention(
      [
        thread("limited"),
        thread("working", { session: { status: "running" } as SidebarThreadSummary["session"] }),
        thread("held"),
        thread("input", { hasPendingUserInput: true }),
        thread("failed", { session: { status: "error" } as SidebarThreadSummary["session"] }),
        thread("approval", { hasPendingApprovals: true }),
        thread("ready"),
      ],
      holds,
    );
    expect(entries.map((entry) => [entry.thread.id, entry.status])).toEqual([
      ["approval", "approval"],
      ["input", "input"],
      ["held", "held"],
      ["limited", "limited"],
    ]);
    expect(entries[2]?.since).toBe("2026-09-12T09:00:00.000Z");
    expect(entries[2]?.summary).toBe("Held");
    expect(entries[0]?.since).toBe("2026-09-12T10:00:00.000Z");
    expect(entries[0]?.summary).toBeNull();
  });

  it("puts the longest wait first within a status and reads holds per environment", () => {
    const holds = new Map([
      [
        other,
        [{ threadId: ThreadId.make("b"), since: "2026-09-12T07:00:00.000Z", summary: "Held" }],
      ],
      [env, null],
    ]);
    const entries = collectNeedsAttention(
      [
        thread("a", { hasPendingApprovals: true, updatedAt: "2026-09-12T10:05:00.000Z" }),
        thread("b", {}, other),
        // Same id on the other environment: no hold there, so a plain row.
        thread("b"),
        thread("c", { hasPendingApprovals: true, updatedAt: "2026-09-12T09:30:00.000Z" }),
      ],
      holds,
    );
    expect(entries.map((entry) => `${entry.thread.environmentId}:${entry.thread.id}`)).toEqual([
      "env-1:c",
      "env-1:a",
      "env-2:b",
    ]);
  });
});
