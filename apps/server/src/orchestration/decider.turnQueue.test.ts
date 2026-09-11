import {
  CommandId,
  MessageId,
  ProjectId,
  ProviderInstanceId,
  QueueId,
  ThreadId,
  type OrchestrationQueuedTurn,
  type OrchestrationReadModel,
} from "@t3tools/contracts";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";

import { decideOrchestrationCommand } from "./decider.ts";

const NOW = "2026-01-01T00:00:00.000Z";
const LATER = "2026-01-01T00:05:00.000Z";
const threadId = ThreadId.make("thread-1");

const row = (queueId: string, orderKey: string): OrchestrationQueuedTurn => ({
  queueId: QueueId.make(queueId),
  messageId: MessageId.make(`${queueId}-message`),
  text: `queued ${queueId}`,
  attachments: [],
  orderKey,
  createdAt: NOW,
  updatedAt: NOW,
});

function makeReadModel(input: {
  readonly queuedTurns?: ReadonlyArray<OrchestrationQueuedTurn>;
  readonly archivedAt?: string | null;
}): OrchestrationReadModel {
  return {
    snapshotSequence: 0,
    projects: [],
    threads: [
      {
        id: threadId,
        projectId: ProjectId.make("project-1"),
        title: "Thread",
        modelSelection: { instanceId: ProviderInstanceId.make("codex"), model: "gpt-5.4" },
        runtimeMode: "full-access",
        interactionMode: "default",
        branch: null,
        worktreePath: null,
        pullRequests: [],
        latestTurn: null,
        createdAt: NOW,
        updatedAt: NOW,
        archivedAt: input.archivedAt ?? null,
        settledOverride: null,
        settledAt: null,
        deletedAt: null,
        messages: [],
        proposedPlans: [],
        activities: [],
        checkpoints: [],
        session: null,
        ...(input.queuedTurns === undefined ? {} : { queuedTurns: input.queuedTurns }),
      },
    ],
    updatedAt: NOW,
  };
}

const message = (id: string, text: string) => ({
  messageId: MessageId.make(id),
  role: "user" as const,
  text,
  attachments: [],
});

const events = (result: unknown) =>
  (Array.isArray(result) ? result : [result]) as Array<{
    readonly type: string;
    readonly payload: Record<string, unknown>;
  }>;

it.layer(NodeServices.layer)("turn queue decider (#806)", (it) => {
  it.effect("queues a row after the last one, keeping the message and the model", () =>
    Effect.gen(function* () {
      const result = events(
        yield* decideOrchestrationCommand({
          command: {
            type: "thread.turn.queue",
            commandId: CommandId.make("cmd-queue"),
            threadId,
            queueId: QueueId.make("q2"),
            message: message("m2", "second"),
            modelSelection: { instanceId: ProviderInstanceId.make("claude"), model: "opus" },
            createdAt: LATER,
          },
          readModel: makeReadModel({ queuedTurns: [row("q1", "m")] }),
        }),
      );
      expect(result).toHaveLength(1);
      expect(result[0]?.type).toBe("thread.turn-queued");
      const queued = result[0]?.payload.queuedTurn as OrchestrationQueuedTurn;
      expect(queued.queueId).toBe("q2");
      expect(queued.text).toBe("second");
      expect(queued.modelSelection).toEqual({ instanceId: "claude", model: "opus" });
      expect(queued.orderKey > "m").toBe(true);
      expect(queued.createdAt).toBe(LATER);
    }),
  );

  it.effect("re-emits an existing row for a duplicate queue command", () =>
    Effect.gen(function* () {
      const existing = row("q1", "m");
      const result = events(
        yield* decideOrchestrationCommand({
          command: {
            type: "thread.turn.queue",
            commandId: CommandId.make("cmd-dup"),
            threadId,
            queueId: QueueId.make("q1"),
            message: message("other", "replayed"),
            createdAt: LATER,
          },
          readModel: makeReadModel({ queuedTurns: [existing] }),
        }),
      );
      expect(result[0]?.payload.queuedTurn).toEqual(existing);
    }),
  );

  it.effect("rejects a bad order key, a missing row, and an archived thread", () =>
    Effect.gen(function* () {
      const bad = yield* decideOrchestrationCommand({
        command: {
          type: "thread.turn.queue",
          commandId: CommandId.make("cmd-bad"),
          threadId,
          queueId: QueueId.make("q9"),
          message: message("m9", "x"),
          orderKey: "A1",
          createdAt: LATER,
        },
        readModel: makeReadModel({}),
      }).pipe(Effect.flip);
      expect(String(bad)).toContain("not a valid order key");

      const missing = yield* decideOrchestrationCommand({
        command: {
          type: "thread.turn.queue.move",
          commandId: CommandId.make("cmd-move-missing"),
          threadId,
          queueId: QueueId.make("nope"),
          orderKey: "b",
        },
        readModel: makeReadModel({ queuedTurns: [row("q1", "m")] }),
      }).pipe(Effect.flip);
      expect(String(missing)).toContain("does not exist");

      const archived = yield* decideOrchestrationCommand({
        command: {
          type: "thread.turn.queue",
          commandId: CommandId.make("cmd-archived"),
          threadId,
          queueId: QueueId.make("q9"),
          message: message("m9", "x"),
          createdAt: LATER,
        },
        readModel: makeReadModel({ archivedAt: NOW }),
      }).pipe(Effect.flip);
      expect(String(archived)).toContain("archived");
    }),
  );

  it.effect("updates, moves and removes a row", () =>
    Effect.gen(function* () {
      const readModel = makeReadModel({ queuedTurns: [row("q1", "m")] });
      const updated = events(
        yield* decideOrchestrationCommand({
          command: {
            type: "thread.turn.queue.update",
            commandId: CommandId.make("cmd-update"),
            threadId,
            queueId: QueueId.make("q1"),
            message: message("m1b", "edited"),
            createdAt: LATER,
          },
          readModel,
        }),
      );
      expect(updated[0]?.type).toBe("thread.turn-queue-updated");
      expect(updated[0]?.payload.queuedTurn).toMatchObject({
        queueId: "q1",
        messageId: "m1b",
        text: "edited",
        orderKey: "m",
        createdAt: NOW,
        updatedAt: LATER,
      });

      const moved = events(
        yield* decideOrchestrationCommand({
          command: {
            type: "thread.turn.queue.move",
            commandId: CommandId.make("cmd-move"),
            threadId,
            queueId: QueueId.make("q1"),
            orderKey: "f",
          },
          readModel,
        }),
      );
      expect(moved[0]?.type).toBe("thread.turn-queue-moved");
      expect(moved[0]?.payload).toMatchObject({ queueId: "q1", orderKey: "f" });

      const removed = events(
        yield* decideOrchestrationCommand({
          command: {
            type: "thread.turn.queue.remove",
            commandId: CommandId.make("cmd-remove"),
            threadId,
            queueId: QueueId.make("q1"),
          },
          readModel,
        }),
      );
      expect(removed[0]?.type).toBe("thread.turn-queue-removed");
      expect(removed[0]?.payload).toMatchObject({ queueId: "q1", reason: "user" });
    }),
  );

  it.effect("a turn start from a queued row removes the row in the same batch", () =>
    Effect.gen(function* () {
      const start = {
        type: "thread.turn.start" as const,
        commandId: CommandId.make("cmd-start"),
        threadId,
        message: message("m1", "queued q1"),
        runtimeMode: "full-access" as const,
        interactionMode: "default" as const,
        queuedFrom: QueueId.make("q1"),
        createdAt: LATER,
      };
      const withRow = events(
        yield* decideOrchestrationCommand({
          command: start,
          readModel: makeReadModel({ queuedTurns: [row("q1", "m")] }),
        }),
      ).map((event) => event.type);
      expect(withRow).toEqual([
        "thread.message-sent",
        "thread.turn-start-requested",
        "thread.turn-queue-removed",
      ]);

      // The row was removed meanwhile: the send still goes, nothing else.
      const withoutRow = events(
        yield* decideOrchestrationCommand({ command: start, readModel: makeReadModel({}) }),
      ).map((event) => event.type);
      expect(withoutRow).toEqual(["thread.message-sent", "thread.turn-start-requested"]);
    }),
  );
});
