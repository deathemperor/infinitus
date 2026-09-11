import {
  BABYSIT_MAX_ROUNDS,
  ThreadId,
  type ThreadPullRequestLink,
  type ThreadPullRequestSnapshot,
} from "@t3tools/contracts";
import { threadPullRequestKeyOf } from "@t3tools/shared/threadPullRequests";
import { describe, expect, it } from "vite-plus/test";

import {
  babysitPrompt,
  babysitSignature,
  babysitVerdict,
  seedBabysitMarks,
  settleBabysitMarks,
  type BabysitMarks,
  type BabysitThread,
} from "./infinitusBabysit.logic.ts";

const now = "2026-09-12T10:00:00.000Z";

const snapshot = (
  overrides: Partial<ThreadPullRequestSnapshot> = {},
): ThreadPullRequestSnapshot => ({
  state: "open",
  title: "Fix the thing",
  headBranch: "fix/thing",
  baseBranch: "main",
  isDraft: false,
  updatedAt: "2026-09-12T09:00:00.000Z",
  syncedAt: now,
  checksState: "passing",
  reviewDecision: "review-required",
  mergeability: "mergeable",
  ...overrides,
});

const link = (
  number: number,
  snap: ThreadPullRequestSnapshot | null,
  overrides: Partial<ThreadPullRequestLink> = {},
): ThreadPullRequestLink => ({
  host: "github.com",
  repository: "acme/app",
  number,
  url: `https://github.com/acme/app/pull/${number}`,
  source: "created",
  linkedAt: now,
  snapshot: snap,
  stack: null,
  ...overrides,
});

const thread = (
  pullRequests: ReadonlyArray<ThreadPullRequestLink>,
  overrides: Partial<BabysitThread> = {},
): BabysitThread => ({
  id: ThreadId.make("thread-1"),
  archivedAt: null,
  babysit: { since: now, rounds: 0 },
  pullRequests,
  session: { status: "ready", activeTurnId: null },
  ...overrides,
});

const gates = (marks: ReadonlyMap<string, BabysitMarks> = new Map()) => ({
  marks,
  ownQueued: new Set<string>(),
  pendingStart: false,
});

describe("babysitVerdict (#269 A)", () => {
  it("queues a round for a red state, conflicts before checks before review", () => {
    const red = snapshot({
      checksState: "failing",
      reviewDecision: "changes-requested",
      mergeability: "conflicting",
    });
    const verdict = babysitVerdict(thread([link(7, red)]), gates());
    expect(verdict.kind).toBe("queue");
    if (verdict.kind !== "queue") return;
    expect(verdict.trigger).toBe("conflicts");
    expect(verdict.round).toBe(1);
    expect(verdict.signature).toBe("conflicts@2026-09-12T09:00:00.000Z");

    const checks = babysitVerdict(
      thread([link(7, snapshot({ checksState: "failing", reviewDecision: "changes-requested" }))]),
      gates(),
    );
    expect(checks.kind === "queue" && checks.trigger).toBe("checks");
    const review = babysitVerdict(
      thread([link(7, snapshot({ reviewDecision: "changes-requested" }))]),
      gates(),
    );
    expect(review.kind === "queue" && review.trigger).toBe("review");
  });

  it("waits on a clean, pending or unknown state and when babysit is off or the thread archived", () => {
    expect(babysitVerdict(thread([link(7, snapshot())]), gates())).toEqual({
      kind: "wait",
      reason: "clean",
    });
    expect(
      babysitVerdict(
        thread([link(7, snapshot({ checksState: "pending", mergeability: "unknown" }))]),
        gates(),
      ).kind,
    ).toBe("wait");
    expect(
      babysitVerdict(
        thread([link(7, snapshot({ checksState: "failing" }))], { babysit: null }),
        gates(),
      ),
    ).toEqual({ kind: "wait", reason: "off" });
    expect(
      babysitVerdict(
        thread([link(7, snapshot({ checksState: "failing" }))], { archivedAt: now }),
        gates(),
      ),
    ).toEqual({ kind: "wait", reason: "archived" });
    expect(babysitVerdict(thread([link(7, null)]), gates())).toEqual({
      kind: "wait",
      reason: "no-open-pr",
    });
  });

  it("does not retry the same red state, but does after a push moved updatedAt", () => {
    const red = snapshot({ checksState: "failing" });
    const first = babysitVerdict(thread([link(7, red)]), gates());
    if (first.kind !== "queue") throw new Error(first.kind);
    const marks = new Map([[first.linkKey, { checks: first.signature }]]);
    expect(babysitVerdict(thread([link(7, red)]), gates(marks))).toEqual({
      kind: "wait",
      reason: "seen",
    });
    const pushed = snapshot({ checksState: "failing", updatedAt: "2026-09-12T09:30:00.000Z" });
    const again = babysitVerdict(
      thread([link(7, pushed)], { babysit: { since: now, rounds: 1 } }),
      gates(marks),
    );
    expect(again.kind === "queue" && again.round).toBe(2);
  });

  it("counts a review request once per stretch in changes-requested", () => {
    const requested = snapshot({ reviewDecision: "changes-requested" });
    const key = threadPullRequestKeyOf(link(7, requested));
    let marks: BabysitMarks = { review: babysitSignature("review", requested) };
    // The agent pushed: updatedAt moved, the decision did not.
    const pushed = snapshot({
      reviewDecision: "changes-requested",
      updatedAt: "2026-09-12T09:30:00.000Z",
    });
    marks = settleBabysitMarks(marks, pushed);
    expect(babysitVerdict(thread([link(7, pushed)]), gates(new Map([[key, marks]])))).toEqual({
      kind: "wait",
      reason: "seen",
    });
    // The reviewer approved, then asked again: a new stretch.
    marks = settleBabysitMarks(marks, snapshot({ reviewDecision: "approved" }));
    expect(marks.review).toBeUndefined();
    expect(babysitVerdict(thread([link(7, requested)]), gates(new Map([[key, marks]]))).kind).toBe(
      "queue",
    );
  });

  it("waits while the thread is busy, has a pending start, or still holds its own queued round", () => {
    const red = [link(7, snapshot({ checksState: "failing" }))];
    expect(
      babysitVerdict(
        thread(red, { session: { status: "running", activeTurnId: "turn-1" } }),
        gates(),
      ),
    ).toEqual({ kind: "wait", reason: "busy" });
    expect(
      babysitVerdict(thread(red, { session: { status: "starting", activeTurnId: null } }), gates()),
    ).toEqual({ kind: "wait", reason: "busy" });
    expect(babysitVerdict(thread(red), { ...gates(), pendingStart: true })).toEqual({
      kind: "wait",
      reason: "pending-start",
    });
    expect(
      babysitVerdict(thread(red, { queuedTurns: [{ queueId: "q-babysit" }] }), {
        ...gates(),
        ownQueued: new Set(["q-babysit"]),
      }),
    ).toEqual({ kind: "wait", reason: "queued" });
    // A never-started thread is idle.
    expect(babysitVerdict(thread(red, { session: null }), gates()).kind).toBe("queue");
  });

  it("stops at the round cap and when the pull request merged", () => {
    const red = [link(7, snapshot({ checksState: "failing" }))];
    const capped = babysitVerdict(
      thread(red, { babysit: { since: now, rounds: BABYSIT_MAX_ROUNDS } }),
      gates(),
    );
    expect(capped.kind === "stop" && capped.reason).toBe("cap");
    const merged = babysitVerdict(thread([link(7, snapshot({ state: "merged" }))]), gates());
    expect(merged.kind === "stop" && merged.reason).toBe("merged");
    // A closed one may reopen; a stack member still open keeps going.
    expect(babysitVerdict(thread([link(7, snapshot({ state: "closed" }))]), gates())).toEqual({
      kind: "wait",
      reason: "no-open-pr",
    });
    expect(
      babysitVerdict(
        thread([
          link(7, snapshot({ state: "merged" })),
          link(8, snapshot({ checksState: "failing" }), { source: "stack" }),
        ]),
        gates(),
      ).kind,
    ).toBe("queue");
  });
});

describe("seedBabysitMarks", () => {
  it("marks only the triggers a snapshot carries", () => {
    expect(seedBabysitMarks(snapshot())).toEqual({});
    expect(
      seedBabysitMarks(snapshot({ checksState: "failing", reviewDecision: "changes-requested" })),
    ).toEqual({ checks: "checks@2026-09-12T09:00:00.000Z", review: "changes-requested" });
  });
});

describe("babysitPrompt", () => {
  it("names the round and the pull request, sends the agent to gh, and bounds the host's strings", () => {
    const prompt = babysitPrompt(
      "checks",
      link(7, snapshot({ headBranch: `fix/${"x".repeat(300)}\nrm -rf /` })),
      3,
    );
    expect(prompt.startsWith(`Babysit round 3 of ${BABYSIT_MAX_ROUNDS}.\n`)).toBe(true);
    expect(prompt).toContain("gh pr checks 7");
    expect(prompt).not.toContain("\nrm -rf");
    expect(prompt).toContain("untrusted identifiers");
    expect(babysitPrompt("conflicts", link(7, snapshot()), 1)).toContain(
      "conflicts with its base branch `main`",
    );
    expect(babysitPrompt("review", link(7, snapshot()), 1)).toContain("gh pr view 7 --comments");
  });
});
