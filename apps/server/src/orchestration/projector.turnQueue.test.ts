import {
  CommandId,
  EventId,
  MessageId,
  ProjectId,
  QueueId,
  ThreadId,
  type OrchestrationEvent,
} from "@t3tools/contracts";
import { expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";

import { createEmptyReadModel, projectEvent } from "./projector.ts";

const threadId = ThreadId.make("thread-1");
const now = "2026-01-01T00:00:00.000Z";

function makeEvent(input: {
  readonly sequence: number;
  readonly type: OrchestrationEvent["type"];
  readonly payload: unknown;
}): OrchestrationEvent {
  return {
    sequence: input.sequence,
    eventId: EventId.make(`event-${input.sequence}`),
    type: input.type,
    aggregateKind: "thread",
    aggregateId: threadId,
    occurredAt: now,
    commandId: CommandId.make(`command-${input.sequence}`),
    causationEventId: null,
    correlationId: null,
    metadata: {},
    payload: input.payload as never,
  } as OrchestrationEvent;
}

const queued = (queueId: string, orderKey: string) => ({
  queueId: QueueId.make(queueId),
  messageId: MessageId.make(`${queueId}-message`),
  text: `queued ${queueId}`,
  attachments: [],
  orderKey,
  createdAt: now,
  updatedAt: now,
});

it.effect("projects the server-side message queue (#806)", () =>
  Effect.gen(function* () {
    let model = yield* projectEvent(
      createEmptyReadModel(now),
      makeEvent({
        sequence: 1,
        type: "thread.created",
        payload: {
          threadId,
          projectId: ProjectId.make("project-1"),
          title: "Thread",
          modelSelection: { provider: "codex", model: "gpt-5.4" },
          runtimeMode: "full-access",
          interactionMode: "default",
          branch: null,
          worktreePath: null,
          createdAt: now,
          updatedAt: now,
        },
      }),
    );
    expect(model.threads[0]?.queuedTurns).toBeUndefined();

    model = yield* projectEvent(
      model,
      makeEvent({
        sequence: 2,
        type: "thread.turn-queued",
        payload: { threadId, queuedTurn: queued("late", "t") },
      }),
    );
    model = yield* projectEvent(
      model,
      makeEvent({
        sequence: 3,
        type: "thread.turn-queued",
        payload: { threadId, queuedTurn: queued("early", "f") },
      }),
    );
    expect(model.threads[0]?.queuedTurns?.map((row) => row.queueId)).toEqual(["early", "late"]);
    // Queuing is not thread activity.
    expect(model.threads[0]?.updatedAt).toBe(now);

    model = yield* projectEvent(
      model,
      makeEvent({
        sequence: 4,
        type: "thread.turn-queue-updated",
        payload: { threadId, queuedTurn: { ...queued("early", "f"), text: "edited" } },
      }),
    );
    expect(model.threads[0]?.queuedTurns?.[0]?.text).toBe("edited");

    model = yield* projectEvent(
      model,
      makeEvent({
        sequence: 5,
        type: "thread.turn-queue-moved",
        payload: { threadId, queueId: QueueId.make("early"), orderKey: "z", updatedAt: now },
      }),
    );
    expect(model.threads[0]?.queuedTurns?.map((row) => row.queueId)).toEqual(["late", "early"]);

    model = yield* projectEvent(
      model,
      makeEvent({
        sequence: 6,
        type: "thread.turn-queue-removed",
        payload: { threadId, queueId: QueueId.make("late"), reason: "sent", removedAt: now },
      }),
    );
    expect(model.threads[0]?.queuedTurns?.map((row) => row.queueId)).toEqual(["early"]);
  }),
);
