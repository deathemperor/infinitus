import { ApprovalRequestId, ThreadId, type OrchestrationProjectShell } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import {
  activityLine,
  approvalMessage,
  doneText,
  MAX_DONE_TEXT_LENGTH,
  parseAction,
  parseMention,
  projectsReply,
  questionMessage,
  replyCommand,
  resolveSlackProject,
  threadTitle,
} from "./infinitusSlack.logic.ts";

const project = (id: string, title: string, root: string) =>
  ({ id, title, workspaceRoot: root, defaultModelSelection: null }) as OrchestrationProjectShell;
const projects = [project("p1", "Limitless", "/w/limitless"), project("p2", "Site", "/w/site")];
const threadId = ThreadId.make("t1");
const requestId = ApprovalRequestId.make("r1");

describe("parseMention (#574)", () => {
  it("strips the bot mention, reads the project, the build word and the task", () => {
    expect(parseMention("<@U0BOT> limitless  fix the flaky test")).toEqual({
      projectHandle: "limitless",
      runtimeMode: "approval-required",
      task: "fix the flaky test",
    });
    expect(parseMention("limitless build ship it <@U0BOT|infinitus>")).toEqual({
      projectHandle: "limitless",
      runtimeMode: "auto-accept-edits",
      task: "ship it",
    });
    expect(parseMention("<@U0BOT> limitless")).toBeNull();
    expect(parseMention("<@U0BOT>")).toBeNull();
  });
});

describe("resolveSlackProject", () => {
  it("matches id, then title, then folder, case-insensitively", () => {
    expect(resolveSlackProject(projects, "P2")?.id).toBe("p2");
    expect(resolveSlackProject(projects, "limitless")?.id).toBe("p1");
    expect(resolveSlackProject(projects, "SITE")?.id).toBe("p2");
    expect(resolveSlackProject(projects, "nope")).toBeNull();
    expect(projectsReply(projects)).toBe("Which project? Start with one of: `limitless`, `site`.");
  });
});

describe("replyCommand / threadTitle", () => {
  it("reads stop and babysit, keeps anything else as a message", () => {
    expect(replyCommand("<@U0BOT> Stop")).toEqual({ kind: "stop" });
    expect(replyCommand("babysit")).toEqual({ kind: "babysit" });
    expect(replyCommand("also add tests")).toEqual({ kind: "message", text: "also add tests" });
    expect(replyCommand("<@U0BOT>")).toBeNull();
    expect(threadTitle("first line\nsecond")).toBe("first line");
    expect(threadTitle("x".repeat(100))).toHaveLength(80);
    expect(threadTitle("  ")).toBe("Slack task");
  });
});

describe("buttons round-trip through the action id", () => {
  it("approval: three decisions, nothing else", () => {
    const message = approvalMessage({
      threadId,
      requestId,
      requestType: "command_execution_approval",
      detail: "rm -rf build",
    });
    expect(message.text).toBe("Approval needed: rm -rf build");
    const actions = message.blocks?.[1] as {
      elements: Array<{ action_id: string; value: string }>;
    };
    expect(actions.elements.map((element) => element.value)).toEqual([
      "accept",
      "acceptForSession",
      "decline",
    ]);
    expect(parseAction(actions.elements[0]!.action_id, "decline")).toEqual({
      kind: "approval",
      threadId,
      requestId,
      decision: "decline",
    });
    expect(parseAction(actions.elements[0]!.action_id, "acceptAlways")).toBeNull();
    expect(parseAction("other:approval:t1:r1", "accept")).toBeNull();
  });

  it("question: the first question's options, values falling back to labels", () => {
    const message = questionMessage({
      threadId,
      requestId,
      questions: [
        { id: "q:1", question: "Which?", options: [{ label: "A", value: "a" }, { label: "B" }] },
      ],
    });
    const actions = message.blocks?.[1] as {
      elements: Array<{ action_id: string; value: string }>;
    };
    expect(actions.elements.map((element) => element.value)).toEqual(["a", "B"]);
    expect(parseAction(actions.elements[1]!.action_id, "B")).toEqual({
      kind: "answer",
      threadId,
      requestId,
      questionId: "q:1",
      answer: "B",
    });
  });
});

describe("doneText / activityLine", () => {
  it("trims the assistant text to the cap and appends the PR link", () => {
    const text = doneText({
      state: "completed",
      assistantText: "y".repeat(2000),
      pullRequestUrl: "https://x/pr/1",
    });
    const lines = text.split("\n");
    expect(lines[0]).toBe("Done.");
    expect(lines[1]).toHaveLength(MAX_DONE_TEXT_LENGTH);
    expect(lines[2]).toBe("PR: https://x/pr/1");
    expect(doneText({ state: "error", assistantText: null, pullRequestUrl: null })).toBe("Failed.");
  });

  it("maps fork activity kinds to fixed lines and nothing else", () => {
    expect(activityLine("infinitus.thread.limited")).toBe(
      "Stopped on a usage limit; resumes when an account is free.",
    );
    expect(activityLine("babysit.done")).toContain("merged");
    expect(activityLine("approval.requested")).toBeNull();
  });
});
