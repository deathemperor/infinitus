import { describe, expect, it } from "vite-plus/test";

import type { ThreadPullRequestLink } from "@t3tools/contracts";

import {
  prChecksUrl,
  prHeaderLabel,
  prHeaderMenuItems,
  prPhaseLabel,
  prReadyForReview,
  threadReadyForReview,
} from "./prHeader.logic";

const link = (
  snapshot: Partial<NonNullable<ThreadPullRequestLink["snapshot"]>> | null,
): ThreadPullRequestLink => ({
  host: "github.com",
  repository: "o/r",
  number: 12,
  url: "https://github.com/o/r/pull/12",
  source: "manual",
  linkedAt: "2026-09-12T00:00:00.000Z",
  snapshot:
    snapshot === null
      ? null
      : {
          state: "open",
          title: "t",
          headBranch: "h",
          baseBranch: "main",
          isDraft: false,
          updatedAt: null,
          syncedAt: "2026-09-12T00:00:00.000Z",
          ...snapshot,
        },
  stack: null,
});

describe("prPhaseLabel", () => {
  it("names the terminal states before anything else", () => {
    expect(prPhaseLabel({ state: "merged", isDraft: true, checksState: "failing" })).toBe("Merged");
    expect(prPhaseLabel({ state: "closed", reviewDecision: "approved" })).toBe("Closed");
    expect(prPhaseLabel({ state: null })).toBe("Status pending");
  });

  it("orders conflict, draft, checks, review the way the web's primary control does", () => {
    expect(prPhaseLabel({ state: "open", mergeability: "conflicting", isDraft: true })).toBe(
      "Conflicts",
    );
    expect(prPhaseLabel({ state: "open", isDraft: true, checksState: "failing" })).toBe("Draft");
    expect(
      prPhaseLabel({ state: "open", checksState: "failing", reviewDecision: "approved" }),
    ).toBe("Checks failing");
    expect(prPhaseLabel({ state: "open", checksState: "pending" })).toBe("Checks running");
    expect(
      prPhaseLabel({ state: "open", checksState: "passing", reviewDecision: "approved" }),
    ).toBe("Approved");
    expect(prPhaseLabel({ state: "open", reviewDecision: "changes-requested" })).toBe(
      "Changes requested",
    );
  });

  it("calls an open, non-draft PR with green or unknown checks and no verdict ready for review", () => {
    expect(prPhaseLabel({ state: "open", checksState: "passing" })).toBe("Ready for review");
    expect(prPhaseLabel({ state: "open", reviewDecision: "review-required" })).toBe(
      "Ready for review",
    );
    expect(prReadyForReview({ state: "open", isDraft: false })).toBe(true);
    expect(prReadyForReview({ state: "open", isDraft: true })).toBe(false);
    expect(prReadyForReview({ state: "merged" })).toBe(false);
  });
});

describe("prChecksUrl", () => {
  it("points at GitHub's checks tab and nowhere else", () => {
    expect(prChecksUrl("https://github.com/o/r/pull/12")).toBe(
      "https://github.com/o/r/pull/12/checks",
    );
    expect(prChecksUrl("https://github.com/o/r/pull/12/?diff=split#top")).toBe(
      "https://github.com/o/r/pull/12/checks",
    );
    expect(prChecksUrl("https://github.corp.example/o/r/pull/7")).toBe(
      "https://github.corp.example/o/r/pull/7/checks",
    );
    expect(prChecksUrl("https://gitlab.com/o/r/-/merge_requests/3")).toBeNull();
    expect(prChecksUrl("https://example.test/o/r/pull/1")).toBeNull();
    expect(prChecksUrl("not a url")).toBeNull();
  });
});

describe("prHeaderMenuItems", () => {
  it("always opens the PR, adds checks when the host has a page, and mark-ready for an actionable draft", () => {
    expect(
      prHeaderMenuItems({
        pr: { state: "open", isDraft: true, checksState: "pending" },
        checksUrl: "https://github.com/o/r/pull/12/checks",
        canRunActions: true,
      }).map((item) => [item.action, item.description]),
    ).toEqual([
      ["open", "In the browser"],
      ["checks", "Checks are still running"],
      ["ready", "Takes the pull request out of draft"],
    ]);
  });

  it("keeps mark-ready off a non-draft, a closed PR, and a server without PR actions", () => {
    const actions = (input: Parameters<typeof prHeaderMenuItems>[0]) =>
      prHeaderMenuItems(input).map((item) => item.action);
    expect(
      actions({ pr: { state: "open", isDraft: false }, checksUrl: null, canRunActions: true }),
    ).toEqual(["open"]);
    expect(
      actions({ pr: { state: "closed", isDraft: true }, checksUrl: null, canRunActions: true }),
    ).toEqual(["open"]);
    expect(
      actions({ pr: { state: "open", isDraft: true }, checksUrl: null, canRunActions: false }),
    ).toEqual(["open"]);
  });

  it("describes the checks item by the rollup", () => {
    const describe = (checksState: "passing" | "failing" | null) =>
      prHeaderMenuItems({
        pr: { state: "open", checksState },
        checksUrl: "https://github.com/o/r/pull/1/checks",
        canRunActions: false,
      })[1]!.description;
    expect(describe("passing")).toBe("All checks passed");
    expect(describe("failing")).toBe("Some checks failed");
    expect(describe(null)).toBe("On the host");
  });

  it("labels the header item by number", () => {
    expect(prHeaderLabel(42)).toBe("#42");
  });
});

describe("threadReadyForReview", () => {
  it("reads the current link's snapshot", () => {
    expect(threadReadyForReview([link({ checksState: "passing" })], true)).toBe(true);
    expect(threadReadyForReview([link({})], true)).toBe(true);
    expect(threadReadyForReview([link({ isDraft: true })], true)).toBe(false);
    expect(threadReadyForReview([link({ checksState: "pending" })], true)).toBe(false);
    expect(threadReadyForReview([link({ reviewDecision: "approved" })], true)).toBe(false);
    expect(threadReadyForReview([link({ state: "merged" })], true)).toBe(false);
  });

  it("is never ready without a synced link or the capability", () => {
    expect(threadReadyForReview([link(null)], true)).toBe(false);
    expect(threadReadyForReview([], true)).toBe(false);
    expect(threadReadyForReview([link({ checksState: "passing" })], false)).toBe(false);
  });
});
