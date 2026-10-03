import {
  ContextHandoffId,
  MessageId,
  CheckpointId,
  CheckpointScopeId,
  RuntimeRequestId,
  NodeId,
  PlanId,
  ProviderInstanceId,
  ProviderDriverKind,
  ProviderThreadId,
  ProviderTurnId,
  RunId,
  RunAttemptId,
  ScheduledTaskId,
  ThreadId,
  TurnItemId,
  type OrchestrationV2RunAttempt,
  type OrchestrationV2ProjectedTurnItem,
  type OrchestrationV2TurnItem,
} from "@infinitus/contracts";
import { resolveUserMessagePresentation } from "@infinitus/client-runtime/user-message";
import { summarizeToolGroup } from "@infinitus/client-runtime/work-log/presentation";
import * as DateTime from "effect/DateTime";
import { describe, expect, it } from "vite-plus/test";

import {
  workEntryRowLabel,
  isContextHandoffActivityGroup,
  buildThreadFeed,
  deriveThreadFeedPresentation,
  threadFeedActivityIsVisible,
  threadFeedRunIsUnsettled,
  type ThreadFeedActivity,
  type ThreadFeedEntry,
  togglePendingUserInputOptionSelection,
  setPendingUserInputCustomAnswer,
  isPendingUserInputOptionSelected,
  buildPendingUserInputAnswers,
} from "./threadActivity";

const threadId = ThreadId.make("thread-1");
const sourceThreadId = ThreadId.make("thread-source");
const runId = RunId.make("run-1");

it("keeps historical plan detail accessible from its paged turn item", () => {
  const item = {
    ...base("historical-plan", "2026-08-29T00:00:00.000Z", 1),
    type: "proposed_plan",
    planId: "plan-historical",
    markdown: "Full historical plan text",
    streaming: false,
  } as OrchestrationV2TurnItem;

  const entries = buildThreadFeed([projected(item, 0)]);
  const activity = entries.flatMap((entry) =>
    entry.type === "activity-group" ? entry.activities : [],
  )[0];
  expect(activity?.detail).toBe("Full historical plan text");
  expect(activity?.getFullDetail()).toContain("Full historical plan text");
});

it("shows only the structured path in expanded mobile read details", () => {
  const item: OrchestrationV2TurnItem = {
    ...base("read-detail", "2026-06-20T00:00:03.000Z", 2),
    type: "dynamic_tool",
    toolName: "Read",
    title: "Read src/env.ts",
    input: { path: "src/env.ts" },
    output: "---\nname: env\n---\nsecret content",
  };
  const activity = buildThreadFeed([projected(item, 0)]).flatMap((entry) =>
    entry.type === "activity-group" ? entry.activities : [],
  )[0];

  expect(activity?.getFullDetail()).toBe("src/env.ts");
  expect(activity?.canExpand).toBe(true);
  expect(activity?.getCopyText()).not.toContain("secret content");
  expect(activity?.getFullDetail()).not.toContain("sourceThreadId");

  const withoutPath = buildThreadFeed([
    projected({ ...item, id: TurnItemId.make("read-without-path"), input: {} }, 0),
  ]).flatMap((entry) => (entry.type === "activity-group" ? entry.activities : []))[0];
  expect(withoutPath?.getFullDetail()).toBeNull();
  expect(withoutPath?.canExpand).toBe(false);
});

it("labels file searches with the adapter title and its search target", () => {
  const item: OrchestrationV2TurnItem = {
    ...base("file-search", "2026-06-20T00:00:03.000Z", 2),
    type: "file_search",
    title: "Searched TODO in web",
    pattern: "TODO",
  };
  const activity = buildThreadFeed([projected(item, 0)]).flatMap((entry) =>
    entry.type === "activity-group" ? entry.activities : [],
  )[0];

  expect(activity?.summary).toBe("Searched TODO in web");
  expect(activity ? workEntryRowLabel(activity.workEntry) : null).toBe("Searched TODO in web");
});

it("keeps approval prompts rather than presenting them as tool work", () => {
  const approval = (
    id: string,
    requestKind: "file-read" | "command" | "file-change",
    ordinal: number,
  ) =>
    ({
      ...base(id, `2026-06-20T00:00:0${ordinal}.000Z`, ordinal),
      type: "approval_request",
      requestId: RuntimeRequestId.make(`request-${id}`),
      requestKind,
      prompt: `Allow ${requestKind}?`,
    }) satisfies OrchestrationV2TurnItem;
  const feed = buildThreadFeed([
    projected(approval("approve-read", "file-read", 1), 0),
    projected(approval("approve-command", "command", 2), 1),
    projected(approval("approve-edit", "file-change", 3), 2),
  ]);
  const activities = feed.flatMap((entry) =>
    entry.type === "activity-group" ? entry.activities : [],
  );

  expect(activities.map((activity) => workEntryRowLabel(activity.workEntry))).toEqual([
    "Allow file-read?",
    "Allow command?",
    "Allow file-change?",
  ]);
  expect(activities[0]?.canExpand).toBe(true);
  expect(
    summarizeToolGroup(activities.slice(1).map((activity) => activity.workEntry)).summary,
  ).not.toMatch(/Ran|changed/);
});

function base(id: string, updatedAt: string, ordinal: number) {
  const timestamp = DateTime.makeUnsafe(updatedAt);
  return {
    id: TurnItemId.make(id),
    threadId,
    runId,
    nodeId: null,
    providerThreadId: null,
    providerTurnId: null,
    nativeItemRef: null,
    parentItemId: null,
    ordinal,
    status: "completed" as const,
    title: null,
    startedAt: timestamp,
    completedAt: timestamp,
    updatedAt: timestamp,
  };
}

function projected(
  item: OrchestrationV2TurnItem,
  position: number,
  visibility: OrchestrationV2ProjectedTurnItem["visibility"] = "local",
): OrchestrationV2ProjectedTurnItem {
  return {
    position,
    visibility,
    sourceThreadId: visibility === "local" ? threadId : sourceThreadId,
    sourceItemId: item.id,
    item,
  };
}

function userMessage(updatedAt = "2026-06-20T00:00:01.000Z") {
  return {
    ...base("item-user", updatedAt, 0),
    type: "user_message" as const,
    messageId: MessageId.make("message-user"),
    createdBy: "user" as const,
    creationSource: "mobile" as const,
    inputIntent: "turn_start" as const,
    text: "Run checks",
    attachments: [],
  };
}

function command(updatedAt = "2026-06-20T00:00:02.000Z") {
  return {
    ...base("item-command", updatedAt, 1),
    type: "command_execution" as const,
    input: "vp check",
    output: "ok",
    exitCode: 0,
  };
}

function assistantMessage(updatedAt = "2026-06-20T00:00:03.000Z") {
  return {
    ...base("item-assistant", updatedAt, 2),
    type: "assistant_message" as const,
    messageId: MessageId.make("message-assistant"),
    text: "Done",
    streaming: false,
  };
}

describe("buildThreadFeed", () => {
  it("keeps async answers in question history instead of user bubbles", () => {
    const requestId = RuntimeRequestId.make("question");
    const question: OrchestrationV2TurnItem = {
      ...base("question", "2026-06-20T00:00:01.000Z", 0),
      type: "user_input_request",
      requestId,
      questions: [],
      questionAnswer: { requestId, answers: { color: "Blue" }, attachmentsByQuestionId: {} },
    };
    const reply: OrchestrationV2TurnItem = {
      ...userMessage(),
      id: TurnItemId.make("answer"),
      messageId: MessageId.make(`async-answer:${requestId}`),
    };
    const feed = buildThreadFeed([projected(question, 0), projected(reply, 1)]);
    expect(feed).toHaveLength(1);
    expect(feed[0]).toMatchObject({
      type: "activity-group",
      activities: [{ workEntry: { questionAnswer: question.questionAnswer } }],
    });
    expect(buildThreadFeed([projected(reply, 0)])[0]?.type).toBe("message");
  });

  it("does not create a work group for a message and checkpoint", () => {
    const checkpoint: OrchestrationV2TurnItem = {
      ...base("checkpoint", "2026-06-20T00:00:04.000Z", 3),
      type: "checkpoint",
      checkpointId: CheckpointId.make("checkpoint"),
      scopeId: CheckpointScopeId.make("scope"),
      files: [],
    };
    const feed = buildThreadFeed([projected(assistantMessage(), 0), projected(checkpoint, 1)]);
    expect(feed.map((entry) => entry.type)).toEqual(["message"]);
  });

  it("omits cached tool output and patch bodies from expanded and copied activity", () => {
    const rawOutput = "RAW_TOOL_OUTPUT";
    const items: OrchestrationV2TurnItem[] = [
      { ...command(), output: rawOutput },
      {
        ...base("dynamic-output", "2026-06-20T00:00:03.000Z", 2),
        type: "dynamic_tool",
        toolName: "example",
        input: { query: "keep input" },
        output: { text: rawOutput },
      },
      {
        ...base("file-output", "2026-06-20T00:00:04.000Z", 3),
        type: "file_change",
        fileName: "src/example.ts",
        diffStr: rawOutput,
        oldStr: rawOutput,
        newStr: rawOutput,
      },
    ];
    const activities = buildThreadFeed(items.map((item, index) => projected(item, index))).flatMap(
      (entry) => (entry.type === "activity-group" ? entry.activities : []),
    );
    expect(activities).toHaveLength(3);
    for (const activity of activities) {
      expect(activity.workEntry.detail).toBeUndefined();
      expect(activity.getFullDetail()).not.toContain(rawOutput);
      expect(activity.getCopyText()).not.toContain(rawOutput);
    }
    expect(activities[0]?.detail).toBe("vp check");
    expect(activities[1]?.getFullDetail()).toContain("keep input");
    expect(activities[2]?.detail).toBe("src/example.ts");
    expect(items[0]).toMatchObject({ output: rawOutput });
  });

  it("recognizes automation attribution after projecting a user message", () => {
    const feed = buildThreadFeed([
      projected(
        {
          ...userMessage(),
          createdBy: "agent",
          creationSource: "server",
          scheduledTaskId: ScheduledTaskId.make("daily-audit"),
        },
        0,
      ),
    ]);
    const messageEntry = feed.find((entry) => entry.type === "message");

    expect(messageEntry).toBeDefined();
    expect(resolveUserMessagePresentation(messageEntry!.message)).toMatchObject({
      text: "Run checks",
      isAutomation: true,
    });
  });

  it("keeps the sender of an agent message distinct from its timeline source", () => {
    const feed = buildThreadFeed([
      projected(
        {
          ...userMessage(),
          createdBy: "agent",
          creationSource: "mcp",
          senderThreadId: sourceThreadId,
        },
        0,
      ),
    ]);
    const messageEntry = feed.find((entry) => entry.type === "message");
    expect(messageEntry?.message.senderThreadId).toBe(sourceThreadId);
    expect(messageEntry?.message.sourceThreadId).toBe(threadId);
  });

  it("anchors feedback before later committed turns", () => {
    const laterUser = {
      ...userMessage("2026-08-29T00:00:05.000Z"),
      id: TurnItemId.make("item-later-user"),
      messageId: MessageId.make("message-later-user"),
      ordinal: 2,
      text: "Later user turn",
    };
    const laterAssistant = {
      ...assistantMessage("2026-08-29T00:00:04.000Z"),
      id: TurnItemId.make("item-later-assistant"),
      messageId: MessageId.make("message-later-assistant"),
      ordinal: 3,
      text: "Later assistant turn",
    };
    const localMessage = (id: string, role: "user" | "assistant") => ({
      id: MessageId.make(id),
      role,
      text: id,
      turnId: null,
      streaming: false,
      createdAt: "2026-08-29T00:00:03.000Z",
      updatedAt: "2026-08-29T00:00:03.000Z",
    });
    const feed = buildThreadFeed(
      [
        projected(userMessage("2026-08-29T00:00:01.000Z"), 0),
        projected(laterUser, 1),
        projected(laterAssistant, 2),
      ],
      {
        anchoredMessages: [
          localMessage("feedback-user", "user"),
          localMessage("feedback-assistant", "assistant"),
          localMessage("message-later-user", "user"),
        ],
      },
    );
    const messages = feed.filter((entry) => entry.type === "message");

    expect(messages.map((entry) => entry.id)).toEqual([
      "message-user",
      "feedback-user",
      "feedback-assistant",
      "message-later-user",
      "message-later-assistant",
    ]);
    expect(
      messages
        .filter((entry) => entry.id.startsWith("feedback-"))
        .every((entry) => entry.message.projectedItem === undefined),
    ).toBe(true);
  });

  it("keeps prominent activity visible while it is running", () => {
    expect(
      threadFeedActivityIsVisible({ prominent: true, status: "neutral", toolLike: true }),
    ).toBe(true);
    expect(
      threadFeedActivityIsVisible({ prominent: false, status: "neutral", toolLike: true }),
    ).toBe(false);
  });

  it("keeps provider notices visible outside completed work folds without failure styling", () => {
    const message = "Safeguards flagged this message. Switched to Opus 4.8.";
    const item = {
      ...base("item-system-notice", "2026-06-20T00:00:02.000Z", 1),
      type: "system_notice" as const,
      message,
    };
    const feed = buildThreadFeed([projected(item, 0)]);
    const presented = deriveThreadFeedPresentation(feed, null, new Set());
    const activities = presented.flatMap((entry) =>
      entry.type === "activity-group" ? entry.activities : [],
    );
    expect(activities).toHaveLength(1);
    expect(activities[0]).toMatchObject({
      summary: message,
      detail: message,
      prominent: true,
      toolLike: false,
      status: null,
      icon: "warning",
      workEntry: { tone: "info", itemType: "system_notice" },
    });
    expect(presented.some((entry) => entry.type === "run-fold")).toBe(false);
  });

  it("presents a usage-limit stop as a warning while preserving its explanation", () => {
    const message = "Plan usage limit reached. Try again after reset.";
    const entries = buildThreadFeed([
      projected(
        {
          ...base("item-limit", "2026-06-20T00:00:02.000Z", 1),
          type: "error",
          status: "failed",
          title: "Usage limit reached",
          failure: { class: "usage_limit", message, code: "usageLimitExceeded", retryable: null },
        },
        0,
      ),
    ]);
    const activity = entries.flatMap((entry) =>
      entry.type === "activity-group" ? entry.activities : [],
    )[0];
    expect(activity).toMatchObject({
      summary: "Usage limit reached",
      status: "neutral",
      icon: "warning",
    });
    expect(activity?.getFullDetail()).toContain(message);
  });

  it.each(["transport_error", "usage_limit"] as const)(
    "presents %s retries and clears warning markers on recovery",
    (failureClass) => {
      const retryBase = {
        ...base("item-provider-retry", "2026-06-20T00:00:02.000Z", 1),
        type: "error" as const,
        failure: {
          class: failureClass,
          message: "The response stream disconnected.",
          code: "responseStreamDisconnected",
          retryable: true,
        },
        retry: {
          attempt: 2,
          maxAttempts: 5,
          retryDelayMs: null,
        },
      };
      const runningFeed = buildThreadFeed([
        projected(
          {
            ...retryBase,
            status: "running",
            title: "Provider retry",
            completedAt: null,
          },
          0,
        ),
      ]);
      const recoveredFeed = buildThreadFeed([
        projected(
          {
            ...retryBase,
            status: "completed",
            title: "Provider recovered",
          },
          0,
        ),
      ]);
      if (failureClass === "usage_limit") {
        const recoveredActivity = recoveredFeed.flatMap((entry) =>
          entry.type === "activity-group" ? entry.activities : [],
        )[0];
        expect(recoveredActivity).toMatchObject({ status: "success", icon: "check" });
      }
      const failedFeed = buildThreadFeed([
        projected(
          {
            ...retryBase,
            status: "failed",
            title: "Provider retry failed",
          },
          0,
        ),
        projected(command("2026-06-20T00:00:03.000Z"), 1),
      ]);
      const runningActivity = runningFeed.find((entry) => entry.type === "activity-group")
        ?.activities[0];
      const recoveredActivity = recoveredFeed.find((entry) => entry.type === "activity-group")
        ?.activities[0];
      if (runningActivity === undefined || recoveredActivity === undefined) {
        throw new Error("Expected provider retry work-log activities.");
      }

      expect(runningActivity).toMatchObject({
        summary: "Provider retry",
        status: "neutral",
        toolLike: false,
      });
      expect(threadFeedActivityIsVisible(runningActivity)).toBe(true);
      expect(recoveredActivity).toMatchObject({
        summary: "Provider recovered",
        status: "success",
        toolLike: false,
      });
      const failedPresentation = deriveThreadFeedPresentation(
        failedFeed,
        { runId, status: "running", startedAt: null, completedAt: null },
        new Set(),
      );
      expect(failedPresentation.map((entry) => entry.type)).toEqual([
        "activity-group",
        "activity-group",
      ]);
      expect(
        failedPresentation[0]?.type === "activity-group"
          ? failedPresentation[0].activities[0]?.summary
          : null,
      ).toBe("Provider retry failed");
    },
  );

  it.each(["pending", "running", "completed"] as const)(
    "omits %s task progress without hiding adjacent conversation items",
    (stepStatus) => {
      const todoItem = {
        ...base("item-tasks", "2026-06-20T00:00:02.500Z", 2),
        type: "todo_list" as const,
        planId: PlanId.make("plan-tasks"),
        steps: [{ id: "step-1", text: "Verify the change", status: stepStatus }],
      } satisfies OrchestrationV2TurnItem;
      const user = projected(userMessage(), 0);
      const tool = projected(command(), 1);
      const assistant = projected(assistantMessage(), 3);

      expect(buildThreadFeed([user, tool, projected(todoItem, 2), assistant])).toEqual(
        buildThreadFeed([user, tool, assistant]),
      );
    },
  );

  it("hides synthetic workspace preparation activity", () => {
    const workspacePreparation = projected(
      {
        ...command(),
        title: "Workspace ready",
        input: "Preparing workspace",
        output: "Workspace preparation completed.",
      },
      0,
    );

    expect(buildThreadFeed([workspacePreparation])).toEqual([]);
  });

  it("does not treat a queued-only run as live feed activity", () => {
    expect(
      threadFeedRunIsUnsettled({
        runId,
        status: "queued",
        startedAt: null,
        completedAt: null,
      }),
    ).toBe(false);
    expect(
      threadFeedRunIsUnsettled({
        runId,
        status: "running",
        startedAt: "2026-06-20T00:00:01.000Z",
        completedAt: null,
      }),
    ).toBe(true);
    expect(
      threadFeedRunIsUnsettled({
        runId,
        status: "completed",
        startedAt: "2026-06-20T00:00:01.000Z",
        completedAt: null,
      }),
    ).toBe(true);
    expect(
      threadFeedRunIsUnsettled({
        runId,
        status: "waiting",
        startedAt: "2026-06-20T00:00:01.000Z",
        completedAt: null,
      }),
    ).toBe(true);
  });

  it("adds queued input only after dispatch creates its turn item", () => {
    const dispatchedRunId = RunId.make("run-dispatched-queued");
    const dispatchedMessageId = MessageId.make("message-dispatched-queued");
    expect(buildThreadFeed([])).toEqual([]);

    const promotedEntries = buildThreadFeed([
      projected(
        {
          ...userMessage(),
          id: TurnItemId.make("item-dispatched-queued"),
          runId: dispatchedRunId,
          messageId: dispatchedMessageId,
          inputIntent: "turn_start",
        },
        0,
      ),
    ]);
    expect(promotedEntries.map((entry) => entry.id)).toEqual([dispatchedMessageId]);
    expect(
      promotedEntries[0]?.type === "message" ? promotedEntries[0].message.inputIntent : undefined,
    ).toBe("turn_start");
  });

  it("hides the interruption request and keeps the terminal result", () => {
    const request = projected(
      {
        ...base("item-interrupt-request", "2026-06-20T00:00:02.000Z", 1),
        type: "run_interrupt_request",
        message: "Interrupt requested",
      },
      0,
    );
    const result = projected(
      {
        ...base("item-interrupt-result", "2026-06-20T00:00:03.000Z", 2),
        type: "run_interrupt_result",
        message: "Run interrupted before provider start",
      },
      1,
    );

    const activities = buildThreadFeed([request, result]).flatMap((entry) =>
      entry.type === "activity-group" ? entry.activities : [],
    );

    expect(activities).toHaveLength(1);
    expect(activities[0]?.summary).toBe("Run interrupted");
    expect(activities[0]?.detail).toBe("Run interrupted before provider start");
    expect(
      deriveThreadFeedPresentation(
        buildThreadFeed([request, result]),
        {
          runId,
          status: "interrupted",
          startedAt: "2026-06-20T00:00:01.000Z",
          completedAt: "2026-06-20T00:00:03.000Z",
        },
        new Set(),
      ).some((entry) => entry.type === "run-fold"),
    ).toBe(false);
  });

  it("preserves authoritative V2 order instead of sorting reconstructed collections", () => {
    const rows = [
      projected(userMessage("2026-06-20T00:00:03.000Z"), 0),
      projected(command("2026-06-20T00:00:01.000Z"), 1),
      projected(assistantMessage("2026-06-20T00:00:02.000Z"), 2),
    ];

    const feed = buildThreadFeed(rows);
    expect(feed.map((entry) => entry.type)).toEqual(["message", "activity-group", "message"]);
    expect(feed.map((entry) => entry.id)).toEqual([
      "message-user",
      "local:thread-1:item-command",
      "message-assistant",
    ]);
    const activity = feed.find((entry) => entry.type === "activity-group")?.activities[0];
    expect(activity?.projectedItem).toBe(rows[1]);
    expect(activity?.getFullDetail()).toContain('"input": "vp check"');
  });

  it("keeps adjacent work from different V2 attempts in separate groups", () => {
    const firstRootNodeId = NodeId.make("node-attempt-1");
    const secondRootNodeId = NodeId.make("node-attempt-2");
    const firstCommand = { ...command(), nodeId: firstRootNodeId };
    const secondCommand = {
      ...command("2026-06-20T00:00:03.000Z"),
      id: TurnItemId.make("item-command-retry"),
      ordinal: 2,
      nodeId: secondRootNodeId,
    };
    const attempts = [
      {
        id: RunAttemptId.make("attempt-1"),
        runId,
        attemptOrdinal: 1,
        rootNodeId: firstRootNodeId,
        providerInstanceId: ProviderInstanceId.make("provider-instance-1"),
        providerThreadId: ProviderThreadId.make("provider-thread-1"),
        providerTurnId: null,
        reason: "initial",
        status: "completed",
        startedAt: DateTime.makeUnsafe("2026-06-20T00:00:01.000Z"),
        completedAt: DateTime.makeUnsafe("2026-06-20T00:00:02.000Z"),
      },
      {
        id: RunAttemptId.make("attempt-2"),
        runId,
        attemptOrdinal: 2,
        rootNodeId: secondRootNodeId,
        providerInstanceId: ProviderInstanceId.make("provider-instance-1"),
        providerThreadId: ProviderThreadId.make("provider-thread-1"),
        providerTurnId: null,
        reason: "retry",
        status: "completed",
        startedAt: DateTime.makeUnsafe("2026-06-20T00:00:02.000Z"),
        completedAt: DateTime.makeUnsafe("2026-06-20T00:00:03.000Z"),
      },
    ] satisfies ReadonlyArray<OrchestrationV2RunAttempt>;

    const feed = buildThreadFeed([projected(firstCommand, 0), projected(secondCommand, 1)], {
      attempts,
    });

    expect(feed).toHaveLength(2);
    expect(
      feed.map((entry) =>
        entry.type === "activity-group" ? entry.activities[0]?.attemptId : null,
      ),
    ).toEqual(["attempt-1", "attempt-2"]);
  });

  it("retains inherited and synthetic rows with their original projected identity", () => {
    const inherited = projected(command(), 0, "inherited");
    const { providerThreadId: _providerThreadId, ...forkBase } = base(
      "item-fork",
      "2026-06-20T00:00:03.000Z",
      2,
    );
    const synthetic = projected(
      {
        ...forkBase,
        type: "fork",
        source: { type: "run", threadId: sourceThreadId, runId },
        targetThreadId: threadId,
      },
      1,
      "synthetic",
    );

    const feed = buildThreadFeed([inherited, synthetic]);
    const activities = feed.flatMap((entry) =>
      entry.type === "activity-group" ? entry.activities : [],
    );
    expect(activities.map((activity) => activity.projectedItem)).toEqual([inherited, synthetic]);
    expect(activities.map((activity) => activity.projectedItem.visibility)).toEqual([
      "inherited",
      "synthetic",
    ]);
    expect(activities.at(-1)?.prominent).toBe(true);
  });

  it("keeps orchestration relationship cards visible when a completed run is folded", () => {
    const { providerThreadId: _providerThreadId, ...forkBase } = base(
      "item-fork",
      "2026-06-20T00:00:02.500Z",
      2,
    );
    const feed = buildThreadFeed([
      projected(userMessage(), 0),
      projected(command(), 1),
      projected(
        {
          ...forkBase,
          type: "fork",
          source: { type: "run", threadId, runId },
          targetThreadId: sourceThreadId,
        },
        2,
      ),
      projected(assistantMessage(), 3),
    ]);

    const collapsed = deriveThreadFeedPresentation(
      feed,
      {
        runId,
        status: "completed",
        startedAt: "2026-06-20T00:00:01.000Z",
        completedAt: "2026-06-20T00:00:03.000Z",
      },
      new Set(),
    );

    expect(
      collapsed.some(
        (entry) =>
          entry.type === "activity-group" &&
          entry.activities.some((activity) => activity.projectedItem.item.type === "fork"),
      ),
    ).toBe(true);
    expect(
      collapsed.some(
        (entry) =>
          entry.type === "activity-group" &&
          entry.activities.some(
            (activity) => activity.projectedItem.item.type === "command_execution",
          ),
      ),
    ).toBe(false);
  });

  it("keeps opening and final assistant messages around the first hidden work", () => {
    const opening = {
      ...assistantMessage("2026-06-20T00:00:01.500Z"),
      id: TurnItemId.make("item-opening"),
      messageId: MessageId.make("message-opening"),
      text: "I will check the deployment configuration.",
    };
    const middle = {
      ...assistantMessage("2026-06-20T00:00:02.500Z"),
      id: TurnItemId.make("item-middle"),
      messageId: MessageId.make("message-middle"),
      text: "The configuration is valid; checking the build next.",
    };
    const feed = buildThreadFeed([
      projected(userMessage(), 0),
      projected(opening, 1),
      projected(command(), 2),
      projected(middle, 3),
      projected(assistantMessage(), 4),
    ]);
    const latestRun = {
      runId,
      status: "completed" as const,
      startedAt: "2026-06-20T00:00:01.000Z",
      completedAt: "2026-06-20T00:00:03.000Z",
    };

    const collapsed = deriveThreadFeedPresentation(feed, latestRun, new Set());
    expect(collapsed.map((entry) => entry.id)).toEqual([
      "message-user",
      "message-opening",
      "run-fold:run-1",
      "message-assistant",
    ]);
    expect(collapsed[1]).toMatchObject({ message: { text: opening.text } });
    expect(collapsed[2]).toMatchObject({
      type: "run-fold",
      createdAt: "2026-06-20T00:00:02.000Z",
      label: "Worked for 2.0s",
    });

    const expanded = deriveThreadFeedPresentation(feed, latestRun, new Set([runId]));
    expect(expanded.map((entry) => entry.type)).toEqual([
      "message",
      "message",
      "run-fold",
      "work-toggle",
      "message",
      "message",
    ]);
    expect(expanded[4]).toMatchObject({ message: { id: middle.messageId, text: middle.text } });
  });

  it("does not fold a response that only has opening and final messages", () => {
    const feed = buildThreadFeed([
      projected(userMessage(), 0),
      projected(
        {
          ...assistantMessage("2026-06-20T00:00:02.000Z"),
          id: TurnItemId.make("item-opening"),
          messageId: MessageId.make("message-opening"),
          text: "The result is ready.",
        },
        1,
      ),
      projected(assistantMessage(), 2),
    ]);

    const presented = deriveThreadFeedPresentation(feed, null, new Set());
    expect(presented.map((entry) => entry.id)).toEqual([
      "message-user",
      "message-opening",
      "message-assistant",
    ]);
  });

  it("folds subagents while keeping created-thread and fork cards visible", () => {
    const { providerThreadId: _providerThreadId, ...forkBase } = base(
      "item-fork",
      "2026-06-20T00:00:02.000Z",
      2,
    );
    const resourceItems = [
      {
        ...base("item-subagent", "2026-06-20T00:00:01.500Z", 1),
        type: "subagent",
        subagentId: NodeId.make("child-agent"),
        origin: "app_owned",
        driver: ProviderDriverKind.make("codex"),
        providerInstanceId: ProviderInstanceId.make("codex"),
        childThreadId: sourceThreadId,
        prompt: "Inspect the deployment configuration",
        result: "Configuration is valid",
      },
      {
        ...forkBase,
        type: "fork",
        source: { type: "run", threadId, runId },
        targetThreadId: sourceThreadId,
      },
      {
        ...base("item-created-thread", "2026-06-20T00:00:04.000Z", 4),
        type: "thread_created",
        targetThreadId: sourceThreadId,
        targetRunId: null,
        targetProviderInstanceId: ProviderInstanceId.make("codex"),
        targetModel: "gpt-5.4",
      },
    ] satisfies ReadonlyArray<OrchestrationV2TurnItem>;
    const projectedResources = [
      projected(resourceItems[0]!, 1),
      projected(resourceItems[1]!, 2),
      projected(resourceItems[2]!, 4),
    ];
    const feed = buildThreadFeed([
      projected(userMessage(), 0),
      projectedResources[0]!,
      projectedResources[1]!,
      projected(command("2026-06-20T00:00:03.000Z"), 3),
      projectedResources[2]!,
      projected(assistantMessage("2026-06-20T00:00:05.000Z"), 5),
    ]);

    const collapsed = deriveThreadFeedPresentation(feed, null, new Set());
    expect(collapsed.map((entry) => entry.type)).toEqual([
      "message",
      "run-fold",
      "activity-group",
      "activity-group",
      "message",
    ]);
    expect(collapsed[1]).toMatchObject({
      type: "run-fold",
      createdAt: "2026-06-20T00:00:01.500Z",
    });
    expect(
      collapsed.flatMap((entry) =>
        entry.type === "activity-group"
          ? entry.activities.map((activity) => activity.projectedItem)
          : [],
      ),
    ).toEqual(projectedResources.slice(1));
    const expanded = deriveThreadFeedPresentation(feed, null, new Set([runId]));
    expect(
      expanded.some(
        (entry) =>
          entry.type === "activity-group" &&
          entry.activities.some((activity) => activity.projectedItem.item.type === "subagent"),
      ),
    ).toBe(true);
  });

  it("folds settled V2 run work while keeping the terminal assistant message visible", () => {
    const feed = buildThreadFeed([
      projected(userMessage(), 0),
      projected(command(), 1),
      projected(assistantMessage(), 2),
    ]);
    const latestRun = {
      runId,
      status: "completed" as const,
      startedAt: "2026-06-20T00:00:01.000Z",
      completedAt: "2026-06-20T00:00:03.000Z",
    };

    const collapsed = deriveThreadFeedPresentation(feed, latestRun, new Set());
    expect(collapsed.map((entry) => entry.type)).toEqual(["message", "run-fold", "message"]);

    const expanded = deriveThreadFeedPresentation(feed, latestRun, new Set([runId]));
    expect(expanded.map((entry) => entry.type)).toEqual([
      "message",
      "run-fold",
      "work-toggle",
      "message",
    ]);
  });

  it("keeps an active run expanded and detects failures from completed command output", () => {
    const failedCommand: OrchestrationV2TurnItem = {
      ...command(),
      output: "sh: missing-command: command not found",
    };
    const feed = buildThreadFeed([projected(userMessage(), 0), projected(failedCommand, 1)]);
    const presented = deriveThreadFeedPresentation(
      feed,
      {
        runId,
        status: "running",
        startedAt: "2026-06-20T00:00:01.000Z",
        completedAt: null,
      },
      new Set(),
    );

    expect(presented.some((entry) => entry.type === "run-fold")).toBe(false);
    expect(presented.find((entry) => entry.type === "work-toggle")).toMatchObject({
      summary: "vp check",
      hiddenCount: 1,
      hasFailure: true,
      live: false,
    });
  });

  it("folds each run of a provider-native subagent thread like a normal turn", () => {
    // A Claude subagent's child thread, as projected: no runs, and a user
    // prompt for the launch and for a SendMessage resume.
    const runless = <T extends OrchestrationV2TurnItem>(item: T, id: string, ordinal: number) => ({
      ...item,
      id: TurnItemId.make(id),
      runId: null,
      ordinal,
    });
    const prompt = (id: string, ordinal: number, at: string) =>
      runless(
        { ...userMessage(at), messageId: MessageId.make(id), creationSource: "provider" as const },
        id,
        ordinal,
      );
    const answer = (id: string, ordinal: number, at: string) =>
      runless({ ...assistantMessage(at), messageId: MessageId.make(id) }, id, ordinal);
    const { exitCode: _exitCode, ...completedCommand } = command("2026-06-20T00:01:17.000Z");
    const feed = (resumeRunning: boolean) =>
      buildThreadFeed(
        [
          prompt("launch", 1, "2026-06-20T00:00:00.000Z"),
          runless(command("2026-06-20T00:00:04.000Z"), "launch-ls", 2),
          answer("launch-answer", 3, "2026-06-20T00:00:08.000Z"),
          prompt("resume", 4, "2026-06-20T00:01:12.000Z"),
          resumeRunning
            ? runless(
                { ...completedCommand, status: "running", completedAt: null, output: "" },
                "resume-ls",
                5,
              )
            : runless(command("2026-06-20T00:01:17.000Z"), "resume-ls", 5),
          ...(resumeRunning ? [] : [answer("resume-answer", 6, "2026-06-20T00:01:20.000Z")]),
        ].map((item, position) => projected(item, position)),
      );
    const shape = (entries: ReadonlyArray<ThreadFeedEntry>) =>
      entries.map((entry) =>
        entry.type === "run-fold"
          ? `fold:${entry.label}`
          : entry.type === "message"
            ? `${entry.message.role}:${entry.message.id}`
            : entry.type,
      );

    const settled = deriveThreadFeedPresentation(feed(false), null, new Set());
    expect(shape(settled)).toEqual([
      "user:launch",
      "fold:Worked for 8.0s",
      "assistant:launch-answer",
      "user:resume",
      "fold:Worked for 8.0s",
      "assistant:resume-answer",
    ]);
    const launchFold = settled.find((entry) => entry.type === "run-fold");
    if (launchFold?.type !== "run-fold") throw new Error("Expected the launch fold");
    expect(
      shape(deriveThreadFeedPresentation(feed(false), null, new Set([launchFold.runId]))),
    ).toEqual([
      "user:launch",
      "fold:Worked for 8.0s",
      "work-toggle",
      "assistant:launch-answer",
      "user:resume",
      "fold:Worked for 8.0s",
      "assistant:resume-answer",
    ]);

    // While the resume runs, only the settled launch folds.
    expect(
      shape(
        deriveThreadFeedPresentation(
          feed(true),
          null,
          new Set(),
          new Set(),
          "2026-06-20T00:01:12.000Z",
          true,
        ),
      ),
    ).toEqual([
      "user:launch",
      "fold:Worked for 8.0s",
      "assistant:launch-answer",
      "user:resume",
      "work-toggle",
    ]);
  });

  it("keeps imported V1 turns folded once the thread's first V2 run starts", () => {
    const imported = <T extends OrchestrationV2TurnItem>(item: T, id: string) => ({
      ...item,
      id: TurnItemId.make(id),
      runId: null,
    });
    const presented = (start: OrchestrationV2TurnItem) =>
      deriveThreadFeedPresentation(
        buildThreadFeed(
          [
            imported(userMessage("2026-06-20T00:00:00.000Z"), "imported-prompt"),
            imported(
              {
                ...assistantMessage("2026-06-20T00:00:02.000Z"),
                messageId: MessageId.make("update"),
              },
              "imported-update",
            ),
            imported(command("2026-06-20T00:00:04.000Z"), "imported-ls"),
            imported(
              {
                ...assistantMessage("2026-06-20T00:00:08.000Z"),
                messageId: MessageId.make("answer"),
              },
              "imported-answer",
            ),
            start,
          ].map((item, position) => projected(item, position)),
        ),
        { runId, status: "running", startedAt: "2026-06-20T00:01:00.000Z", completedAt: null },
        new Set(),
        new Set(),
        "2026-06-20T00:01:00.000Z",
      )
        .slice(0, 4)
        .map((entry) => (entry.type === "message" ? entry.message.role : entry.type));

    // A sent prompt and an automatic wake both start V2 work below the import.
    expect(
      presented({
        ...userMessage("2026-06-20T00:01:00.000Z"),
        id: TurnItemId.make("new-prompt"),
        messageId: MessageId.make("new-prompt"),
      }),
    ).toEqual(["user", "assistant", "run-fold", "assistant"]);
    expect(
      presented({
        ...base("wake", "2026-06-20T00:01:00.000Z", 4),
        type: "notification",
        source: { kind: "background_task" },
        outcome: "completed",
        summary: "Background task finished",
      }),
    ).toEqual(["user", "assistant", "run-fold", "assistant"]);
  });

  it("keeps a provider-native subagent's runless tool call live while it works", () => {
    const startedAt = "2026-06-20T00:00:01.000Z";
    const { exitCode: _exitCode, ...completedCommand } = command();
    const runningCommand: OrchestrationV2TurnItem = {
      ...completedCommand,
      runId: null,
      status: "running",
      completedAt: null,
      output: "",
    };
    const feed = buildThreadFeed([
      projected({ ...userMessage(), runId: null }, 0),
      projected(runningCommand, 1),
    ]);

    const presented = deriveThreadFeedPresentation(
      feed,
      null,
      new Set(),
      new Set(),
      startedAt,
      true,
    );
    expect(presented.find((entry) => entry.type === "work-toggle")).toMatchObject({
      summary: "Running vp",
      live: true,
      shimmer: true,
    });
    expect(presented.some((entry) => entry.type === "thinking")).toBe(false);
  });

  it("keeps a runless tail folded while a normal thread waits for its sent run", () => {
    // Right after a send the local clock runs before the server creates the
    // run, and the latest run may still be queued: neither is runless work,
    // so the settled tail must not reopen and shift the feed.
    const startedAt = "2026-06-20T00:00:05.000Z";
    const feed = buildThreadFeed([
      projected({ ...userMessage(), runId: null }, 0),
      projected({ ...command(), runId: null }, 1),
    ]);
    for (const latestRun of [
      null,
      { runId, status: "queued" as const, startedAt: null, completedAt: null },
    ]) {
      const presented = deriveThreadFeedPresentation(
        feed,
        latestRun,
        new Set(),
        new Set(),
        startedAt,
      );
      expect(presented.map((entry) => entry.type)).toEqual(["message", "run-fold", "thinking"]);
    }
  });

  it("waits for workspace preparation before showing provider activity", () => {
    const startedAt = "2026-04-01T00:00:01.000Z";
    const run = { runId, status: "preparing" as const, startedAt: null, completedAt: null };
    expect(deriveThreadFeedPresentation([], run, new Set(), new Set(), startedAt)).toEqual([]);
    expect(
      deriveThreadFeedPresentation(
        [],
        { ...run, status: "running", startedAt },
        new Set(),
        new Set(),
        startedAt,
      ),
    ).toEqual([{ type: "thinking", id: "live-activity-row", createdAt: startedAt, runId }]);
  });

  it("uses a stable Thinking row while work has started without a projected item", () => {
    const startedAt = "2026-04-01T00:00:01.000Z";
    const presented = deriveThreadFeedPresentation([], null, new Set(), new Set(), startedAt);

    expect(presented).toEqual([
      { type: "thinking", id: "live-activity-row", createdAt: startedAt, runId: null },
    ]);
    expect(deriveThreadFeedPresentation([], null, new Set(), new Set(), startedAt)[0]).toBe(
      presented[0],
    );
  });

  it("keeps expanded work in one group with stable row identities", () => {
    const activity = (
      id: string,
      createdAt: string,
      status: ThreadFeedActivity["status"] = "success",
    ): ThreadFeedActivity => ({
      id,
      createdAt,
      runId: null,
      attemptId: null,
      summary: `Tool ${id}`,
      detail: null,
      canExpand: false,
      getFullDetail: () => null,
      getCopyText: () => id,
      icon: "command",
      logo: null,
      toolLike: true,
      prominent: false,
      status,
      lifecycleStatus: status === "neutral" ? "inProgress" : "completed",
      workEntry: {
        id,
        createdAt,
        label: `Tool ${id}`,
        tone: "tool",
        command: "vp check",
        itemType: "command_execution",
        toolLifecycleStatus: status === "neutral" ? "inProgress" : "completed",
      },
      projectedItem: projected(command(createdAt), 0),
    });
    const feed: ThreadFeedEntry[] = [
      {
        type: "activity-group",
        id: "work-group-1",
        createdAt: "2026-04-01T00:00:01.000Z",
        runId: null,
        activities: [
          activity("activity-neutral", "2026-04-01T00:00:01.000Z", "neutral"),
          activity("activity-1", "2026-04-01T00:00:02.000Z"),
          activity("activity-2", "2026-04-01T00:00:03.000Z"),
          activity("activity-3", "2026-04-01T00:00:04.000Z"),
        ],
      },
    ];

    const collapsed = deriveThreadFeedPresentation(feed, null, new Set());
    expect(collapsed.map((entry) => entry.id)).toEqual(["work-toggle:work-group:activity-neutral"]);
    expect(collapsed[0]).toMatchObject({
      type: "work-toggle",
      groupId: "work-group:activity-neutral",
      hiddenCount: 3,
      expanded: false,
      summary: "Ran 3 commands",
    });

    const expanded = deriveThreadFeedPresentation(
      feed,
      null,
      new Set(),
      new Set(["work-group:activity-neutral"]),
    );
    expect(expanded.map((entry) => entry.id)).toEqual([
      "work-toggle:work-group:activity-neutral",
      "work-details:work-group:activity-neutral",
    ]);
    expect(expanded[0]).toMatchObject({
      type: "work-toggle",
      expanded: true,
    });
    expect(expanded[1]).toMatchObject({
      type: "activity-group",
      activities: [
        { id: "activity-1", groupedToolDetail: true, live: false },
        { id: "activity-2", groupedToolDetail: true, live: false },
        { id: "activity-3", groupedToolDetail: true, live: false },
      ],
    });
  });

  it("retains Claude Read image previews without tool output", () => {
    const item = {
      ...base("image-read", "2026-06-20T00:00:04.000Z", 3),
      type: "dynamic_tool" as const,
      toolName: "Read",
      input: { file_path: "/workspace/reference.png" },
      viewedImagePath: "/workspace/reference.png",
    } satisfies OrchestrationV2TurnItem;
    const feed = buildThreadFeed([projected(item, 0)]);
    const activity = feed[0]?.type === "activity-group" ? feed[0].activities[0] : null;
    expect(activity?.workEntry.viewedImagePath).toBe("/workspace/reference.png");
  });

  it("pretty prints T3 MCP dynamic tool activities and attaches the product logo", () => {
    const toolItem: OrchestrationV2TurnItem = {
      ...base("item-t3-tool", "2026-06-20T00:00:04.000Z", 3),
      type: "dynamic_tool",
      toolName: "mcp__t3-code__t3_thread_read",
      input: { threadId: "thread-child" },
      output: { messages: [] },
    };

    const feed = buildThreadFeed([projected(toolItem, 0)]);
    const activity = feed[0]?.type === "activity-group" ? feed[0].activities[0] : null;

    expect(activity?.summary).toBe("Read a T3 thread");
    expect(activity?.logo).toBe("t3-code");
    expect(activity?.getCopyText().split("\n")[0]).toBe("Read a T3 thread");
  });

  it("uses the CUA action title in the mobile feed", () => {
    const item: OrchestrationV2TurnItem = {
      ...base("cua", "2026-09-23T20:20:00.000Z", 1),
      type: "dynamic_tool",
      toolName: "cua_repl.js",
      input: { code: "await game.getAXStateAndScreenshot();", title: "Inspect Saga music screen" },
    };
    const feed = buildThreadFeed([projected(item, 0)]);
    const activity = feed[0]?.type === "activity-group" ? feed[0].activities[0] : null;
    expect(activity?.summary).toBe("Inspect Saga music screen");
  });

  it("uses canonical T3 orchestration summaries in compact work groups", () => {
    const rows = [
      projected(command("2026-06-20T00:00:01.000Z"), 0),
      ...["mcp__t3-code__t3_thread_send", "t3_code.t3_thread_send", "t3_thread_send"].map(
        (toolName, index) =>
          projected(
            {
              ...base(`item-send-${index}`, `2026-06-20T00:00:0${index + 2}.000Z`, index + 2),
              type: "dynamic_tool" as const,
              toolName,
              input: { threadId: `thread-${index}`, message: "Continue" },
              output: { threadId: `thread-${index}`, messageId: `message-${index}` },
            },
            index + 1,
          ),
      ),
      projected(
        {
          ...command("2026-06-20T00:00:06.000Z"),
          id: TurnItemId.make("item-command-2"),
          ordinal: 6,
        },
        4,
      ),
    ];

    const presented = deriveThreadFeedPresentation(
      buildThreadFeed(rows),
      { runId, status: "running", startedAt: null, completedAt: null },
      new Set(),
    );

    expect(presented).toMatchObject([
      {
        type: "work-toggle",
        summary: "Ran 2 commands and sent messages to 3 threads",
        hiddenCount: 5,
        hasFailure: false,
      },
    ]);
  });

  it("presents project calls and summarizes successful clones through the mobile feed", () => {
    const items: OrchestrationV2TurnItem[] = [
      {
        ...base("list", "2026-09-19T00:00:01.000Z", 1),
        type: "dynamic_tool",
        title: "Custom provider title",
        toolName: "T3-code.t3_project_list",
        input: {},
        output: { projects: [] },
      },
      {
        ...base("clone", "2026-09-19T00:00:02.000Z", 2),
        type: "dynamic_tool",
        title: "Custom provider title",
        toolName: "mcp__t3_code__t3_project_clone",
        input: {},
        output: { cwd: "/tmp/repo" },
      },
      {
        ...base("failed-clone", "2026-09-19T00:00:03.000Z", 3),
        type: "dynamic_tool",
        title: "Custom provider title",
        toolName: "t3_project_clone",
        input: {},
        output: { isError: true },
      },
    ];
    const feed = buildThreadFeed(items.map((item, position) => projected(item, position)));
    const activities = feed.flatMap((entry) =>
      entry.type === "activity-group" ? entry.activities : [],
    );
    expect(workEntryRowLabel(activities[0]!.workEntry)).toBe("Listed projects");
    expect(workEntryRowLabel(activities[1]!.workEntry)).toBe("Cloned a repository");
    expect(workEntryRowLabel(activities[2]!.workEntry)).toBe("Failed to clone a repository");
    expect(activities.every((activity) => activity.logo === "t3-code")).toBe(true);
    const presented = deriveThreadFeedPresentation(
      feed,
      { runId, status: "running", startedAt: null, completedAt: null },
      new Set(),
    );
    expect(presented.find((entry) => entry.type === "work-toggle")).toMatchObject({
      summary: "Listed projects 1 time and cloned 1 repository",
      hasFailure: true,
    });
  });
});

describe("retained v2 feed presentation", () => {
  it("retains unchanged rows while the assistant streams", () => {
    const rows = [
      projected(userMessage(), 0),
      projected(command(), 1),
      projected({ ...assistantMessage(), streaming: true }, 2),
    ];
    const latestRun = {
      runId,
      status: "running" as const,
      startedAt: "2026-06-20T00:00:01.000Z",
      completedAt: null,
    };
    const before = buildThreadFeed(rows);
    const beforePresentation = deriveThreadFeedPresentation(
      before,
      latestRun,
      new Set(),
      new Set(),
      latestRun.startedAt,
    );
    const after = buildThreadFeed([
      rows[0]!,
      rows[1]!,
      projected(
        { ...assistantMessage("2026-06-20T00:00:04.000Z"), text: "Still working", streaming: true },
        2,
      ),
    ]);
    const afterPresentation = deriveThreadFeedPresentation(
      after,
      latestRun,
      new Set(),
      new Set(),
      latestRun.startedAt,
    );
    expect(after[0]).toBe(before[0]);
    expect(after[1]).toBe(before[1]);
    expect(after[2]).not.toBe(before[2]);
    expect(afterPresentation[0]).toBe(beforePresentation[0]);
    expect(afterPresentation[1]).toBe(beforePresentation[1]);
  });

  it.each(["running", "completed", "interrupted"] as const)(
    "uses the compaction row as the live activity only while %s",
    (status) => {
      const compact = projected(
        {
          ...base("compacted", "2026-06-20T00:00:02.000Z", 1),
          type: "compaction",
          status,
          driver: null,
          beforeTokenCount: 899_000,
          ...(status === "completed" ? { afterTokenCount: 19_000 } : {}),
        },
        1,
      );
      const latestRun = {
        runId,
        status: "running" as const,
        startedAt: "2026-06-20T00:00:01.000Z",
        completedAt: null,
      };
      const rows = deriveThreadFeedPresentation(
        buildThreadFeed([projected(userMessage(), 0), compact]),
        latestRun,
        new Set(),
        new Set(),
        latestRun.startedAt,
      );
      expect(rows.some((row) => row.type === "thinking")).toBe(status !== "running");
      expect(rows.find((row) => row.type === "activity-group")).toMatchObject({
        activities: [
          {
            summary:
              status === "running"
                ? "Compacting context"
                : status === "completed"
                  ? "Context compacted 899K → 19K tokens"
                  : "Context compacted",
          },
        ],
      });
    },
  );

  it.each(["running", "completed", "failed"] as const)(
    "keeps a %s handoff separate from commands and visible through folds",
    (status) => {
      const handoff = projected(
        {
          ...base("handoff", "2026-06-20T00:00:02.000Z", 1),
          type: "handoff",
          status,
          contextHandoffId: ContextHandoffId.make("handoff"),
          fromProviderThreadIds: [],
          toProviderThreadId: ProviderThreadId.make("target"),
          fromProviderInstanceIds: [ProviderInstanceId.make("codex")],
          toProviderInstanceId: ProviderInstanceId.make("claudeAgent"),
          strategy: "full_thread_summary",
          summary: "Private full conversation summary",
        },
        1,
      );
      const feed = buildThreadFeed([
        projected(userMessage(), 0),
        handoff,
        projected(command("2026-06-20T00:00:03.000Z"), 2),
        projected(assistantMessage("2026-06-20T00:00:04.000Z"), 3),
      ]);
      for (const expanded of [new Set<RunId>(), new Set([runId])]) {
        const rows = deriveThreadFeedPresentation(feed, null, expanded);
        const divider = rows.filter(
          (entry) => entry.type === "activity-group" && isContextHandoffActivityGroup(entry),
        );
        expect(divider).toHaveLength(1);
        expect(divider[0]).toMatchObject({ activities: [{ projectedItem: handoff }] });
      }
      const alone = deriveThreadFeedPresentation(
        buildThreadFeed([projected(userMessage(), 0), handoff]),
        null,
        new Set(),
      );
      expect(alone.map((entry) => entry.type)).toEqual(["message", "activity-group"]);
    },
  );

  it("keeps a standalone compaction visible and folds it with other completed work", () => {
    const compact = projected(
      {
        ...base("compacted", "2026-06-20T00:00:02.000Z", 1),
        type: "compaction",
        driver: null,
        summary: "Shorter context",
      },
      1,
    );
    const latestRun = {
      runId,
      status: "completed" as const,
      startedAt: "2026-06-20T00:00:01.000Z",
      completedAt: "2026-06-20T00:00:04.000Z",
    };
    const onlyCompaction = deriveThreadFeedPresentation(
      buildThreadFeed([projected(userMessage(), 0), compact]),
      latestRun,
      new Set(),
    );
    expect(onlyCompaction.map((entry) => entry.type)).toEqual(["message", "activity-group"]);
    const feed = buildThreadFeed([
      projected(userMessage(), 0),
      compact,
      projected(command("2026-06-20T00:00:03.000Z"), 2),
      projected(assistantMessage("2026-06-20T00:00:04.000Z"), 3),
    ]);
    expect(
      deriveThreadFeedPresentation(feed, latestRun, new Set()).map((entry) => entry.type),
    ).toEqual(["message", "run-fold", "message"]);
    const expanded = deriveThreadFeedPresentation(feed, latestRun, new Set([runId]));
    expect(
      expanded.find(
        (entry) =>
          entry.type === "activity-group" &&
          entry.activities[0]?.projectedItem.item.type === "compaction",
      ),
    ).toMatchObject({ activities: [{ summary: "Context compacted" }] });
  });

  it("retains assistant image attachments from the wire", () => {
    const image = {
      type: "image" as const,
      id: "assistant-image",
      name: "result.png",
      mimeType: "image/png",
      sizeBytes: 100,
    };
    const feed = buildThreadFeed([
      projected({ ...assistantMessage(), text: "", attachments: [image] }, 0),
    ]);
    expect(feed).toMatchObject([
      { type: "message", message: { role: "assistant", attachments: [image] } },
    ]);
  });

  it("keeps native application icons and source identity in collapsed and expanded work", () => {
    const icon = {
      _tag: "native-app" as const,
      app: { _tag: "app-id" as const, appId: "com.example.Editor" },
    };
    const source = {
      key: "native-app:com.example.editor",
      name: "Editor",
      kind: "computer" as const,
      icon,
    };
    const rows = [0, 1].map((index) =>
      projected(
        {
          ...base(`native-${index}`, `2026-06-20T00:00:0${index + 2}.000Z`, index + 1),
          type: "dynamic_tool" as const,
          toolName: "computer.click",
          input: { x: index, y: 1 },
          output: null,
          toolSurface: "computer" as const,
          toolIcon: icon,
          toolSource: source,
        },
        index,
      ),
    );
    const feed = buildThreadFeed(rows);
    const latestRun = { runId, status: "running" as const, startedAt: null, completedAt: null };
    const collapsed = deriveThreadFeedPresentation(feed, latestRun, new Set());
    const toggle = collapsed[0];
    if (toggle?.type !== "work-toggle") throw new Error("Expected a collapsed work group");
    const presented = deriveThreadFeedPresentation(
      feed,
      latestRun,
      new Set(),
      new Set([toggle.groupId]),
    );
    expect(presented[0]).toMatchObject({
      type: "work-toggle",
      summary: "Used Editor",
      toolSurface: "computer",
      toolIcon: icon,
    });
    expect(presented[1]).toMatchObject({
      type: "activity-group",
      activities: [
        { icon: "computer", workEntry: { toolSource: source, toolIcon: icon } },
        { icon: "computer", workEntry: { toolSource: source, toolIcon: icon } },
      ],
    });
  });

  it.each([
    ["failed", "Failed to click in the preview browser", true],
    ["cancelled", "Stopped clicking in the preview browser", false],
  ] as const)(
    "keeps %s calls terminal while the parent run remains live",
    (status, summary, hasFailure) => {
      const feed = buildThreadFeed([
        projected(
          {
            ...base("preview-click", "2026-06-20T00:00:02.000Z", 1),
            type: "dynamic_tool",
            status,
            toolName: "mcp__t3-code__preview_click",
            input: { element: "button" },
            output: null,
          },
          0,
        ),
      ]);
      const rows = deriveThreadFeedPresentation(
        feed,
        { runId, status: "running", startedAt: "2026-06-20T00:00:01.000Z", completedAt: null },
        new Set(),
        new Set(),
        "2026-06-20T00:00:01.000Z",
      );
      expect(rows[0]).toMatchObject({ type: "work-toggle", summary, hasFailure, shimmer: false });
    },
  );

  it.each([
    { envelope: "direct", output: { taskId: "a" } },
    { envelope: "structured", output: { structuredContent: { taskId: "a" } } },
    { envelope: "text", output: { content: [{ type: "text", text: '{"taskId":"a"}' }] } },
  ])(
    "folds matched $envelope delegations without hiding pending, failed or unmatched calls",
    ({ output }) => {
      const agent = (
        id: string,
        index: number,
        origin = "app_owned" as "app_owned" | "provider_native",
      ) =>
        projected(
          {
            ...base(id, "2026-06-20T00:00:01.000Z", index),
            type: "subagent",
            subagentId: NodeId.make(id),
            origin,
            driver: ProviderDriverKind.make("codex"),
            providerInstanceId: ProviderInstanceId.make("codex"),
            childThreadId: ThreadId.make(`child-${id}`),
            prompt: "Identical task",
            result: "Done",
          },
          index,
        );
      const delegation = (
        id: string,
        index: number,
        overrides: Partial<Extract<OrchestrationV2TurnItem, { type: "dynamic_tool" }>> = {},
      ) =>
        projected(
          {
            ...base(id, "2026-06-20T00:00:02.000Z", index),
            type: "dynamic_tool",
            toolName: "t3-code.delegate_task",
            input: { task: "Identical task" },
            output,
            ...overrides,
          },
          index,
        );
      const feed = buildThreadFeed([
        agent("a", 1),
        delegation("matched", 2),
        agent("b", 3),
        delegation("pending", 4, { status: "running", output: null }),
        delegation("unmatched", 5, { output: { taskId: "missing" } }),
        delegation("failed", 6, { status: "failed" }),
        delegation("error-output", 7, { output: { taskId: "a", isError: true } }),
        delegation("other-run", 8, { runId: RunId.make("other-run") }),
        agent("native", 9, "provider_native"),
        delegation("native-delegation", 10, { output: { taskId: "native" } }),
      ]);
      const groups = feed.flatMap((entry) =>
        entry.type === "activity-group"
          ? [entry.activities.map((activity) => activity.projectedItem.item.id)]
          : [],
      );
      expect(groups[0]).toEqual(["a", "b"]);
      expect(groups.flat()).toEqual([
        "a",
        "b",
        "pending",
        "unmatched",
        "failed",
        "error-output",
        "other-run",
        "native",
        "native-delegation",
      ]);
      const presented = deriveThreadFeedPresentation(
        feed,
        null,
        new Set([runId, RunId.make("other-run")]),
      );
      expect(
        presented.find(
          (entry) =>
            entry.type === "activity-group" && entry.activities[0]?.projectedItem.item.id === "a",
        )?.continuesWorkLog,
      ).toBeUndefined();
    },
  );

  it("keeps subagents from different provider turns in separate cards", () => {
    const agent = (id: string, index: number) =>
      projected(
        {
          ...base(id, "2026-06-20T00:00:01.000Z", index),
          type: "subagent",
          subagentId: NodeId.make(id),
          origin: "provider_native",
          driver: ProviderDriverKind.make("codex"),
          providerInstanceId: ProviderInstanceId.make("codex"),
          providerTurnId: ProviderTurnId.make(id),
          childThreadId: null,
          prompt: "Task",
          result: null,
        },
        index,
      );
    expect(
      buildThreadFeed([agent("a", 1), agent("b", 2)]).flatMap((entry) =>
        entry.type === "activity-group"
          ? [entry.activities.map((activity) => activity.projectedItem.item.id)]
          : [],
      ),
    ).toEqual([["a"], ["b"]]);
  });

  it("groups only adjacent subagents in the same run, keeping their child links", () => {
    const agent = (id: string, index: number, agentRunId = runId) =>
      projected(
        {
          ...base(id, `2026-06-20T00:00:0${index}.000Z`, index),
          type: "subagent",
          runId: agentRunId,
          subagentId: NodeId.make(id),
          origin: "app_owned",
          driver: ProviderDriverKind.make("codex"),
          providerInstanceId: ProviderInstanceId.make("codex"),
          childThreadId: ThreadId.make(`child-${id}`),
          prompt: "Solve the puzzle",
          result: "Done",
        },
        index,
      );
    const feed = buildThreadFeed([
      agent("a", 1),
      agent("b", 2),
      projected(command("2026-06-20T00:00:03.000Z"), 3),
      agent("c", 4),
      agent("d", 5, RunId.make("other-run")),
    ]);
    expect(
      feed.flatMap((entry) =>
        entry.type === "activity-group"
          ? [entry.activities.map((activity) => activity.projectedItem.item.id)]
          : [],
      ),
    ).toEqual([["a", "b"], ["item-command"], ["c"], ["d"]]);
    const presented = deriveThreadFeedPresentation(
      feed,
      null,
      new Set([runId, RunId.make("other-run")]),
    );
    const groups = presented.flatMap((entry) =>
      entry.type === "activity-group" && entry.activities[0]?.projectedItem.item.type === "subagent"
        ? [entry]
        : [],
    );
    expect(groups.map((entry) => entry.activities.length)).toEqual([2, 1, 1]);
    expect(groups[0]?.activities.map((activity) => activity.projectedItem.item)).toMatchObject([
      { childThreadId: "child-a" },
      { childThreadId: "child-b" },
    ]);
  });

  it("shows an idle native subagent without claiming completion", () => {
    const rows = buildThreadFeed([
      projected(
        {
          ...base("native-agent", "2026-06-20T00:00:02.000Z", 1),
          type: "subagent",
          status: "idle",
          subagentId: NodeId.make("native-agent"),
          origin: "provider_native",
          driver: ProviderDriverKind.make("antigravity"),
          providerInstanceId: ProviderInstanceId.make("antigravity"),
          childThreadId: null,
          title: "Search",
          prompt: "Find relevant files",
          result: null,
        },
        0,
      ),
    ]);
    expect(rows[0]).toMatchObject({
      type: "activity-group",
      activities: [{ status: "neutral", lifecycleStatus: "idle", prominent: false }],
    });
    expect(deriveThreadFeedPresentation(rows, null, new Set([runId]))).toMatchObject([
      { type: "run-fold", expanded: true },
      { type: "activity-group", activities: [{ lifecycleStatus: "idle" }] },
    ]);
  });
});

const singleSelectQuestion = {
  id: "runtime",
  header: "Runtime",
  question: "Which runtime should be used?",
  options: [
    { label: "Go", description: "One binary" },
    { label: "Node.js", description: "Reuse TypeScript" },
  ],
  multiSelect: false,
} as const;

const multiSelectQuestion = {
  id: "scope",
  header: "Scope",
  question: "Which data should be collected?",
  options: [
    { label: "Orders", description: "Receipts" },
    { label: "Listings", description: "Inventory" },
  ],
  multiSelect: true,
} as const;

describe("pending user input answers", () => {
  it("replaces single-select options and toggles multi-select options", () => {
    expect(
      togglePendingUserInputOptionSelection(
        singleSelectQuestion,
        { selectedOptionValues: ["Go"] },
        "Node.js",
      ),
    ).toEqual({ customAnswer: "", selectedOptionValues: ["Node.js"] });

    const orders = togglePendingUserInputOptionSelection(multiSelectQuestion, undefined, "Orders");
    const ordersAndListings = togglePendingUserInputOptionSelection(
      multiSelectQuestion,
      orders,
      "Listings",
    );
    expect(ordersAndListings).toEqual({
      customAnswer: "",
      selectedOptionValues: ["Orders", "Listings"],
    });
    expect(
      togglePendingUserInputOptionSelection(multiSelectQuestion, ordersAndListings, "Orders"),
    ).toEqual({ customAnswer: "", selectedOptionValues: ["Listings"] });

    const paddedOrders = togglePendingUserInputOptionSelection(
      multiSelectQuestion,
      undefined,
      "  Orders  ",
    );
    expect(paddedOrders).toEqual({ customAnswer: "", selectedOptionValues: ["Orders"] });
    expect(
      togglePendingUserInputOptionSelection(multiSelectQuestion, paddedOrders, "  Orders  "),
    ).toEqual({ customAnswer: "" });
  });

  it("builds array answers for multi-select questions", () => {
    expect(
      buildPendingUserInputAnswers([singleSelectQuestion, multiSelectQuestion], {
        runtime: { selectedOptionValues: ["Go"] },
        scope: { selectedOptionValues: ["Orders", "Listings"] },
      }),
    ).toEqual({
      runtime: "Go",
      scope: ["Orders", "Listings"],
    });
  });

  it("clears selected options while a custom answer is active", () => {
    expect(
      setPendingUserInputCustomAnswer(
        multiSelectQuestion,
        { selectedOptionValues: ["Orders", "Listings"] },
        "Orders first",
      ),
    ).toEqual({ customAnswer: "Orders first" });
  });

  it("matches selected chips against normalized option labels", () => {
    expect(
      isPendingUserInputOptionSelected(
        multiSelectQuestion,
        { selectedOptionValues: ["Orders"] },
        "  Orders  ",
      ),
    ).toBe(true);
    expect(
      isPendingUserInputOptionSelected(
        multiSelectQuestion,
        { selectedOptionValues: ["Orders"], customAnswer: "Orders first" },
        "  Orders  ",
      ),
    ).toBe(false);
  });
});

describe("provider question values", () => {
  const question = {
    ...singleSelectQuestion,
    allowCustomAnswer: false,
    options: [
      { label: "Same label", value: "  exact first  ", description: "First" },
      { label: "Same label", value: "second", description: "Second" },
    ],
  } as const;

  it("submits raw option values and distinguishes duplicate labels", () => {
    const first = togglePendingUserInputOptionSelection(question, undefined, "  exact first  ");
    expect(isPendingUserInputOptionSelected(question, first, "  exact first  ")).toBe(true);
    expect(isPendingUserInputOptionSelected(question, first, "second")).toBe(false);
    expect(buildPendingUserInputAnswers([question], { runtime: first })).toEqual({
      runtime: "  exact first  ",
    });
    expect(togglePendingUserInputOptionSelection(question, first, "Same label")).toBe(first);
  });

  it("rejects arbitrary text when the provider only accepts offered options", () => {
    expect(setPendingUserInputCustomAnswer(question, undefined, "Other")).toEqual({});
    expect(
      buildPendingUserInputAnswers([question], { runtime: { customAnswer: "Other" } }),
    ).toBeNull();
    expect(
      buildPendingUserInputAnswers([question], { runtime: { selectedOptionValues: ["unknown"] } }),
    ).toBeNull();
    expect(
      buildPendingUserInputAnswers([question], {
        runtime: { selectedOptionValues: ["second"], customAnswer: "stale draft" },
      }),
<<<<<<< HEAD
    );
    expect(feed).toEqual([]);
  });

  it.each(["setup-script.requested", "setup-script.started"])(
    "keeps error-toned %s notices visible",
    (kind) => {
      const feed = buildThreadFeed(
        makeThread({
          id: ThreadId.make("thread-setup-error"),
          projectId: ProjectId.make("project-1"),
          title: "Setup error",
          activities: [
            makeActivity({
              id: EventId.make("setup-error"),
              kind,
              summary: "Setup failed",
              createdAt: "2026-08-30T00:00:00.000Z",
              tone: "error",
            }),
          ],
        }),
      );

      expect(feed).toMatchObject([
        { type: "activity-group", activities: [{ id: "setup-error", status: "failure" }] },
      ]);
    },
  );

  it("keeps historic work entries attributed to their turns", () => {
    const thread = makeThread({
      id: ThreadId.make("thread-1"),
      projectId: ProjectId.make("project-1"),
      title: "Runtime warning thread",
      latestTurn: {
        turnId: TurnId.make("turn-latest"),
        state: "running",
        requestedAt: "2026-04-01T00:00:00.000Z",
        startedAt: "2026-04-01T00:00:01.000Z",
        completedAt: null,
        assistantMessageId: null,
      },
      activities: [
        makeActivity({
          id: EventId.make("activity-old"),
          kind: "runtime.warning",
          summary: "Runtime warning",
          createdAt: "2026-04-01T00:00:02.000Z",
          turnId: TurnId.make("turn-old"),
          payload: {
            message: "Old warning",
          },
        }),
        makeActivity({
          id: EventId.make("activity-latest"),
          kind: "runtime.warning",
          summary: "Runtime warning",
          createdAt: "2026-04-01T00:00:03.000Z",
          turnId: TurnId.make("turn-latest"),
          payload: {
            message: "Latest warning",
          },
        }),
      ],
    });

    const feed = buildThreadFeed(thread);
    expect(feed).toMatchObject([
      {
        type: "activity-group",
        turnId: "turn-old",
        activities: [{ id: "activity-old", turnId: "turn-old" }],
      },
      {
        type: "activity-group",
        turnId: "turn-latest",
        activities: [{ id: "activity-latest", turnId: "turn-latest" }],
      },
    ]);
  });

  it("drops runtime warnings with no displayable content", () => {
    const thread = makeThread({
      id: ThreadId.make("thread-noise"),
      projectId: ProjectId.make("project-1"),
      title: "Warning noise thread",
      activities: [
        makeActivity({
          id: EventId.make("activity-noise"),
          kind: "runtime.warning",
          summary: "Claude system message 'background_tasks_changed' (no displayable text content)",
          createdAt: "2026-04-01T00:00:02.000Z",
          turnId: TurnId.make("turn-1"),
        }),
        makeActivity({
          id: EventId.make("activity-signal"),
          kind: "runtime.warning",
          summary: "Reconnecting... 2/5",
          createdAt: "2026-04-01T00:00:03.000Z",
          turnId: TurnId.make("turn-1"),
        }),
      ],
    });

    const feed = buildThreadFeed(thread);
    expect(feed).toMatchObject([
      {
        type: "activity-group",
        activities: [{ id: "activity-signal" }],
      },
    ]);
  });

  it("collapses matching tool lifecycle rows like desktop", () => {
    const thread = makeThread({
      id: ThreadId.make("thread-2"),
      projectId: ProjectId.make("project-1"),
      title: "Collapsed tools",
      latestTurn: {
        turnId: TurnId.make("turn-1"),
        state: "completed",
        requestedAt: "2026-04-01T00:00:00.000Z",
        startedAt: "2026-04-01T00:00:01.000Z",
        completedAt: "2026-04-01T00:00:03.000Z",
        assistantMessageId: null,
      },
      activities: [
        makeActivity({
          id: EventId.make("tool-updated"),
          kind: "tool.updated",
          tone: "tool",
          summary: "Run tests",
          createdAt: "2026-04-01T00:00:01.000Z",
          turnId: TurnId.make("turn-1"),
          payload: {
            title: "Run tests",
            itemType: "command_execution",
            detail: "/bin/zsh -lc 'bun run test'",
          },
        }),
        makeActivity({
          id: EventId.make("tool-completed"),
          kind: "tool.completed",
          tone: "tool",
          summary: "Run tests completed",
          createdAt: "2026-04-01T00:00:02.000Z",
          turnId: TurnId.make("turn-1"),
          payload: {
            title: "Run tests",
            itemType: "command_execution",
            detail: "/bin/zsh -lc 'bun run test'",
          },
        }),
      ],
    });

    const feed = buildThreadFeed(thread);
    const group = feed[0];

    expect(group).toMatchObject({
      type: "activity-group",
    });
    if (!group || group.type !== "activity-group") {
      return;
    }

    expect(group.activities).toHaveLength(1);
    expect(group.activities[0]).toMatchObject({
      id: "tool-updated",
      createdAt: "2026-04-01T00:00:01.000Z",
      turnId: "turn-1",
      summary: "Run tests",
      detail: "bun run test",
      canExpand: true,
      icon: "command",
      toolLike: true,
      status: "success",
    });
    expect(group.activities[0]?.getFullDetail()).toBe("/bin/zsh -lc 'bun run test'");
    expect(group.activities[0]?.getCopyText()).toBe(
      "Run tests\nbun run test\n/bin/zsh -lc 'bun run test'",
    );
  });

  it("keeps viewed image metadata while collapsing a streamed Claude Read", () => {
    const turnId = TurnId.make("turn-image-read");
    const imagePath = `/workspace/${"nested folder/".repeat(16)}reference image.webp`;
    const thread = makeThread({
      id: ThreadId.make("thread-image-read"),
      projectId: ProjectId.make("project-1"),
      title: "Image read",
      activities: [
        makeActivity({
          id: EventId.make("image-read-update"),
          kind: "tool.updated",
          tone: "tool",
          summary: "Image view",
          createdAt: "2026-04-01T00:00:01.000Z",
          turnId,
          payload: {
            toolCallId: "tool-read-image",
            itemType: "image_view",
            status: "inProgress",
            detail: `${imagePath.slice(0, 177)}...`,
            data: { imagePath },
          },
        }),
        makeActivity({
          id: EventId.make("image-read-completed"),
          kind: "tool.completed",
          tone: "tool",
          summary: "Image view",
          createdAt: "2026-04-01T00:00:02.000Z",
          turnId,
          payload: {
            toolCallId: "tool-read-image",
            itemType: "image_view",
            status: "completed",
            detail: `${imagePath.slice(0, 177)}...`,
            data: {},
          },
        }),
      ],
    });

    const group = buildThreadFeed(thread)[0];
    expect(group).toMatchObject({
      type: "activity-group",
      activities: [
        {
          workEntry: {
            itemType: "image_view",
            viewedImagePath: imagePath,
          },
        },
      ],
    });
    if (group?.type !== "activity-group") return;
    const row = group.activities[0]!;
    expect(row.canExpand).toBe(true);
    expect(row.getFullDetail()).toBeNull();
    expect(workEntryRowLabel(row.workEntry, true)).toBe(`${imagePath.slice(0, 177)}...`);
  });

  it("keeps MCP inputs available to expanded mobile work rows", () => {
    const turnId = TurnId.make("turn-mcp");
    const thread = makeThread({
      id: ThreadId.make("thread-mcp"),
      projectId: ProjectId.make("project-1"),
      title: "Expandable MCP call",
      latestTurn: {
        turnId,
        state: "completed",
        requestedAt: "2026-04-01T00:00:00.000Z",
        startedAt: "2026-04-01T00:00:01.000Z",
        completedAt: "2026-04-01T00:00:03.000Z",
        assistantMessageId: null,
      },
      activities: [
        makeActivity({
          id: EventId.make("mcp-completed"),
          kind: "tool.completed",
          tone: "tool",
          summary: "Call repository tool",
          createdAt: "2026-04-01T00:00:02.000Z",
          turnId,
          payload: {
            title: "Call repository tool",
            itemType: "mcp_tool_call",
            toolSurface: "computer",
            toolIcon: {
              _tag: "native-app",
              app: { _tag: "app-id", appId: "com.example.Editor" },
            },
            toolSource: {
              key: "native-app:com.example.editor",
              name: "Computer Use",
              kind: "computer",
              icon: {
                _tag: "native-app",
                app: { _tag: "app-id", appId: "com.example.Editor" },
              },
            },
            detail: "repository.search",
            status: "completed",
            data: {
              item: {
                server: "repository",
                tool: "search",
                arguments: { query: "work log" },
              },
            },
          },
        }),
      ],
    });

    const group = buildThreadFeed(thread)[0];
    expect(group).toMatchObject({ type: "activity-group" });
    if (!group || group.type !== "activity-group") {
      return;
    }

    expect(group.activities[0]?.icon).toBe("computer");
    expect(group.activities[0]?.workEntry.toolSurface).toBe("computer");
    expect(group.activities[0]?.workEntry.toolIcon).toEqual({
      _tag: "native-app",
      app: { _tag: "app-id", appId: "com.example.Editor" },
    });
    expect(group.activities[0]?.workEntry.toolSource).toEqual({
      key: "native-app:com.example.editor",
      name: "Computer Use",
      kind: "computer",
      icon: {
        _tag: "native-app",
        app: { _tag: "app-id", appId: "com.example.Editor" },
      },
    });
    expect(group.activities[0]?.getFullDetail()).toContain('"query": "work log"');
    expect(workEntryRowLabel(group.activities[0]!.workEntry, true)).toBe("repository.search");
    expect(group.activities[0]?.getFullDetail()).not.toContain("repository.search");
  });

  it.each([
    {
      source: "raw MCP browser identity",
      label: "Call MCP tool",
      title: "Call MCP tool",
      item: { server: "t3-code", tool: "preview_navigate" },
      status: "inProgress",
      displayName: "Navigating the preview browser",
      icon: "browser",
    },
    {
      source: "raw MCP orchestration identity",
      label: "Call MCP tool",
      title: "Call MCP tool",
      item: { server: "t3-code", tool: "task_status" },
      status: "inProgress",
      displayName: "Getting delegated task status",
      icon: "t3-code",
    },
    {
      source: "provider-qualified title",
      label: "Call MCP tool",
      title: "mcp__t3-code__preview_snapshot",
      item: undefined,
      status: "inProgress",
      displayName: "Taking a snapshot of the preview page",
      icon: "browser",
    },
    {
      source: "provider-qualified label",
      label: "mcp__t3-code__task_status",
      title: undefined,
      item: undefined,
      status: "inProgress",
      displayName: "Getting delegated task status",
      icon: "t3-code",
    },
    {
      source: "browser identity without lifecycle status",
      label: "Call MCP tool",
      title: "Call MCP tool",
      item: { server: "t3-code", tool: "preview_click" },
      status: undefined,
      displayName: "Clicking in the preview browser",
      liveDisplayName: "Clicking in the preview browser",
      settledDisplayName: "Clicked in the preview browser",
      icon: "browser",
    },
    {
      source: "orchestration identity without lifecycle status",
      label: "Call MCP tool",
      title: "Call MCP tool",
      item: { server: "t3-code", tool: "task_status" },
      status: undefined,
      displayName: "Getting delegated task status",
      liveDisplayName: "Getting delegated task status",
      settledDisplayName: "Got delegated task status",
      icon: "t3-code",
    },
  ])(
    "uses friendly row and running labels from $source",
    ({ label, title, item, status, displayName, liveDisplayName, settledDisplayName, icon }) => {
      const turnId = TurnId.make("turn-friendly-mcp");
      const rawCommand = "node mcp-call.js";
      const rawDetail = '{"provider":"raw MCP output"}';
      const thread = makeThread({
        id: ThreadId.make("thread-friendly-mcp"),
        projectId: ProjectId.make("project-1"),
        title: "Friendly MCP labels",
        latestTurn: {
          turnId,
          state: "running",
          requestedAt: "2026-04-01T00:00:00.000Z",
          startedAt: "2026-04-01T00:00:01.000Z",
          completedAt: null,
          assistantMessageId: null,
        },
        activities: [
          makeActivity({
            id: EventId.make("friendly-mcp"),
            kind: "tool.updated",
            tone: "tool",
            summary: label,
            createdAt: "2026-04-01T00:00:02.000Z",
            turnId,
            payload: {
              title,
              itemType: "mcp_tool_call",
              detail: rawDetail,
              status,
              data: { item, command: rawCommand },
            },
          }),
        ],
      });

      const feed = buildThreadFeed(thread);
      const group = feed[0];
      expect(group).toMatchObject({
        type: "activity-group",
        activities: [{ summary: displayName, detail: rawCommand }],
      });
      if (!group || group.type !== "activity-group") return;
      const activity = group.activities[0]!;
      expect(activity.getFullDetail()).toContain(rawCommand);
      expect(activity.getFullDetail()).toContain(rawDetail);
      expect(activity.getCopyText()).toContain(rawCommand);
      expect(activity.getCopyText()).toContain(rawDetail);
      expect(activity.getCopyText()).not.toContain(displayName);
      if (item) expect(activity.getFullDetail()).toContain(JSON.stringify(item, null, 2));
      expect(
        deriveThreadFeedPresentation(
          feed,
          thread.latestTurn,
          new Set(),
          new Set(),
          thread.latestTurn!.startedAt,
        ),
      ).toMatchObject([
        {
          type: "work-toggle",
          summary: liveDisplayName ?? displayName,
          summaryToolIcon: icon,
          live: true,
        },
      ]);
      if (settledDisplayName) {
        const settledRows = deriveThreadFeedPresentation(
          feed,
          {
            ...thread.latestTurn!,
            state: "completed",
            completedAt: "2026-04-01T00:00:03.000Z",
          },
          new Set([turnId]),
          new Set(),
        );
        expect(settledRows.find((entry) => entry.type === "work-toggle")).toMatchObject({
          summary: settledDisplayName,
          summaryToolIcon: icon,
          live: false,
        });
      }
    },
  );

  it("retains Claude MCP metadata behind friendly row and running labels", () => {
    const turnId = TurnId.make("turn-claude-mcp");
    const toolData = {
      toolName: "mcp__t3-code__preview_click",
      input: { locator: { role: "button", name: "Continue" } },
      result: { content: "Clicked Continue" },
    };
    const detail = "Click Continue";
    const thread = makeThread({
      id: ThreadId.make("thread-claude-mcp"),
      projectId: ProjectId.make("project-1"),
      title: "Claude MCP labels",
      latestTurn: {
        turnId,
        state: "running",
        requestedAt: "2026-04-01T00:00:00.000Z",
        startedAt: "2026-04-01T00:00:01.000Z",
        completedAt: null,
        assistantMessageId: null,
      },
      activities: [
        makeActivity({
          id: EventId.make("claude-mcp-completed"),
          kind: "tool.completed",
          tone: "tool",
          summary: "MCP tool call completed",
          createdAt: "2026-04-01T00:00:02.000Z",
          turnId,
          payload: {
            title: "MCP tool call",
            itemType: "mcp_tool_call",
            status: "completed",
            detail,
            data: toolData,
          },
        }),
      ],
    });

    const feed = buildThreadFeed(thread);
    const group = feed[0];
    expect(group).toMatchObject({
      type: "activity-group",
      activities: [
        {
          summary: "Clicked in the preview browser",
          detail,
          workEntry: { label: "MCP tool call completed", toolTitle: "MCP tool call" },
        },
      ],
    });
    if (!group || group.type !== "activity-group") return;
    const activity = group.activities[0]!;
    const fullDetail = `MCP call\n${JSON.stringify(toolData, null, 2)}\n\n${detail}`;
    expect(activity.workEntry.toolData).toBe(toolData);
    expect(activity.getFullDetail()).toBe(fullDetail);
    expect(activity.getCopyText()).toBe(`MCP tool call\n${detail}\n${fullDetail}`);
    expect(
      deriveThreadFeedPresentation(
        feed,
        thread.latestTurn,
        new Set(),
        new Set(),
        thread.latestTurn!.startedAt,
      ),
    ).toMatchObject([
      {
        type: "work-toggle",
        summary: "Clicking in the preview browser",
        summaryToolIcon: "browser",
        live: true,
      },
    ]);
  });

  it.each([
    {
      status: "completed",
      displayName: "Clicked in the preview browser",
      liveDisplayName: "Clicking in the preview browser",
      detail: "Clicked Continue",
      hasFailure: false,
    },
    {
      status: "failed",
      displayName: "Failed to click in the preview browser",
      liveDisplayName: "Failed to click in the preview browser",
      detail: "Timed out waiting for Continue",
      hasFailure: true,
    },
  ])(
    "uses the browser call label once its action settles as $status",
    ({ status, displayName, liveDisplayName, detail, hasFailure }) => {
      const turnId = TurnId.make("turn-preview-lifecycle");
      const toolCallId = "preview-click";
      const groupId = `work-group:tool:${turnId}:${toolCallId}`;
      const toolData = {
        server: "t3-code",
        tool: "preview_click",
        arguments: { locator: { role: "button", name: "Continue" } },
      };
      const thread = makeThread({
        id: ThreadId.make("thread-preview-lifecycle"),
        projectId: ProjectId.make("project-1"),
        title: "Browser tool lifecycle",
        latestTurn: {
          turnId,
          state: "running",
          requestedAt: "2026-04-01T00:00:00.000Z",
          startedAt: "2026-04-01T00:00:01.000Z",
          completedAt: null,
          assistantMessageId: null,
        },
        activities: [
          makeActivity({
            id: EventId.make("preview-click-started"),
            kind: "tool.updated",
            tone: "tool",
            summary: "MCP tool call",
            createdAt: "2026-04-01T00:00:02.000Z",
            turnId,
            payload: {
              title: "MCP tool call",
              itemType: "mcp_tool_call",
              status: "inProgress",
              toolCallId,
              data: { item: toolData },
            },
          }),
        ],
      });
      const present = (currentThread: OrchestrationThread) =>
        deriveThreadFeedPresentation(
          buildThreadFeed(currentThread),
          currentThread.latestTurn,
          new Set([turnId]),
          new Set([groupId]),
          currentThread.latestTurn?.state === "running" ? currentThread.latestTurn.startedAt : null,
        );

      expect(present(thread)).toMatchObject([
        {
          type: "work-toggle",
          groupId,
          hiddenCount: 1,
          expanded: true,
          summary: "Clicking in the preview browser",
          summaryToolIcon: "browser",
          live: true,
          shimmer: true,
        },
        {
          type: "activity-group",
          id: `work-details:${groupId}`,
          activities: [
            {
              id: "preview-click-started",
              summary: "Clicking in the preview browser",
              lifecycleStatus: "inProgress",
              live: true,
            },
          ],
        },
      ]);

      const terminalThread = {
        ...thread,
        activities: [
          ...thread.activities,
          makeActivity({
            id: EventId.make("preview-click-completed"),
            kind: "tool.completed",
            tone: "tool",
            summary: "MCP tool call completed",
            createdAt: "2026-04-01T00:00:03.000Z",
            turnId,
            payload: { itemType: "mcp_tool_call", toolCallId, status, detail },
          }),
        ],
      };
      const terminalRows = present(terminalThread);
      expect(terminalRows).toMatchObject([
        {
          type: "work-toggle",
          groupId,
          hiddenCount: 1,
          expanded: true,
          summary: liveDisplayName,
          summaryToolIcon: "browser",
          hasFailure,
          live: true,
          // A successful trailing call keeps shining; a failure hands off to "Thinking".
          shimmer: !hasFailure,
        },
        {
          type: "activity-group",
          id: `work-details:${groupId}`,
          activities: [
            {
              id: "preview-click-started",
              summary: displayName,
              lifecycleStatus: status,
              live: false,
            },
          ],
        },
        ...(hasFailure ? [{ type: "thinking", turnId }] : []),
      ]);
      const terminalGroup = terminalRows[1];
      if (terminalGroup?.type !== "activity-group") return;
      const activity = terminalGroup.activities[0]!;
      const fullDetail = `MCP call\n${JSON.stringify(toolData, null, 2)}\n\n${detail}`;
      expect(activity.workEntry.toolData).toBe(toolData);
      expect(activity.getFullDetail()).toBe(fullDetail);
      expect(activity.getCopyText()).toBe(`MCP tool call\n${detail}\n${fullDetail}`);

      const settledRows = present({
        ...terminalThread,
        latestTurn: {
          ...thread.latestTurn!,
          state: "completed",
          completedAt: "2026-04-01T00:00:04.000Z",
        },
      });
      expect(settledRows.find((entry) => entry.type === "work-toggle")).toMatchObject({
        groupId,
        hiddenCount: 1,
        expanded: true,
        summary: displayName,
        summaryKind: "browser",
        hasFailure,
        live: false,
      });
      expect(settledRows.find((entry) => entry.type === "activity-group")).toMatchObject({
        id: `work-details:${groupId}`,
        activities: [{ id: "preview-click-started", summary: displayName, live: false }],
      });
    },
  );

  it.each([
    [0, "Used browser 3 times", "browser"],
    [2, "Ran 2 commands and used browser 3 times", "mixed"],
  ] as const)(
    "separates browser counts from %s completed commands",
    (commandCount, summary, summaryKind) => {
      const thread = makeThread({
        id: ThreadId.make("thread-browser-counts"),
        projectId: ProjectId.make("project-1"),
        title: "Browser group counts",
        activities: Array.from({ length: commandCount + 3 }, (_, index) =>
          makeActivity({
            id: EventId.make(`browser-count-${index}`),
            createdAt: new Date(Date.UTC(2026, 3, 1, 0, 0, index)).toISOString(),
            kind: "tool.completed",
            tone: "tool",
            summary: index < commandCount ? "Ran command" : "MCP tool call",
            payload: {
              toolCallId: `browser-count-${index}`,
              status: "completed",
              ...(index < commandCount
                ? {
                    itemType: "command_execution",
                    data: { item: { command: "/bin/bash -lc 'vp test run'" } },
                  }
                : {
                    itemType: "mcp_tool_call",
                    data: { item: { server: "t3-code", tool: "preview_click" } },
                  }),
            },
          }),
        ),
      });
      expect(
        deriveThreadFeedPresentation(buildThreadFeed(thread), null, new Set(), new Set()),
      ).toMatchObject([{ type: "work-toggle", summary, summaryKind, live: false }]);
    },
  );

  it("defers large tool output expansion until a work row is opened or copied", () => {
    let serializedToolOutputs = 0;
    const activities = Array.from({ length: 5_000 }, (_, index) =>
      makeActivity({
        id: EventId.make(`large-tool-${index}`),
        kind: "tool.completed",
        tone: "tool",
        summary: `Tool ${index}`,
        createdAt: new Date(Date.UTC(2026, 3, 1, 0, 0, index)).toISOString(),
        payload: {
          title: `Tool ${index}`,
          itemType: "mcp_tool_call",
          status: "completed",
          data: {
            item: {
              toJSON: () => {
                serializedToolOutputs += 1;
                return { output: "x".repeat(32_768) };
              },
            },
          },
        },
      }),
    );
    const thread = makeThread({
      id: ThreadId.make("thread-large-tools"),
      projectId: ProjectId.make("project-1"),
      title: "Large tools",
      activities,
    });

    const feed = buildThreadFeed(thread);
    expect(serializedToolOutputs).toBe(0);

    const group = feed[0];
    expect(group).toMatchObject({ type: "activity-group" });
    if (!group || group.type !== "activity-group") {
      return;
    }

    expect(group.activities).toHaveLength(5_000);
    const expanded = deriveThreadFeedPresentation(
      feed,
      null,
      new Set(),
      new Set(["work-group:large-tool-0"]),
    );
    expect(expanded).toHaveLength(2);
    expect(expanded[1]).toMatchObject({
      type: "activity-group",
      id: "work-details:work-group:large-tool-0",
    });
    if (expanded[1]?.type === "activity-group") {
      expect(expanded[1].activities).toHaveLength(5_000);
      expect(expanded[1].activities[0]?.getFullDetail).toBe(group.activities[0]?.getFullDetail);
    }
    expect(serializedToolOutputs).toBe(0);
    expect(group.activities[0]?.getFullDetail()).toContain('"output"');
    expect(serializedToolOutputs).toBe(1);
    expect(group.activities[0]?.getCopyText()).toContain('"output"');
    expect(serializedToolOutputs).toBe(1);
  });

  it("keeps the first and terminal assistant messages visible around settled work", () => {
    const turnId = TurnId.make("turn-1");
    const thread = makeThread({
      id: ThreadId.make("thread-3"),
      projectId: ProjectId.make("project-1"),
      title: "Folded work",
      latestTurn: {
        turnId,
        state: "completed",
        requestedAt: "2026-04-01T00:00:00.000Z",
        startedAt: "2026-04-01T00:00:01.000Z",
        completedAt: "2026-04-01T00:00:18.000Z",
        assistantMessageId: MessageId.make("assistant-final"),
      },
      messages: [
        {
          id: MessageId.make("assistant-first"),
          role: "assistant",
          text: "Synthetic deployment checklist\n1. Confirm the deployment is ready.",
          turnId,
          streaming: false,
          createdAt: "2026-04-01T00:00:02.000Z",
          updatedAt: "2026-04-01T00:00:03.000Z",
        },
        {
          id: MessageId.make("assistant-final"),
          role: "assistant",
          text: "Done.",
          turnId,
          streaming: false,
          createdAt: "2026-04-01T00:00:17.000Z",
          updatedAt: "2026-04-01T00:00:18.000Z",
        },
      ],
      activities: [
        makeActivity({
          id: EventId.make("tool-completed"),
          kind: "tool.completed",
          tone: "tool",
          summary: "Read files",
          createdAt: "2026-04-01T00:00:05.000Z",
          turnId,
          payload: {
            title: "Read files",
            itemType: "file_read",
            status: "completed",
          },
        }),
      ],
    });

    const feed = buildThreadFeed(thread);
    const collapsed = deriveThreadFeedPresentation(feed, thread.latestTurn, new Set());
    expect(collapsed.map((entry) => entry.id)).toEqual([
      "assistant-first",
      "turn-fold:turn-1",
      "assistant-final",
    ]);
    expect(collapsed[1]).toMatchObject({
      type: "turn-fold",
      label: "Worked for 17s",
      expanded: false,
    });

    const expanded = deriveThreadFeedPresentation(feed, thread.latestTurn, new Set([turnId]));
    expect(expanded.map((entry) => entry.id)).toEqual([
      "assistant-first",
      "turn-fold:turn-1",
      "work-toggle:work-group:tool-completed",
      "assistant-final",
    ]);

    const interrupted = deriveThreadFeedPresentation(
      feed,
      { ...thread.latestTurn!, state: "interrupted", completedAt: "2026-04-01T00:00:20.000Z" },
      new Set(),
    );
    expect(interrupted[1]).toMatchObject({
      type: "turn-fold",
      label: "You stopped after 19s",
      expanded: false,
    });
    const retimed = deriveThreadFeedPresentation(
      buildThreadFeed({
        ...thread,
        messages: [
          thread.messages[0]!,
          { ...thread.messages[1]!, updatedAt: "2026-04-01T00:00:25.000Z" },
        ],
      }),
      null,
      new Set(),
    );
    expect(retimed[1]).toMatchObject({ type: "turn-fold", label: "Worked for 23s" });
    expect(collapsed[1]).toMatchObject({ type: "turn-fold", label: "Worked for 17s" });
  });

  it("folds assistant messages between the first and terminal messages", () => {
    const turnId = TurnId.make("turn-1");
    const thread = makeThread({
      id: ThreadId.make("thread-middle-message"),
      projectId: ProjectId.make("project-1"),
      title: "Bounded narration",
      latestTurn: {
        turnId,
        state: "completed",
        requestedAt: "2026-04-01T00:00:00.000Z",
        startedAt: "2026-04-01T00:00:01.000Z",
        completedAt: "2026-04-01T00:00:06.000Z",
        assistantMessageId: MessageId.make("assistant-final"),
      },
      messages: [
        {
          id: MessageId.make("assistant-first"),
          role: "assistant",
          text: "The main result is ready.",
          turnId,
          streaming: false,
          createdAt: "2026-04-01T00:00:01.000Z",
          updatedAt: "2026-04-01T00:00:02.000Z",
        },
        {
          id: MessageId.make("assistant-middle"),
          role: "assistant",
          text: "I am checking one more detail.",
          turnId,
          streaming: false,
          createdAt: "2026-04-01T00:00:03.000Z",
          updatedAt: "2026-04-01T00:00:04.000Z",
        },
        {
          id: MessageId.make("assistant-final"),
          role: "assistant",
          text: "Verification finished.",
          turnId,
          streaming: false,
          createdAt: "2026-04-01T00:00:05.000Z",
          updatedAt: "2026-04-01T00:00:06.000Z",
        },
      ],
    });

    const feed = buildThreadFeed(thread);
    const rows = deriveThreadFeedPresentation(feed, thread.latestTurn, new Set());

    expect(rows.map((entry) => entry.id)).toEqual([
      "assistant-first",
      "turn-fold:turn-1",
      "assistant-final",
    ]);
  });

  it("measures a steer-superseded turn from its user boundary through trailing work", () => {
    const firstTurnId = TurnId.make("turn-1");
    const secondTurnId = TurnId.make("turn-2");
    const thread = makeThread({
      id: ThreadId.make("thread-steered"),
      projectId: ProjectId.make("project-1"),
      title: "Steered work",
      latestTurn: {
        turnId: secondTurnId,
        state: "running",
        requestedAt: "2026-04-01T00:00:14.000Z",
        startedAt: "2026-04-01T00:00:14.000Z",
        completedAt: null,
        assistantMessageId: MessageId.make("assistant-next"),
      },
      messages: [
        {
          id: MessageId.make("user-1"),
          role: "user",
          text: "Do it once more.",
          turnId: null,
          streaming: false,
          createdAt: "2026-04-01T00:00:00.000Z",
          updatedAt: "2026-04-01T00:00:00.000Z",
        },
        {
          id: MessageId.make("assistant-commentary"),
          role: "assistant",
          text: "Kicking off call 1.",
          turnId: firstTurnId,
          streaming: false,
          createdAt: "2026-04-01T00:00:09.000Z",
          updatedAt: "2026-04-01T00:00:09.000Z",
        },
        {
          id: MessageId.make("user-2"),
          role: "user",
          text: "Actually do 15.",
          turnId: null,
          streaming: false,
          createdAt: "2026-04-01T00:00:14.000Z",
          updatedAt: "2026-04-01T00:00:14.000Z",
        },
        {
          id: MessageId.make("assistant-next"),
          role: "assistant",
          text: "One down - adjusting.",
          turnId: secondTurnId,
          streaming: true,
          createdAt: "2026-04-01T00:00:17.000Z",
          updatedAt: "2026-04-01T00:00:17.000Z",
        },
      ],
      activities: [
        makeActivity({
          id: EventId.make("work-1"),
          kind: "tool.completed",
          tone: "tool",
          summary: "Ran command",
          createdAt: "2026-04-01T00:00:12.000Z",
          turnId: firstTurnId,
          payload: {
            title: "Ran command",
            itemType: "command_execution",
            status: "completed",
          },
        }),
      ],
    });

    const feed = buildThreadFeed(thread);
    const collapsed = deriveThreadFeedPresentation(feed, thread.latestTurn, new Set());
    expect(collapsed.find((entry) => entry.type === "turn-fold")).toMatchObject({
      turnId: firstTurnId,
      label: "Worked for 12s",
    });
  });

  it("keeps an active turn expanded and classifies error-shaped tool output", () => {
    const turnId = TurnId.make("turn-running");
    const thread = makeThread({
      id: ThreadId.make("thread-4"),
      projectId: ProjectId.make("project-1"),
      title: "Running work",
      latestTurn: {
        turnId,
        state: "running",
        requestedAt: "2026-04-01T00:00:00.000Z",
        startedAt: "2026-04-01T00:00:01.000Z",
        completedAt: null,
        assistantMessageId: null,
      },
      activities: [
        makeActivity({
          id: EventId.make("tool-succeeded"),
          kind: "tool.completed",
          tone: "tool",
          summary: "Run command",
          createdAt: "2026-04-01T00:00:04.000Z",
          turnId,
          payload: {
            title: "Run command",
            itemType: "command_execution",
            detail: "done",
            status: "completed",
          },
        }),
        makeActivity({
          id: EventId.make("tool-failed"),
          kind: "tool.completed",
          tone: "tool",
          summary: "Run command",
          createdAt: "2026-04-01T00:00:05.000Z",
          turnId,
          payload: {
            title: "Run command",
            itemType: "command_execution",
            detail: "zsh: command not found: nope",
            status: "completed",
          },
        }),
      ],
    });

    const feed = buildThreadFeed(thread);
    expect(deriveThreadFeedPresentation(feed, thread.latestTurn, new Set())).toMatchObject([
      {
        type: "work-toggle",
        summary: "Ran 2 commands",
        hiddenCount: 2,
        hasFailure: true,
      },
    ]);
    expect(feed[0]).toMatchObject({
      type: "activity-group",
      activities: [{ status: "success" }, { status: "failure" }],
    });
    const expanded = deriveThreadFeedPresentation(
      feed,
      thread.latestTurn,
      new Set(),
      new Set(["work-group:tool-succeeded"]),
    );
    expect(expanded.map((entry) => entry.id)).toEqual([
      "work-toggle:work-group:tool-succeeded",
      "work-details:work-group:tool-succeeded",
    ]);
    expect(expanded[1]).toMatchObject({
      type: "activity-group",
      activities: [
        { id: "tool-succeeded", status: "success", groupedToolDetail: true },
        { id: "tool-failed", status: "failure", groupedToolDetail: true },
      ],
    });
  });

  it("keeps expanded work in one group with stable row identities", () => {
    const activity = (
      id: string,
      createdAt: string,
      status: ThreadFeedActivity["status"] = "success",
      toolSurface?: "browser" | "computer",
      toolIcon?: import("@infinitus/contracts").ToolActivityIcon,
    ): ThreadFeedActivity => ({
      id,
      createdAt,
      turnId: null,
      summary: `Tool ${id}`,
      detail: null,
      canExpand: false,
      getFullDetail: () => null,
      getCopyText: () => id,
      icon: "command",
      toolLike: true,
      status,
      workEntry: {
        id,
        createdAt,
        turnId: null,
        label: `Tool ${id}`,
        command: `command ${id}`,
        tone: "tool",
        ...(toolSurface ? { toolSurface } : {}),
        ...(toolIcon ? { toolIcon } : {}),
      },
    });
    const feed: ThreadFeedEntry[] = [
      {
        type: "activity-group",
        id: "work-group-1",
        createdAt: "2026-04-01T00:00:01.000Z",
        turnId: null,
        activities: [
          activity("activity-1", "2026-04-01T00:00:01.000Z"),
          activity("activity-neutral", "2026-04-01T00:00:02.000Z", "neutral"),
          activity("activity-2", "2026-04-01T00:00:03.000Z", "success", "browser"),
          activity("activity-3", "2026-04-01T00:00:04.000Z", "success", "computer", {
            _tag: "native-app",
            app: { _tag: "app-id", appId: "com.example.Editor" },
          }),
        ],
      },
    ];

    const collapsed = deriveThreadFeedPresentation(feed, null, new Set());
    expect(collapsed.map((entry) => entry.id)).toEqual(["work-toggle:work-group:activity-1"]);
    expect(collapsed[0]).toMatchObject({
      type: "work-toggle",
      groupId: "work-group:activity-1",
      hiddenCount: 3,
      expanded: false,
      summary: "Ran 3 commands",
      toolSurface: "computer",
      toolIcon: {
        _tag: "native-app",
        app: { _tag: "app-id", appId: "com.example.Editor" },
      },
    });

    const expanded = deriveThreadFeedPresentation(
      feed,
      null,
      new Set(),
      new Set(["work-group:activity-1"]),
    );
    expect(expanded.map((entry) => entry.id)).toEqual([
      "work-toggle:work-group:activity-1",
      "work-details:work-group:activity-1",
    ]);
    expect(expanded[0]).toMatchObject({
      type: "work-toggle",
      expanded: true,
    });
    expect(expanded[1]).toMatchObject({
      type: "activity-group",
      activities: [
        { id: "activity-1", groupedToolDetail: true, live: false },
        { id: "activity-2", groupedToolDetail: true, live: false },
        { id: "activity-3", groupedToolDetail: true, live: false },
      ],
    });
    const unchanged = deriveThreadFeedPresentation(
      feed,
      null,
      new Set(),
      new Set(["work-group:activity-1", "unrelated-group"]),
    );
    expect(unchanged[0]).toBe(expanded[0]);
    expect(unchanged[1]).toBe(expanded[1]);
    expect(deriveThreadFeedPresentation(feed, null, new Set())).toEqual(collapsed);
  });

  it.each(
    [
      "sudo -u root pnpm test",
      "/bin/zsh -lc 'sudo -u root pnpm test'",
      "/bin/bash -lc 'sudo -u root pnpm test'",
    ].flatMap((command) =>
      (
        [
          { lifecycleStatus: "inProgress", summary: "Running pnpm", shimmer: true },
          { lifecycleStatus: "completed", summary: "Running pnpm", shimmer: true },
          { lifecycleStatus: "failed", summary: "Failed pnpm", shimmer: false },
          { lifecycleStatus: "declined", summary: "Declined pnpm", shimmer: false },
          { lifecycleStatus: "stopped", summary: "Stopped pnpm", shimmer: false },
        ] as const
      ).map((state) => ({ command, ...state })),
    ),
  )(
    "keeps the command summary in sync with $lifecycleStatus: $command",
    ({ command, lifecycleStatus, summary, shimmer }) => {
      const turnId = TurnId.make("turn-live-tools");
      const activity = (
        id: string,
        status: ThreadFeedActivity["status"],
        lifecycleStatus: ThreadFeedActivity["lifecycleStatus"],
        tone: "tool" | "error" = "tool",
        command?: string,
      ): ThreadFeedActivity => ({
        id,
        createdAt: `2026-04-01T00:00:0${id.at(-1)}.000Z`,
        turnId,
        summary: `Tool ${id}`,
        detail: lifecycleStatus === "stopped" ? "Exit code 130" : null,
        canExpand: false,
        getFullDetail: () => null,
        getCopyText: () => id,
        icon: "command",
        toolLike: true,
        status,
        lifecycleStatus,
        workEntry: {
          id,
          createdAt: `2026-04-01T00:00:0${id.at(-1)}.000Z`,
          turnId,
          label: `Tool ${id}`,
          tone,
          toolLifecycleStatus: lifecycleStatus,
          ...(lifecycleStatus === "stopped" ? { detail: "Exit code 130" } : {}),
          ...(command ? { command, itemType: "command_execution" as const } : {}),
        },
      });
      const feed: ThreadFeedEntry[] = [
        {
          type: "activity-group",
          id: "activity-1",
          createdAt: "2026-04-01T00:00:01.000Z",
          turnId,
          activities: [
            activity("activity-1", "success", "completed"),
            activity("activity-2", "failure", "failed", "error"),
            activity(
              "activity-3",
              lifecycleStatus === "inProgress"
                ? "neutral"
                : lifecycleStatus === "completed"
                  ? "success"
                  : "failure",
              lifecycleStatus,
              "tool",
              command,
            ),
            ...(lifecycleStatus === "inProgress"
              ? [activity("activity-4", "success", "completed", "tool", "printf done")]
              : []),
          ],
        },
      ];
      const latestTurn = {
        turnId,
        state: "running" as const,
        requestedAt: "2026-04-01T00:00:00.000Z",
        startedAt: "2026-04-01T00:00:00.000Z",
        completedAt: null,
        assistantMessageId: null,
      };

      const rows = deriveThreadFeedPresentation(
        feed,
        latestTurn,
        new Set(),
        new Set(),
        latestTurn.startedAt,
      );
      // The shimmering row is the turn's live slot; once it stops shimmering
      // the slot belongs to "Thinking" and the group keeps its own identity.
      expect(rows.slice(0, 3).map((entry) => [entry.id, entry.type])).toEqual([
        ["work-toggle:work-group:activity-1", "work-toggle"],
        ["activity-2", "activity-group"],
        [shimmer ? "live-activity-row" : "work-live:work-group:activity-3", "work-toggle"],
      ]);
      expect(rows.slice(0, 3).map((entry) => entry.type === "work-toggle" && entry.live)).toEqual([
        false,
        false,
        true,
      ]);
      expect(rows[2]).toMatchObject({
        summary,
        summaryKind: "command",
        live: true,
        shimmer,
      });
      expect(rows[0]).toMatchObject({ live: false, shimmer: false });
      // Exactly one live activity: the shimmering call, or "Thinking" once it fails.
      expect(rows.filter((entry) => entry.type === "thinking")).toHaveLength(shimmer ? 0 : 1);
      expect(rows.at(-1)?.type).toBe(shimmer ? "work-toggle" : "thinking");

      const stoppedRows = deriveThreadFeedPresentation(feed, latestTurn, new Set());
      expect(stoppedRows.some((entry) => entry.type === "thinking")).toBe(false);
      expect(stoppedRows.filter((entry) => entry.type === "work-toggle")).toMatchObject([
        { live: false, shimmer: false },
        {
          live: false,
          shimmer: false,
          summary: lifecycleStatus === "inProgress" ? "printf done" : command,
        },
      ]);

      const completedRows = deriveThreadFeedPresentation(
        feed,
        { ...latestTurn, state: "completed", completedAt: "2026-04-01T00:00:04.000Z" },
        new Set([turnId]),
        new Set(),
        latestTurn.startedAt,
      );
      expect(completedRows.filter((entry) => entry.type === "work-toggle")).toMatchObject([
        { live: false, shimmer: false },
        { live: false, shimmer: false },
      ]);
    },
  );

  it("groups ordered reasoning blocks, keeps the live slot, and restores the group after unfolding", () => {
    const turnId = TurnId.make("reasoning-group");
    const messages: OrchestrationThread["messages"] = [1, 2, 3, 4].map((second) => ({
      id: MessageId.make(`reasoning-${second}`),
      role: "reasoning",
      text: `**Step ${second}**\n\nCheck ${second}.`,
      turnId,
      streaming: second === 4,
      createdAt: `2026-04-01T00:00:0${second}.000Z`,
      updatedAt: `2026-04-01T00:00:0${second}.000Z`,
    }));
    const thread = makeThread({
      id: ThreadId.make("reasoning-group"),
      projectId: ProjectId.make("project-1"),
      title: "Reasoning",
      messages,
      latestTurn: {
        turnId,
        state: "running",
        requestedAt: "2026-04-01T00:00:00.000Z",
        startedAt: "2026-04-01T00:00:00.000Z",
        completedAt: null,
        assistantMessageId: null,
      },
    });
    const feed = buildThreadFeed(thread);
    const rows = deriveThreadFeedPresentation(feed, thread.latestTurn, new Set(), new Set(), "now");
    expect(rows).toMatchObject([
      { type: "work-toggle", id: "live-activity-row", summary: "Thinking", hiddenCount: 4 },
    ]);
    expect(rows).toHaveLength(1);
    expect(
      deriveThreadFeedPresentation(feed, thread.latestTurn, new Set(), new Set(), "now")[0],
    ).toBe(rows[0]);

    const settledTurn = {
      ...thread.latestTurn!,
      state: "completed" as const,
      completedAt: "2026-04-01T00:00:06.000Z",
    };
    // Reasoning alone stays visible, including a streaming flag left behind on settlement.
    expect(deriveThreadFeedPresentation(feed, settledTurn, new Set())).toMatchObject([
      { type: "work-toggle", summary: "Thought (×4)", hiddenCount: 4 },
    ]);
    const completedMessages = messages.map((message) => ({ ...message, streaming: false }));
    const waiting = deriveThreadFeedPresentation(
      buildThreadFeed({ ...thread, messages: completedMessages }),
      thread.latestTurn,
      new Set(),
      new Set(),
      "now",
    );
    expect(waiting).toMatchObject([
      { type: "work-toggle", id: "live-activity-row", summary: "Thinking", hiddenCount: 4 },
    ]);
    const feedWithWork = buildThreadFeed({
      ...thread,
      activities: [
        makeActivity({
          id: EventId.make("reasoning-tool"),
          kind: "tool.completed",
          tone: "tool",
          summary: "Read files",
          createdAt: "2026-04-01T00:00:05.000Z",
          turnId,
          payload: { itemType: "file_read", status: "completed" },
        }),
      ],
    });
    const toolRunning = deriveThreadFeedPresentation(
      feedWithWork,
      thread.latestTurn,
      new Set(),
      new Set(),
      "now",
    );
    expect(toolRunning).toMatchObject([
      { type: "work-toggle", id: "live-activity-row", shimmer: true, hiddenCount: 5 },
    ]);
    expect(toolRunning[0]).not.toMatchObject({ summary: "Thinking" });
    const nextThought = {
      ...messages[3]!,
      id: MessageId.make("reasoning-after-tool"),
      createdAt: "2026-04-01T00:00:06.000Z",
      updatedAt: "2026-04-01T00:00:06.000Z",
    };
    const reasoningAgainFeed: ThreadFeedEntry[] = [
      ...feedWithWork,
      {
        type: "message",
        id: nextThought.id,
        createdAt: nextThought.createdAt,
        message: nextThought,
      },
    ];
    const reasoningAgain = deriveThreadFeedPresentation(
      reasoningAgainFeed,
      thread.latestTurn,
      new Set(),
      new Set(),
      "now",
    );
    expect(reasoningAgain.filter((row) => row.id === "live-activity-row")).toMatchObject([
      { type: "work-toggle", summary: "Thinking", hiddenCount: 6 },
    ]);
    expect(reasoningAgain).toHaveLength(1);
    const expandedLive = deriveThreadFeedPresentation(
      reasoningAgainFeed,
      thread.latestTurn,
      new Set(),
      new Set([`activity-run:${messages[0]!.id}`]),
      "now",
    );
    expect(expandedLive.map((entry) => entry.type)).toEqual([
      "work-toggle",
      "message",
      "activity-group",
      "message",
    ]);
    expect(expandedLive[1]).toMatchObject({ reasoningMessages: messages });
    expect(expandedLive[3]).toMatchObject({ message: nextThought });
    expect(deriveThreadFeedPresentation(feedWithWork, settledTurn, new Set())).toMatchObject([
      { type: "turn-fold", expanded: false },
    ]);
    const reopened = deriveThreadFeedPresentation(
      feedWithWork,
      settledTurn,
      new Set([turnId]),
      new Set([`activity-run:${messages[0]!.id}`]),
    );
    expect(reopened.map((entry) => entry.type)).toEqual([
      "turn-fold",
      "work-toggle",
      "message",
      "activity-group",
    ]);
    expect(reopened[2]).toMatchObject({ id: messages[0]!.id, reasoningMessages: messages });
    const toolFirstFeed = feedWithWork.filter((entry) => entry.type === "activity-group");
    const toolFirst = deriveThreadFeedPresentation(
      toolFirstFeed,
      thread.latestTurn,
      new Set(),
      new Set(),
      "now",
    )[0];
    expect(toolFirst?.type).toBe("work-toggle");
    if (toolFirst?.type !== "work-toggle") return;
    const preservedExpansion = deriveThreadFeedPresentation(
      [...toolFirstFeed, reasoningAgainFeed.at(-1)!],
      thread.latestTurn,
      new Set(),
      new Set([toolFirst.groupId]),
      "now",
    );
    expect(preservedExpansion.map((entry) => entry.type)).toEqual([
      "work-toggle",
      "activity-group",
      "message",
    ]);
    expect(preservedExpansion[0]).toMatchObject({
      id: "live-activity-row",
      groupId: toolFirst.groupId,
      expanded: true,
      summary: "Thinking",
    });
    const strandedToolFeed = buildThreadFeed({
      ...thread,
      messages: [],
      activities: [
        makeActivity({
          id: EventId.make("stranded-tool"),
          kind: "tool.updated",
          tone: "tool",
          summary: "Running command",
          createdAt: "2026-04-01T00:00:00.000Z",
          turnId,
          payload: {
            toolCallId: "stranded-tool",
            itemType: "command_execution",
            command: "sleep 60",
            status: "inProgress",
          },
        }),
      ],
    });
    const afterStrandedTool = deriveThreadFeedPresentation(
      [...strandedToolFeed, ...feedWithWork],
      thread.latestTurn,
      new Set(),
      new Set(),
      "now",
    );
    expect(afterStrandedTool).toMatchObject([
      { type: "work-toggle", id: "live-activity-row", summary: toolFirst.summary, hiddenCount: 6 },
    ]);
  });

  it.each(["tool", "failed-tool", "assistant", "turn", "unknown-turn"] as const)(
    "keeps thoughts in order across a %s in expanded activity history",
    (boundary) => {
      const turnId = TurnId.make("reasoning-boundary");
      const messages: OrchestrationThread["messages"] = [1, 3].map((second) => ({
        id: MessageId.make(`reasoning-${second}`),
        role: "reasoning",
        text: `Step ${second}`,
        turnId:
          boundary === "unknown-turn"
            ? null
            : boundary === "turn" && second === 3
              ? TurnId.make("other-turn")
              : turnId,
        streaming: false,
        createdAt: `2026-04-01T00:00:0${second}.000Z`,
        updatedAt: `2026-04-01T00:00:0${second}.000Z`,
      }));
      const thread = makeThread({
        id: ThreadId.make("reasoning-boundary"),
        projectId: ProjectId.make("project-1"),
        title: "Reasoning",
        messages:
          boundary === "assistant"
            ? [
                messages[0]!,
                {
                  ...messages[0]!,
                  id: MessageId.make("assistant-between"),
                  role: "assistant",
                  text: "Checking the next file.",
                  createdAt: "2026-04-01T00:00:02.000Z",
                },
                messages[1]!,
              ]
            : messages,
        activities:
          boundary === "tool" || boundary === "failed-tool"
            ? [
                makeActivity({
                  id: EventId.make("tool-between"),
                  kind: "tool.completed",
                  tone: "tool",
                  summary: "Read files",
                  createdAt: "2026-04-01T00:00:02.000Z",
                  turnId,
                  payload: {
                    itemType: "file_read",
                    status: boundary === "failed-tool" ? "failed" : "completed",
                  },
                }),
              ]
            : [],
      });
      const rows = deriveThreadFeedPresentation(
        buildThreadFeed(thread),
        null,
        new Set([turnId]),
        new Set(messages.map((message) => `activity-run:${message.id}`)),
      );
      const reasoningRows = rows.filter(
        (entry) => entry.type === "message" && entry.message.role === "reasoning",
      );
      if (boundary === "failed-tool") {
        // A failed call stays inside the run instead of splitting it.
        expect(rows.filter((entry) => entry.type === "work-toggle")).toMatchObject([
          { hasFailure: true, hiddenCount: 3 },
        ]);
      }
      expect(reasoningRows).toEqual(
        messages.map((message) => ({
          type: "message",
          id: message.id,
          createdAt: message.createdAt,
          message,
        })),
      );
    },
  );

  it("shows one Thinking row while a turn works without live tool activity", () => {
    const turnId = TurnId.make("turn-thinking");
    const latestTurn = {
      turnId,
      state: "running" as const,
      requestedAt: "2026-04-01T00:00:00.000Z",
      startedAt: "2026-04-01T00:00:00.000Z",
      completedAt: null,
      assistantMessageId: null,
    };
    const feed = buildThreadFeed(
      makeThread({
        id: ThreadId.make("thread-thinking"),
        projectId: ProjectId.make("project-1"),
        title: "Thinking",
        latestTurn,
        messages: [
          {
            id: MessageId.make("user-1"),
            role: "user",
            text: "hello",
            turnId,
            streaming: false,
            createdAt: "2026-04-01T00:00:00.000Z",
            updatedAt: "2026-04-01T00:00:00.000Z",
          },
        ],
      }),
    );

    const rows = deriveThreadFeedPresentation(feed, latestTurn, new Set(), new Set(), "now");
    expect(rows.map((entry) => entry.type)).toEqual(["message", "thinking"]);
    expect(rows[1]).toMatchObject({ id: "live-activity-row", createdAt: "now", turnId });
    // The row identity is stable across re-derivations so the list can reuse it.
    expect(deriveThreadFeedPresentation(feed, latestTurn, new Set(), new Set(), "now")[1]).toBe(
      rows[1],
    );
    // Idle threads show no live activity.
    expect(
      deriveThreadFeedPresentation(feed, latestTurn, new Set(), new Set(), null).map(
        (entry) => entry.type,
      ),
    ).toEqual(["message"]);
  });

  it("keeps one live slot while calls fail and restart", () => {
    // Recorded from a Claude session whose Bash was broken: every call went
    // inProgress → failed within two seconds. Each transition used to insert
    // or remove a Thinking row under the group; now the same row id holds
    // the live call and then "Thinking", so the list updates it in place.
    const turnId = TurnId.make("turn-failing-calls");
    const latestTurn = {
      turnId,
      state: "running" as const,
      requestedAt: "2026-04-01T00:00:00.000Z",
      startedAt: "2026-04-01T00:00:00.000Z",
      completedAt: null,
      assistantMessageId: null,
    };
    const call = (n: number, status: "inProgress" | "failed") =>
      makeActivity({
        id: EventId.make(`call-${n}-${status}`),
        kind: status === "failed" ? "tool.completed" : "tool.updated",
        tone: "tool",
        summary: "Command run",
        createdAt: `2026-04-01T00:00:${String(n * 2 + (status === "failed" ? 1 : 0)).padStart(2, "0")}.000Z`,
        turnId,
        payload: {
          itemType: "command_execution",
          toolCallId: `call-${n}`,
          title: "Command run",
          status,
          detail: `Bash: ls ${n}`,
        },
      });
    const liveIds = (activities: ReadonlyArray<ReturnType<typeof makeActivity>>) =>
      deriveThreadFeedPresentation(
        buildThreadFeed(
          makeThread({
            id: ThreadId.make("thread-failing-calls"),
            projectId: ProjectId.make("project-1"),
            title: "Failing calls",
            latestTurn,
            activities,
          }),
        ),
        latestTurn,
        new Set(),
        new Set(),
        latestTurn.startedAt,
      ).map((row) => `${row.type}:${row.id}`);

    expect(liveIds([call(1, "inProgress")])).toEqual(["work-toggle:live-activity-row"]);
    expect(liveIds([call(1, "inProgress"), call(1, "failed")])).toEqual([
      "work-toggle:work-live:work-group:tool:turn-failing-calls:call-1",
      "thinking:live-activity-row",
    ]);
    expect(liveIds([call(1, "inProgress"), call(1, "failed"), call(2, "inProgress")])).toEqual([
      "work-toggle:live-activity-row",
    ]);
    // A call whose end was never reported, in a run before an error row,
    // keeps its own identity: only the trailing run can hold the live slot.
    const errorRow = makeActivity({
      id: EventId.make("runtime-error"),
      kind: "runtime.error",
      tone: "error",
      summary: "Provider error",
      createdAt: "2026-04-01T00:00:02.500Z",
      turnId,
      payload: { message: "boom" },
    });
    expect(liveIds([call(1, "inProgress"), errorRow, call(2, "inProgress")])).toEqual([
      "work-toggle:work-live:work-group:tool:turn-failing-calls:call-1",
      "activity-group:runtime-error",
      "work-toggle:live-activity-row",
    ]);
  });

  it("hands a settled tool run off to Thinking once assistant text streams after it", () => {
    const turnId = TurnId.make("turn-streaming-tail");
    const latestTurn = {
      turnId,
      state: "running" as const,
      requestedAt: "2026-04-01T00:00:00.000Z",
      startedAt: "2026-04-01T00:00:00.000Z",
      completedAt: null,
      assistantMessageId: null,
    };
    const feed = buildThreadFeed(
      makeThread({
        id: ThreadId.make("thread-streaming-tail"),
        projectId: ProjectId.make("project-1"),
        title: "Streaming tail",
        latestTurn,
        messages: [
          {
            id: MessageId.make("assistant-1"),
            role: "assistant",
            text: "Here is what I found",
            turnId,
            streaming: true,
            createdAt: "2026-04-01T00:00:05.000Z",
            updatedAt: "2026-04-01T00:00:06.000Z",
          },
        ],
        activities: [
          makeActivity({
            id: EventId.make("read-completed"),
            kind: "tool.completed",
            tone: "tool",
            summary: "Read file",
            createdAt: "2026-04-01T00:00:02.000Z",
            turnId,
            payload: {
              itemType: "file_read",
              toolCallId: "read-1",
              title: "Read file",
              status: "completed",
              detail: "src/index.ts",
            },
          }),
        ],
      }),
    );

    const rows = deriveThreadFeedPresentation(
      feed,
      latestTurn,
      new Set(),
      new Set(),
      latestTurn.startedAt,
    );
    expect(rows.map((entry) => entry.type)).toEqual(["work-toggle", "message", "thinking"]);
    expect(rows[0]).toMatchObject({ live: false, shimmer: false });
  });

  it("preserves serialized shell wrappers with non-matching boundary quotes", () => {
    const turnId = TurnId.make("turn-serialized-shell-wrapper");
    const command =
      "/bin/zsh -lc 'git status\nsed -n '\"'1,20p' apps/web/src/components/DiffPanel.tsx\"";
    const thread = makeThread({
      id: ThreadId.make("thread-serialized-shell-wrapper"),
      projectId: ProjectId.make("project-1"),
      title: "Serialized shell wrapper",
      latestTurn: {
        turnId,
        state: "running",
        requestedAt: "2026-04-01T00:00:00.000Z",
        startedAt: "2026-04-01T00:00:00.000Z",
        completedAt: null,
        assistantMessageId: null,
      },
      activities: [
        makeActivity({
          id: EventId.make("serialized-shell-wrapper"),
          kind: "tool.updated",
          tone: "tool",
          summary: "Ran command",
          createdAt: "2026-04-01T00:00:01.000Z",
          turnId,
          payload: {
            itemType: "command_execution",
            status: "inProgress",
            data: { item: { command } },
          },
        }),
      ],
    });

    const feed = buildThreadFeed(thread);
    expect(feed[0]).toMatchObject({
      type: "activity-group",
      activities: [{ workEntry: { command } }],
    });
    if (feed[0]?.type === "activity-group") {
      expect(feed[0].activities[0]?.workEntry.rawCommand).toBeUndefined();
    }
  });

  it.each([
    ["inProgress", true],
    ["completed", false],
    ["failed", false],
    ["declined", false],
    ["stopped", false],
  ] as const)("respects the %s lifecycle of trailing task progress", (status, shimmer) => {
    const turnId = TurnId.make("turn-task-progress");
    const thread = makeThread({
      id: ThreadId.make("thread-task-progress"),
      projectId: ProjectId.make("project-1"),
      title: "Task lifecycle",
      latestTurn: {
        turnId,
        state: "running",
        requestedAt: "2026-04-01T00:00:00.000Z",
        startedAt: "2026-04-01T00:00:01.000Z",
        completedAt: null,
        assistantMessageId: null,
      },
      activities: [
        makeActivity({
          id: EventId.make("task-progress"),
          kind: "task.progress",
          summary: "Task progress",
          createdAt: "2026-04-01T00:00:02.000Z",
          turnId,
          payload: { taskId: "task-1", status },
        }),
      ],
    });

    const rows = deriveThreadFeedPresentation(
      buildThreadFeed(thread),
      thread.latestTurn,
      new Set(),
      new Set(),
      thread.latestTurn!.startedAt,
    );
    expect(rows.some((entry) => entry.type === "work-toggle" && entry.shimmer)).toBe(shimmer);
  });

  it("does not revive cached in-progress tools after work stops", () => {
    const turnId = TurnId.make("turn-stale-tool");
    const feed: ThreadFeedEntry[] = [
      {
        type: "activity-group",
        id: "stale-tool",
        createdAt: "2026-04-01T00:00:01.000Z",
        turnId,
        activities: [
          {
            id: "stale-tool",
            createdAt: "2026-04-01T00:00:01.000Z",
            turnId,
            summary: "Running tests",
            detail: null,
            canExpand: false,
            getFullDetail: () => null,
            getCopyText: () => "",
            icon: "command",
            toolLike: true,
            status: "neutral",
            lifecycleStatus: "inProgress",
            workEntry: {
              id: "stale-tool",
              createdAt: "2026-04-01T00:00:01.000Z",
              turnId,
              label: "Running tests",
              tone: "tool",
              toolLifecycleStatus: "inProgress",
            },
          },
        ],
      },
    ];
    const latestTurn = {
      turnId,
      state: "running" as const,
      requestedAt: "2026-04-01T00:00:00.000Z",
      startedAt: "2026-04-01T00:00:00.000Z",
      completedAt: null,
      assistantMessageId: null,
    };

    expect(deriveThreadFeedPresentation(feed, latestTurn, new Set())).toEqual([]);
    expect(
      deriveThreadFeedPresentation(feed, latestTurn, new Set(), new Set(), latestTurn.startedAt),
    ).toMatchObject([{ type: "work-toggle", live: true, shimmer: true }]);
  });

  it("collapses interleaved tool lifecycles by call identity", () => {
    const turnId = TurnId.make("turn-parallel-tools");
    const toolActivity = (
      id: string,
      toolCallId: string,
      kind: "tool.updated" | "tool.completed",
      status: "inProgress" | "completed",
      detail: string,
      nestedId = false,
    ) =>
      makeActivity({
        id: EventId.make(id),
        kind,
        tone: "tool",
        summary: `Run ${toolCallId} command`,
        createdAt: `2026-04-01T00:00:0${id.at(-1)}.000Z`,
        turnId,
        payload: {
          ...(nestedId ? { data: { toolCallId } } : { toolCallId }),
          itemType: "command_execution",
          status,
          detail,
        },
      });
    const thread = makeThread({
      id: ThreadId.make("thread-parallel-tools"),
      projectId: ProjectId.make("project-1"),
      title: "Parallel tools",
      activities: [
        toolActivity("call-a-1", "call-a", "tool.updated", "inProgress", "starting"),
        toolActivity("call-b-2", "call-b", "tool.updated", "inProgress", "starting", true),
        toolActivity("call-a-3", "call-a", "tool.completed", "completed", "first output"),
        toolActivity("call-b-4", "call-b", "tool.completed", "completed", "second output", true),
      ],
    });

    const feed = buildThreadFeed(thread);
    const activityGroup = feed.find((entry) => entry.type === "activity-group");
    expect(activityGroup).toMatchObject({
      type: "activity-group",
      activities: [
        { id: "call-a-1", lifecycleStatus: "completed", detail: "first output" },
        { id: "call-b-2", lifecycleStatus: "completed", detail: "second output" },
      ],
    });
    expect(
      deriveThreadFeedPresentation(feed, null, new Set([turnId])).find(
        (entry) => entry.type === "work-toggle",
      ),
    ).toMatchObject({
      type: "work-toggle",
      hiddenCount: 2,
      summary: "Ran 2 commands",
      live: false,
    });

    const groupId = `work-group:tool:${turnId}:call-a`;
    const startedAt = "2026-04-01T00:00:00.000Z";
    const runningRows = deriveThreadFeedPresentation(
      buildThreadFeed({ ...thread, activities: thread.activities.slice(0, 2) }),
      { turnId, state: "running", startedAt, completedAt: null },
      new Set(),
      new Set([groupId]),
      startedAt,
    );
    expect(runningRows.find((entry) => entry.type === "activity-group")).toMatchObject({
      id: `work-details:${groupId}`,
      activities: [
        { id: "call-a-1", lifecycleStatus: "inProgress", groupedToolDetail: true, live: false },
        { id: "call-b-2", lifecycleStatus: "inProgress", groupedToolDetail: true, live: true },
      ],
    });

    const completedRows = deriveThreadFeedPresentation(
      feed,
      null,
      new Set([turnId]),
      new Set([groupId]),
    );
    expect(completedRows.find((entry) => entry.type === "activity-group")).toMatchObject({
      id: `work-details:${groupId}`,
      activities: [
        { id: "call-a-1", lifecycleStatus: "completed", groupedToolDetail: true, live: false },
        { id: "call-b-2", lifecycleStatus: "completed", groupedToolDetail: true, live: false },
      ],
    });

    const correctedFeed = buildThreadFeed({
      ...thread,
      activities: thread.activities.map((activity) =>
        activity.id === "call-a-3"
          ? {
              ...activity,
              tone: "error",
              payload: {
                toolCallId: "call-a",
                itemType: "command_execution",
                status: "failed",
                detail: "Corrected failure output",
              },
            }
          : activity,
      ),
    });
    const correctedGroup = correctedFeed.find((entry) => entry.type === "activity-group");
    expect(correctedGroup).toMatchObject({
      activities: [
        { id: "call-a-1", lifecycleStatus: "failed", detail: "Corrected failure output" },
        { id: "call-b-2", lifecycleStatus: "completed", detail: "second output" },
      ],
    });
    expect(correctedGroup?.activities[0]?.getCopyText()).toContain("Corrected failure output");
    expect(activityGroup?.activities[0]?.getCopyText()).toContain("first output");
    const correctedRows = deriveThreadFeedPresentation(
      correctedFeed,
      null,
      new Set([turnId]),
      new Set([groupId]),
    );
    expect(correctedRows.find((entry) => entry.type === "activity-group")).toMatchObject({
      id: "call-a-1",
      activities: [{ status: "failure", workEntry: { tone: "error" } }],
    });
  });
  it("uses a Bash call's description as the row's headline, with the command beneath (#1231)", () => {
    const turnId = TurnId.make("turn-described-command");
    const thread = makeThread({
      id: ThreadId.make("thread-described-command"),
      projectId: ProjectId.make("project-1"),
      title: "Described command",
      activities: [
        makeActivity({
          id: EventId.make("described-started"),
          kind: "tool.started",
          tone: "tool",
          summary: "Command run",
          createdAt: "2026-09-01T00:00:00.000Z",
          turnId,
          payload: {
            toolCallId: "tool-described",
            itemType: "command_execution",
            status: "inProgress",
            data: { toolName: "Bash", command: "vp test run" },
          },
        }),
        makeActivity({
          id: EventId.make("described-completed"),
          kind: "tool.completed",
          tone: "tool",
          summary: "Command run",
          createdAt: "2026-09-01T00:00:01.000Z",
          turnId,
          payload: {
            toolCallId: "tool-described",
            itemType: "command_execution",
            status: "completed",
            data: { toolName: "Bash", command: "vp test run", description: "Run the\n web tests" },
          },
        }),
        makeActivity({
          id: EventId.make("plain-completed"),
          kind: "tool.completed",
          tone: "tool",
          summary: "Command run",
          createdAt: "2026-09-01T00:00:02.000Z",
          turnId,
          payload: {
            toolCallId: "tool-plain",
            itemType: "command_execution",
            status: "completed",
            data: { toolName: "Bash", command: "ls" },
          },
        }),
      ],
    });

    const [group] = buildThreadFeed(thread);
    expect(group?.type).toBe("activity-group");
    if (group?.type !== "activity-group") return;
    const [described, plain] = group.activities;
    expect(described?.workEntry).toMatchObject({
      command: "vp test run",
      commandDescription: "Run the web tests",
    });
    expect(workEntryRowLabel(described!.workEntry)).toBe("Run the web tests");
    expect(workEntryRowLabel(described!.workEntry, true)).toBe("Run the web tests");
    expect(described?.getFullDetail()?.startsWith("vp test run")).toBe(true);
    expect(plain?.workEntry.commandDescription).toBeUndefined();
    expect(workEntryRowLabel(plain!.workEntry)).toBe("ls");
  });
});

describe("quiet timeline: nested agents", () => {
  it.each(["task.updated", "task.progress"] as const)(
    "does not mark an ordinary task complete when it resumes through %s",
    (resumeKind) => {
      const thread = makeThread({
        id: ThreadId.make("resumed-agent"),
        projectId: ProjectId.make("project-1"),
        title: "Resumed agent",
        activities: (
          [
            ["task.progress", "running", "Review"],
            ["task.updated", "idle", "Task idle"],
            [resumeKind, "running", "Review resumed"],
          ] as const
        ).map(([kind, status, summary], index) =>
          makeActivity({
            id: EventId.make(`resumed-${index}`),
            kind,
            summary,
            createdAt: `2026-04-01T00:00:0${index + 1}.000Z`,
            payload: {
              taskId: "agent-1",
              agentKind: "agent",
              title: "Reviewer",
              status,
              detail: summary,
            },
          }),
        ),
      });
      const rows = buildThreadFeed(thread).flatMap((entry) =>
        entry.type === "activity-group" ? entry.activities : [],
      );
      // The agent folds into its spawn batch, which stays live after a resume.
      expect(rows).toMatchObject([
        {
          lifecycleStatus: "inProgress",
          summary: "Kicked off 1 subagent · 1 working",
          workEntry: { agentSpawn: { workflowId: null, agentTaskIds: ["agent-1"] } },
        },
      ]);
    },
  );

  it("folds a turn's direct spawns into one batch row that tracks their states", () => {
    const turnId = TurnId.make("turn-spawn");
    const agent = (
      id: string,
      kind: "task.started" | "task.progress" | "task.completed" | "task.updated",
      taskId: string,
      status: string,
      seconds: number,
      extra: Record<string, unknown> = {},
    ) =>
      makeActivity({
        id: EventId.make(id),
        kind,
        summary: `${taskId} ${status}`,
        createdAt: `2026-04-01T00:00:${String(seconds).padStart(2, "0")}.000Z`,
        turnId,
        payload: {
          taskId,
          agentKind: "agent",
          taskType: "local_agent",
          title: `Agent ${taskId}`,
          status,
          ...extra,
        },
      });
    const shell = makeActivity({
      id: EventId.make("shell-1"),
      kind: "task.completed",
      summary: "Task completed",
      createdAt: "2026-04-01T00:00:05.000Z",
      turnId,
      payload: {
        taskId: "sh-1",
        agentKind: "background",
        taskType: "local_bash",
        status: "completed",
        title: "Run tests",
        detail: "Run tests",
      },
    });
    const activities = [
      agent("a-start", "task.started", "a", "running", 1),
      agent("b-start", "task.started", "b", "running", 2),
      agent("a-progress", "task.progress", "a", "running", 3, { detail: "Reading files" }),
      shell,
      agent("b-progress", "task.progress", "b", "running", 6, { detail: "Grepping" }),
    ];
    const rowsFor = (extraActivities: ReadonlyArray<ReturnType<typeof makeActivity>>) =>
      buildThreadFeed(
        makeThread({
          id: ThreadId.make("thread-spawn"),
          projectId: ProjectId.make("project-1"),
          title: "Spawns",
          activities: [...activities, ...extraActivities],
        }),
      ).flatMap((entry) => (entry.type === "activity-group" ? entry.activities : []));

    // The batch anchors on the first task.started: a fixed id and timestamp,
    // unlike progress ticks (which the server rewrites in place).
    const running = rowsFor([]);
    expect(running.map((row) => [row.id, row.summary])).toEqual([
      ["a-start", "Kicked off 2 subagents · 2 working"],
      ["shell-1", "Run tests"],
    ]);
    expect(running[0]).toMatchObject({
      createdAt: "2026-04-01T00:00:01.000Z",
      lifecycleStatus: "inProgress",
      workEntry: { agentSpawn: { agentTaskIds: ["a", "b"] } },
    });

    const oneDone = rowsFor([agent("a-done", "task.completed", "a", "completed", 7)]);
    expect(oneDone[0]).toMatchObject({
      id: "a-start",
      summary: "Kicked off 2 subagents · 1 working",
      lifecycleStatus: "inProgress",
    });

    const allDone = rowsFor([
      agent("a-done", "task.completed", "a", "completed", 7),
      agent("b-failed", "task.updated", "b", "failed", 8, { error: "boom" }),
    ]);
    expect(allDone[0]).toMatchObject({
      id: "a-start",
      summary: "Ran 2 subagents · 1 failed",
      lifecycleStatus: "failed",
      status: "failure",
    });
    expect(allDone).toHaveLength(2);
  });

  it("folds the tool call that launched an agent into its spawn card", () => {
    const turnId = TurnId.make("turn-agent-tool");
    const at = (seconds: number) => `2026-04-01T00:00:${String(seconds).padStart(2, "0")}.000Z`;
    const feed = buildThreadFeed(
      makeThread({
        id: ThreadId.make("thread-agent-tool"),
        projectId: ProjectId.make("project-1"),
        title: "Agent tool",
        activities: [
          makeActivity({
            id: EventId.make("agent-call-updated"),
            kind: "tool.updated",
            tone: "tool",
            summary: "Subagent task",
            createdAt: at(1),
            turnId,
            payload: {
              itemType: "collab_agent_tool_call",
              toolCallId: "toolu_agent",
              status: "inProgress",
              title: "Subagent task",
              detail: "Locate code",
              data: { toolName: "Agent" },
            },
          }),
          makeActivity({
            id: EventId.make("agent-started"),
            kind: "task.started",
            summary: "Locate code",
            createdAt: at(2),
            turnId,
            payload: {
              taskId: "a1",
              agentKind: "agent",
              taskType: "local_agent",
              title: "Locate code",
              toolUseId: "toolu_agent",
            },
          }),
          makeActivity({
            id: EventId.make("agent-done"),
            kind: "task.completed",
            summary: "Locate code",
            createdAt: at(3),
            turnId,
            payload: {
              taskId: "a1",
              agentKind: "agent",
              taskType: "local_agent",
              title: "Locate code",
              toolUseId: "toolu_agent",
              status: "completed",
            },
          }),
          makeActivity({
            id: EventId.make("agent-call-completed"),
            kind: "tool.completed",
            tone: "tool",
            summary: "Subagent task",
            createdAt: at(4),
            turnId,
            payload: {
              itemType: "collab_agent_tool_call",
              toolCallId: "toolu_agent",
              status: "completed",
              title: "Subagent task",
              detail: "Locate code",
              data: { toolName: "Agent" },
            },
          }),
        ],
      }),
    );
    const rows = feed.flatMap((entry) =>
      entry.type === "activity-group" ? entry.activities.map((row) => row.id) : [],
    );
    expect(rows).toEqual(["agent-started"]);
    expect(
      deriveThreadFeedPresentation(feed, null, new Set([turnId])).map((row) => row.type),
    ).toEqual(["turn-fold", "agent-spawn"]);
  });

  it("shows a member's brief and its newest own tool call (#1567)", () => {
    const turnId = TurnId.make("turn-spawn-tools");
    const at = (seconds: number) => `2026-04-01T00:00:${String(seconds).padStart(2, "0")}.000Z`;
    const feed = buildThreadFeed(
      makeThread({
        id: ThreadId.make("thread-spawn-tools"),
        projectId: ProjectId.make("project-1"),
        title: "Spawn tools",
        activities: [
          makeActivity({
            id: EventId.make("a-start"),
            kind: "task.started",
            summary: "Agent a",
            createdAt: at(1),
            turnId,
            payload: {
              taskId: "a",
              agentKind: "agent",
              taskType: "local_agent",
              title: "Agent a",
              prompt: "Find every caller of verifySession.",
            },
          }),
          makeActivity({
            id: EventId.make("a-progress"),
            kind: "task.progress",
            summary: "Agent a",
            createdAt: at(2),
            turnId,
            payload: { taskId: "a", agentKind: "agent", title: "Agent a", detail: "Reading auth/" },
          }),
          makeActivity({
            id: EventId.make("a-grep"),
            kind: "tool.updated",
            tone: "tool",
            summary: "Grep",
            createdAt: at(3),
            turnId,
            payload: {
              itemType: "dynamic_tool_call",
              toolCallId: "toolu_grep",
              status: "inProgress",
              title: "Grep",
              agentId: "a",
            },
          }),
        ],
      }),
    );
    const card = deriveThreadFeedPresentation(feed, null, new Set([turnId])).find(
      (row) => row.type === "agent-spawn",
    );
    expect(card).toMatchObject({
      summary: {
        status: "Grep",
        members: [
          { title: "Agent a", detail: "Grep", prompt: "Find every caller of verifySession." },
        ],
      },
    });
    // The attributed tool row itself stays out of the timeline.
    expect(
      feed.flatMap((entry) =>
        entry.type === "activity-group" ? entry.activities.map((row) => row.id) : [],
      ),
    ).toEqual(["a-start"]);
  });

  it("presents a spawn batch as one card whose status line follows the newest member activity", () => {
    const turnId = TurnId.make("turn-spawn-card");
    const latestTurn = {
      turnId,
      state: "running" as const,
      requestedAt: "2026-04-01T00:00:00.000Z",
      startedAt: "2026-04-01T00:00:00.000Z",
      completedAt: null,
      assistantMessageId: null,
    };
    const agent = (
      id: string,
      kind: "task.started" | "task.progress" | "task.completed",
      taskId: string,
      seconds: number,
      extra: Record<string, unknown> = {},
    ) =>
      makeActivity({
        id: EventId.make(id),
        kind,
        summary: `Agent ${taskId}`,
        createdAt: `2026-04-01T00:00:${String(seconds).padStart(2, "0")}.000Z`,
        turnId,
        payload: {
          taskId,
          agentKind: "agent",
          taskType: "local_agent",
          title: `Agent ${taskId}`,
          ...extra,
        },
      });
    const presentFor = (activities: ReadonlyArray<ReturnType<typeof makeActivity>>) =>
      deriveThreadFeedPresentation(
        buildThreadFeed(
          makeThread({
            id: ThreadId.make("thread-spawn-card"),
            projectId: ProjectId.make("project-1"),
            title: "Spawn card",
            latestTurn,
            activities,
          }),
        ),
        latestTurn,
        new Set(),
        new Set(),
        latestTurn.startedAt,
      );

    // A working card is the live activity; no Thinking row sits under it.
    const single = presentFor([agent("a-start", "task.started", "a", 1)]);
    expect(single.map((row) => row.type)).toEqual(["agent-spawn"]);
    expect(single[0]).toMatchObject({
      id: `agent-spawn:${turnId}`,
      summary: { title: "Agent a", status: "Working", tone: "working" },
    });

    // The server upserts the progress row with a new createdAt each tick;
    // the card keeps its identity and only the status line changes.
    const tick = (seconds: number, detail: string) =>
      presentFor([
        agent("a-start", "task.started", "a", 1),
        agent("task-progress:a", "task.progress", "a", seconds, { detail }),
      ]);
    expect(tick(2, "Reading a.ts")[0]).toMatchObject({
      id: `agent-spawn:${turnId}`,
      createdAt: "2026-04-01T00:00:01.000Z",
      summary: { title: "Agent a", status: "Reading a.ts", tone: "working" },
    });
    expect(tick(3, "Reading b.ts")[0]).toMatchObject({
      id: `agent-spawn:${turnId}`,
      createdAt: "2026-04-01T00:00:01.000Z",
      summary: { status: "Reading b.ts" },
    });

    const batch = presentFor([
      agent("a-start", "task.started", "a", 1),
      agent("b-start", "task.started", "b", 2),
      agent("task-progress:b", "task.progress", "b", 3, { detail: "Grepping" }),
      agent("a-done", "task.completed", "a", 4, { status: "completed" }),
    ]);
    expect(batch[0]).toMatchObject({
      id: `agent-spawn:${turnId}`,
      summary: {
        title: "2 subagents",
        status: "Grepping",
        tone: "working",
        members: [
          { title: "Agent a", status: "completed", tone: "completed" },
          { title: "Agent b", status: "working", tone: "working", detail: "Grepping" },
        ],
      },
    });

    const settled = presentFor([
      agent("a-start", "task.started", "a", 1),
      agent("b-start", "task.started", "b", 2),
      agent("a-done", "task.completed", "a", 4, { status: "completed" }),
      agent("b-done", "task.completed", "b", 5, { status: "failed", error: "boom" }),
    ]);
    expect(settled[0]).toMatchObject({
      type: "agent-spawn",
      summary: { title: "2 subagents", status: "1 failed", tone: "failed" },
    });
    expect(settled.map((row) => row.type)).toEqual(["agent-spawn", "thinking"]);
  });

  it.each(["cancelled", "failed", "interrupted", "idle"] as const)(
    "replaces Antigravity batch progress with %s",
    (status) => {
      const detail =
        status === "idle"
          ? "Turn ended. Individual agent status is unavailable."
          : "Antigravity process stopped.";
      const thread = makeThread({
        id: ThreadId.make("antigravity-agents"),
        projectId: ProjectId.make("project-1"),
        title: "Antigravity subagents",
        activities: [
          ...["trajectory:4", "trajectory:5"].map((taskId, index) =>
            makeActivity({
              id: EventId.make(`progress-${index}`),
              kind: "task.progress",
              summary: "Antigravity subagent batch",
              createdAt: `2026-04-01T00:00:0${index + 1}.000Z`,
              payload: {
                taskId,
                taskType: "subagent_batch",
                agentKind: "agent",
                title: "Antigravity subagent batch",
                detail: "Antigravity subagent batch",
                status: "running",
              },
            }),
          ),
          makeActivity({
            id: EventId.make("agent-stopped"),
            kind: "task.updated",
            summary: `Task ${status}`,
            createdAt: "2026-04-01T00:00:03.000Z",
            payload: {
              taskId: "trajectory:4",
              taskType: "subagent_batch",
              agentKind: "agent",
              title: "Antigravity subagent batch",
              status,
              ...(status === "idle" ? { detail, timelineBypass: true } : { error: detail }),
            },
          }),
        ],
      });
      const rows = buildThreadFeed(thread).flatMap((entry) =>
        entry.type === "activity-group" ? entry.activities : [],
      );
      // Turn-less batches never share a spawn group, so each keeps its own row.
      expect(rows).toHaveLength(2);
      expect(rows[0]).toMatchObject({
        lifecycleStatus: status === "failed" ? "failed" : "stopped",
        summary: `Ran 1 subagent · ${status === "failed" ? "1 failed" : "1 stopped"}`,
        workEntry: {
          taskId: "trajectory:4",
          toolTitle: "Antigravity subagent batch",
          agentSpawn: { agents: [{ detail }] },
        },
      });
      expect(rows[0]?.getFullDetail()).toContain(detail);
      expect(rows[1]).toMatchObject({
        lifecycleStatus: "inProgress",
        summary: "Kicked off 1 subagent · 1 working",
        workEntry: { taskId: "trajectory:5" },
      });
    },
  );

  it("folds bypassed Claude workflow members into the coordinator's batch and settles them with it", () => {
    const turnId = TurnId.make("turn-workflow");
    const at = (seconds: number) => `2026-04-01T00:00:${String(seconds).padStart(2, "0")}.000Z`;
    const thread = makeThread({
      id: ThreadId.make("thread-workflow"),
      projectId: ProjectId.make("project-1"),
      title: "Workflow",
      activities: [
        makeActivity({
          id: EventId.make("wf-progress"),
          kind: "task.progress",
          summary: "Workflow running",
          createdAt: at(1),
          turnId,
          payload: {
            taskId: "wf-1",
            taskType: "local_workflow",
            workflowName: "review",
            agentKind: "agent",
            title: "review",
            status: "running",
          },
        }),
        // Members are synthesized with timelineBypass and never render alone.
        ...[0, 1].map((index) =>
          makeActivity({
            id: EventId.make(`member-${index}`),
            kind: "task.progress",
            summary: `Agent ${index}`,
            createdAt: at(2 + index),
            turnId,
            payload: {
              taskId: `wf-1:wf:${index}`,
              agentKind: "agent",
              title: `Reviewer ${index}`,
              description: `Reviewer ${index}`,
              status: index === 0 ? "completed" : "running",
              parentAgentId: "wf-1",
              timelineBypass: true,
            },
          }),
        ),
        makeActivity({
          id: EventId.make("wf-done"),
          kind: "task.completed",
          summary: "Task completed",
          createdAt: at(10),
          turnId,
          payload: {
            taskId: "wf-1",
            taskType: "local_workflow",
            workflowName: "review",
            agentKind: "agent",
            status: "completed",
            title: "review",
          },
        }),
      ],
    });
    const rows = buildThreadFeed(thread).flatMap((entry) =>
      entry.type === "activity-group" ? entry.activities : [],
    );
    expect(rows).toHaveLength(1);
    // The member that never reported its own end settles with the coordinator.
    expect(rows[0]).toMatchObject({
      id: "wf-progress",
      summary: "Ran 2 subagents · completed",
      lifecycleStatus: "completed",
      workEntry: {
        agentSpawn: {
          workflowId: "wf-1",
          agentTaskIds: ["wf-1", "wf-1:wf:0", "wf-1:wf:1"],
        },
      },
    });
    expect(rows[0]?.getFullDetail()).toBe("Reviewer 0 · completed\nReviewer 1 · completed");
  });

  it("summarizes a spawn card from the newest member report and the batch outcome", () => {
    type Member = NonNullable<WorkLogEntry["agentSpawn"]>["agents"][number];
    const member = (title: string, status: Member["status"], detail: string, seconds: number) =>
      ({
        title,
        status,
        detail,
        updatedAt: `2026-04-01T00:00:${String(seconds).padStart(2, "0")}.000Z`,
      }) satisfies Member;
    const direct = (agents: ReadonlyArray<Member>) => ({
      workflowId: null,
      agentTaskIds: agents.map((_, index) => `a${index}`),
      agents,
    });

    // The newest report wins regardless of member order.
    expect(
      agentSpawnSummary(
        direct([
          member("Agent 0", "inProgress", "Reading b.ts", 5),
          member("Agent 1", "inProgress", "Reading a.ts", 2),
        ]),
        "inProgress",
      ),
    ).toMatchObject({ title: "2 subagents", status: "Reading b.ts", tone: "working" });

    // A declined request is a failed batch, not a completed one.
    expect(
      agentSpawnSummary(direct([member("Agent 0", "declined", "", 1)]), "declined"),
    ).toMatchObject({ status: "failed", tone: "failed" });

    // A coordinator that failed on its own reports the failure even when every
    // member succeeded; before any member reports, the card has a neutral title.
    const workflow = (agents: ReadonlyArray<Member>) => ({
      workflowId: "wf",
      agentTaskIds: ["wf", ...agents.map((_, index) => `wf:wf:${index}`)],
      agents: [member("review", "failed", "", 9), ...agents],
    });
    expect(
      agentSpawnSummary(workflow([member("Reviewer", "completed", "", 3)]), "failed"),
    ).toMatchObject({ title: "Reviewer", status: "failed", tone: "failed" });
    expect(
      agentSpawnSummary(
        { workflowId: "wf", agentTaskIds: ["wf"], agents: [member("review", undefined, "", 1)] },
        "inProgress",
      ),
    ).toMatchObject({ title: "Subagents", status: "Working", tone: "working", members: [] });
  });

  it("treats a Codex child's idle turn end as a finished batch member", () => {
    const turnId = TurnId.make("turn-codex");
    const child = (
      id: string,
      kind: "task.started" | "task.updated",
      status: string,
      seconds: number,
    ) =>
      makeActivity({
        id: EventId.make(id),
        kind,
        summary: `${status}`,
        createdAt: `2026-04-01T00:00:${String(seconds).padStart(2, "0")}.000Z`,
        turnId,
        payload: {
          taskId: "child-1",
          agentKind: "agent",
          title: "math_one",
          status,
          timelineBypass: true,
        },
      });
    const thread = makeThread({
      id: ThreadId.make("thread-codex"),
      projectId: ProjectId.make("project-1"),
      title: "Codex children",
      activities: [
        child("c-start", "task.started", "running", 1),
        child("c-running", "task.updated", "running", 2),
        child("c-idle", "task.updated", "idle", 5),
      ],
    });
    const rows = buildThreadFeed(thread).flatMap((entry) =>
      entry.type === "activity-group" ? entry.activities : [],
    );
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      summary: "Ran 1 subagent · completed",
      lifecycleStatus: "completed",
    });
  });

  it("keeps a nested agent's terminal row but hides its background work", () => {
    const thread = makeThread({
      id: ThreadId.make("thread-nested"),
      projectId: ProjectId.make("project-1"),
      title: "Nested agents",
      activities: [
        // A subagent's own shell: internal, covered by the owner's liveness.
        makeActivity({
          id: EventId.make("shell-done"),
          kind: "task.completed",
          summary: "Task completed",
          createdAt: "2026-04-01T00:00:02.000Z",
          payload: { taskId: "sh-1", agentId: "owner", agentKind: "background" },
        }),
        // A nested AGENT's completion: mobile has no Agents sheet, so this
        // terminal row is the only signal it ever finished.
        makeActivity({
          id: EventId.make("nested-done"),
          kind: "task.completed",
          summary: "Task completed",
          createdAt: "2026-04-01T00:00:03.000Z",
          payload: { taskId: "n-1", agentId: "owner", agentKind: "agent" },
        }),
      ],
    });

    const feed = buildThreadFeed(thread);
    const ids = feed.flatMap((entry) =>
      entry.type === "activity-group" ? entry.activities.map((row) => row.id) : [],
    );
    expect(ids).toContain("nested-done");
    expect(ids).not.toContain("shell-done");
    expect(deriveThreadFeedPresentation(feed, null, new Set())).toMatchObject([
      {
        type: "agent-spawn",
        id: "agent-spawn:n-1",
        activity: { id: "nested-done" },
        summary: { title: "Task completed", status: "completed", tone: "completed" },
      },
    ]);
=======
    ).toEqual({ runtime: "second" });
>>>>>>> upstream-sync-e8545b293-upstream-renamed
  });
});

it("accepts ready attachment-only answers while preserving selected options", () => {
  const question = {
    id: "q",
    header: "Spec",
    question: "Provide a specification",
    options: [{ label: "Yes", description: "Approve" }],
    multiSelect: false,
  };
  expect(buildPendingUserInputAnswers([question], { q: { attachmentCount: 1 } })).toEqual({
    q: "",
  });
  expect(
    buildPendingUserInputAnswers([question], {
      q: { attachmentCount: 1, selectedOptionValues: ["Yes"] },
    }),
  ).toEqual({ q: "Yes" });
  expect(
    buildPendingUserInputAnswers([question], {
      q: { attachmentCount: 1, attachmentsBlocked: true },
    }),
  ).toBeNull();
  expect(
    buildPendingUserInputAnswers([{ ...question, allowCustomAnswer: false }], {
      q: { attachmentCount: 1 },
    }),
  ).toBeNull();
});

it("makes attachment-only question answers expandable in the mobile feed", () => {
  const answer = {
    requestId: RuntimeRequestId.make("question-request"),
    answers: { q: "" },
    questionTextById: { q: "Attach the specification" },
    attachmentsByQuestionId: {
      q: [
        {
          type: "file" as const,
          id: "question-file",
          name: "spec.txt",
          mimeType: "text/plain",
          sizeBytes: 4,
        },
      ],
    },
  };
  const [group] = buildThreadFeed([
    projected(
      {
        ...base("answer-history", "2026-09-08T00:00:00.000Z", 0),
        type: "user_input_request",
        requestId: answer.requestId,
        questions: [],
        questionAnswer: answer,
      },
      0,
    ),
  ]);
  expect(group?.type).toBe("activity-group");
  if (group?.type !== "activity-group") return;
  expect(group.activities[0]).toMatchObject({
    canExpand: true,
    workEntry: { questionAnswer: answer },
  });
  expect(group.activities[0]?.getFullDetail()).toContain("spec.txt");
});

it("renders automatic completion as a neutral activity while retaining its details", () => {
  const item = {
    ...base("notification", "2026-06-20T00:00:01.000Z", 0),
    type: "notification" as const,
    source: { kind: "monitor" as const },
    outcome: "updated" as const,
    summary: "Monitor reported an update",
    detail: "Build checks changed",
  };
  const feed = buildThreadFeed([
    projected(item, 0),
    projected(command(), 1),
    projected(assistantMessage(), 2),
  ]);
  expect(feed[0]?.type).toBe("activity-group");
  if (feed[0]?.type !== "activity-group") throw new Error("Expected notification activity");
  const activity = feed[0].activities[0]!;
  expect(activity.summary).toBe("Monitor reported an update");
  expect(activity.detail).toBeNull();
  expect(activity.status).toBeNull();
  expect(activity.getFullDetail()).toContain(item.detail);
  const presented = deriveThreadFeedPresentation(
    feed,
    {
      runId,
      status: "completed",
      startedAt: "2026-06-20T00:00:01.000Z",
      completedAt: "2026-06-20T00:00:03.000Z",
    },
    new Set(),
  );
  expect(
    presented.some(
      (entry) =>
        entry.type === "activity-group" &&
        entry.activities.some((activity) => activity.summary === "Monitor reported an update"),
    ),
  ).toBe(true);
  expect(buildThreadFeed([projected(userMessage(), 0)])[0]?.type).toBe("message");
});

it("uses a compact reasoning preview and a short expanded heading", () => {
  const entry = {
    id: "thought",
    label: "Thinking",
    createdAt: "2026-09-17T12:00:00Z",
    itemType: "reasoning" as const,
    tone: "thinking" as const,
    detail: "Check **ordering**.\nThen run the test.",
    toolLifecycleStatus: "inProgress" as const,
  };
  expect(workEntryRowLabel(entry)).toBe("Check **ordering**. Then run the test.");
  expect(workEntryRowLabel(entry, true)).toBe("Thinking");
  expect(workEntryRowLabel({ ...entry, toolLifecycleStatus: "completed" }, true)).toBe("Thought");
});

it("keeps search output in expanded details rather than the compact label", () => {
  const entry = {
    id: "search",
    label: "Grep",
    toolTitle: "Grep",
    createdAt: "2026-09-17T12:00:00Z",
    itemType: "dynamic_tool" as const,
    tone: "tool" as const,
    detail: "---\nfile body",
    toolData: {},
  };
  expect(workEntryRowLabel(entry)).toBe("Grep");
  expect(workEntryRowLabel(entry, true)).toBe("---\nfile body");
});

it.each(["First paragraph.\n\nSecond paragraph.", ""])(
  "previews live reasoning text %j",
  (text) => {
    const thought: OrchestrationV2TurnItem = {
      ...base("live-thought", "2026-06-20T00:00:02.000Z", 1),
      type: "reasoning",
      status: "running",
      completedAt: null,
      streaming: true,
      text,
    };
    const feed = buildThreadFeed([projected(userMessage(), 0), projected(thought, 1)]);
    const rows = deriveThreadFeedPresentation(
      feed,
      { runId, status: "running", startedAt: "2026-06-20T00:00:01.000Z", completedAt: null },
      new Set(),
      new Set(),
      "2026-06-20T00:00:01.000Z",
    );
    if (text) {
      expect(rows.find((row) => row.type === "work-toggle")).toMatchObject({
        summary: "First paragraph. Second paragraph.",
        live: true,
      });
    } else {
      expect(
        rows.some(
          (row) =>
            row.type === "thinking" || (row.type === "work-toggle" && row.summary === "Thinking"),
        ),
      ).toBe(true);
    }
  },
);

it("stops stranded thinking after a steer and follows the next thought or tool", () => {
  const at = "2026-06-20T00:00:02.000Z";
  const thought = (id: string): OrchestrationV2TurnItem => ({
    ...base(id, at, 1),
    type: "reasoning",
    status: "running",
    completedAt: null,
    streaming: true,
    text: id,
  });
  const first = thought("first-thought");
  const next = thought("next-thought");
  const steer = { ...userMessage(at), inputIntent: "steer" as const };
  const tool = { ...command(at), status: "running" as const, completedAt: null };
  const rows = (items: ReadonlyArray<OrchestrationV2TurnItem>, expanded = new Set<string>()) =>
    deriveThreadFeedPresentation(
      buildThreadFeed(items.map((item, position) => projected(item, position))),
      { runId, status: "running", startedAt: at, completedAt: null },
      new Set(),
      expanded,
      at,
    );
  expect(rows([first]).find((row) => row.type === "work-toggle")).toMatchObject({
    summary: "first-thought",
    live: true,
    shimmer: true,
  });
  const afterSteer = rows([first, steer]);
  expect(afterSteer.find((row) => row.type === "work-toggle")).toMatchObject({
    live: false,
    shimmer: false,
  });
  expect(afterSteer.at(-1)?.type).toBe("thinking");
  const header = afterSteer.find((row) => row.type === "work-toggle");
  if (header?.type !== "work-toggle") throw new Error("Expected thought toggle");
  const expanded = rows([first, steer], new Set([header.groupId]));
  expect(expanded.find((row) => row.type === "work-toggle")).toMatchObject({ summary: "Thought" });
  expect(expanded.find((row) => row.type === "activity-group")).toMatchObject({
    activities: [{ lifecycleStatus: "completed", workEntry: { toolLifecycleStatus: "completed" } }],
  });
  for (const items of [
    [first, steer, next],
    [first, next],
    [first, steer, next, tool],
  ]) {
    const live = rows(items).filter((row) => row.type === "work-toggle" && row.shimmer);
    expect(live).toHaveLength(1);
    expect(live[0]).toMatchObject({
      summary: items.at(-1)!.type === "reasoning" ? "next-thought" : "Running vp",
    });
  }
  expect(first.status).toBe("running");
});

it("previews a settled thought in its collapsed header and labels its expanded header", () => {
  const thought: OrchestrationV2TurnItem = {
    ...base("thought-preview", "2026-06-20T00:00:02.000Z", 1),
    type: "reasoning",
    streaming: false,
    text: "First paragraph.\n\nSecond paragraph.",
  };
  const feed = buildThreadFeed([
    projected(userMessage(), 0),
    projected(thought, 1),
    projected(assistantMessage(), 2),
  ]);
  const run = {
    runId,
    status: "completed" as const,
    startedAt: "2026-06-20T00:00:01.000Z",
    completedAt: "2026-06-20T00:00:03.000Z",
  };
  const collapsed = deriveThreadFeedPresentation(feed, run, new Set([runId]));
  const header = collapsed.find((row) => row.type === "work-toggle");
  expect(header).toMatchObject({ summary: "First paragraph. Second paragraph." });
  if (header?.type !== "work-toggle") throw new Error("Expected thought toggle");
  const expanded = deriveThreadFeedPresentation(
    feed,
    run,
    new Set([runId]),
    new Set([header.groupId]),
  );
  expect(expanded.find((row) => row.type === "work-toggle")).toMatchObject({
    summary: "Thought",
    continuesWorkLog: true,
  });
  const detail = expanded.find((row) => row.type === "activity-group");
  expect(detail?.continuesWorkLog).toBeUndefined();
  if (detail?.type !== "activity-group") throw new Error("Expected full thought");
  expect(detail.activities[0]?.detail).toBe(thought.text);
});

it.each(["provider_error", "usage_limit"] as const)(
  "keeps a historical %s failure and preceding work visible without disclosures",
  (failureClass) => {
    const at = "2026-06-20T00:00:03.000Z";
    const error: OrchestrationV2TurnItem = {
      ...base("failure", at, 2),
      type: "error",
      status: "failed",
      failure: {
        class: failureClass,
        message: "The provider stopped this turn.\nRetry later.",
        code: null,
        retryable: true,
      },
    };
    const command: OrchestrationV2TurnItem = {
      ...base("command", "2026-06-20T00:00:02.000Z", 1),
      type: "command_execution",
      input: "pwd",
      output: "",
      exitCode: 0,
    };
    const sourceFeed = buildThreadFeed([
      projected(userMessage(), 0),
      projected(command, 1),
      projected(error, 2),
    ]);
    const feed = deriveThreadFeedPresentation(
      sourceFeed,
      { runId: RunId.make("newer-run"), status: "completed", startedAt: at, completedAt: at },
      new Set(),
    );
    const whileWorking = deriveThreadFeedPresentation(
      sourceFeed,
      { runId: RunId.make("newer-run"), status: "running", startedAt: at, completedAt: null },
      new Set(),
    );
    for (const entry of feed) {
      expect(whileWorking.find((row) => row.id === entry.id)).toBe(entry);
    }
    expect(feed.some((entry) => entry.type === "run-fold" || entry.type === "work-toggle")).toBe(
      false,
    );
    const activities = feed.flatMap((entry) =>
      entry.type === "activity-group" ? entry.activities : [],
    );
    expect(activities.map((activity) => activity.projectedItem.item.id)).toEqual([
      "command",
      "failure",
    ]);
    expect(activities.at(-1)).toMatchObject({
      detail: error.failure.message,
      createdAt: at,
      canExpand: false,
      prominent: true,
    });
  },
);
