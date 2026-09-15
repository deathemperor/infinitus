import { CommandId, MessageId, ProviderInstanceId, QueueId, ThreadId } from "@t3tools/contracts";
import { AsyncResult } from "effect/unstable/reactivity";
import { describe, expect, it } from "vite-plus/test";

import {
  isThreadHeld,
  outboxQueueMode,
  queueBehindRunningTurn,
  queuedTurnSendAt,
  queueTurnCommandInput,
  resolveThreadOutboxDelivery,
} from "./threadOutboxQueue.logic";

const thread = ThreadId.make("thread-1");

describe("threadOutboxQueue.logic (#807)", () => {
  it("waits for a running or held existing thread in queue mode", () => {
    const base = {
      action: "send" as const,
      isCreation: false,
      threadHeld: false,
      mode: "queue" as const,
    };
    expect(queueBehindRunningTurn({ ...base, threadBusy: true })).toBe("wait");
    expect(queueBehindRunningTurn({ ...base, threadBusy: false, threadHeld: true })).toBe("wait");
    expect(queueBehindRunningTurn({ ...base, threadBusy: false })).toBe("send");
  });

  it("steers into a running turn but never past a hold", () => {
    const base = { action: "send" as const, isCreation: false, mode: "steer" as const };
    expect(queueBehindRunningTurn({ ...base, threadBusy: true, threadHeld: false })).toBe("send");
    expect(queueBehindRunningTurn({ ...base, threadBusy: false, threadHeld: true })).toBe("wait");
    expect(queueBehindRunningTurn({ ...base, threadBusy: true, threadHeld: true })).toBe("wait");
  });

  it("reads steer only from a loaded preference, and queues while the store loads", () => {
    expect(outboxQueueMode(AsyncResult.initial())).toBe("queue");
    expect(outboxQueueMode(AsyncResult.success({}))).toBe("queue");
    expect(outboxQueueMode(AsyncResult.success({ infinitusComposerSendMode: "queue" }))).toBe(
      "queue",
    );
    expect(outboxQueueMode(AsyncResult.success({ infinitusComposerSendMode: "steer" }))).toBe(
      "steer",
    );
  });

  it("leaves creations, non-send actions and steer mode alone", () => {
    expect(
      queueBehindRunningTurn({
        action: "send",
        isCreation: true,
        threadBusy: true,
        threadHeld: true,
        mode: "queue",
      }),
    ).toBe("send");
    expect(
      queueBehindRunningTurn({
        action: "remove",
        isCreation: false,
        threadBusy: true,
        threadHeld: false,
        mode: "queue",
      }),
    ).toBe("remove");
    expect(
      queueBehindRunningTurn({
        action: "send",
        isCreation: false,
        threadBusy: true,
        threadHeld: false,
        mode: "steer",
      }),
    ).toBe("send");
  });

  it("reads a hold of any kind for the thread, none from a null list", () => {
    expect(isThreadHeld(null, thread)).toBe(false);
    expect(isThreadHeld([], thread)).toBe(false);
    expect(isThreadHeld([{ threadId: thread, since: "now", summary: "held" }], thread)).toBe(true);
    expect(
      isThreadHeld([{ threadId: thread, since: "now", summary: "limit", kind: "limited" }], thread),
    ).toBe(true);
    expect(
      isThreadHeld([{ threadId: ThreadId.make("other"), since: "now", summary: "held" }], thread),
    ).toBe(false);
  });
});

describe("resolveThreadOutboxDelivery (#812)", () => {
  const base = {
    action: "send" as const,
    isCreation: false,
    threadHeld: false,
    mode: "queue" as const,
    serverSendAt: false,
  };

  it("hands a send behind a running or held turn to a server with the queue", () => {
    expect(resolveThreadOutboxDelivery({ ...base, threadBusy: true, serverQueues: true })).toBe(
      "queue",
    );
    expect(
      resolveThreadOutboxDelivery({
        ...base,
        threadBusy: false,
        threadHeld: true,
        serverQueues: true,
      }),
    ).toBe("queue");
    expect(resolveThreadOutboxDelivery({ ...base, threadBusy: false, serverQueues: true })).toBe(
      "send",
    );
  });

  it("keeps the wait on a server without the queue, and every other outcome", () => {
    expect(resolveThreadOutboxDelivery({ ...base, threadBusy: true, serverQueues: false })).toBe(
      "wait",
    );
    expect(
      resolveThreadOutboxDelivery({
        ...base,
        action: "wait",
        threadBusy: true,
        serverQueues: true,
      }),
    ).toBe("wait");
    expect(
      resolveThreadOutboxDelivery({
        ...base,
        action: "remove",
        threadBusy: true,
        serverQueues: true,
      }),
    ).toBe("remove");
    expect(
      resolveThreadOutboxDelivery({
        ...base,
        isCreation: true,
        threadBusy: true,
        serverQueues: true,
      }),
    ).toBe("send");
  });
});

describe("steer as a tool-boundary row (#1325)", () => {
  const steer = {
    action: "send" as const,
    isCreation: false,
    threadBusy: true,
    threadHeld: false,
    mode: "steer" as const,
    serverQueues: true,
    serverSendAt: true,
  };

  it("queues a steer send behind a running turn at the next tool boundary on a server that honours it", () => {
    expect(resolveThreadOutboxDelivery(steer)).toBe("queue");
    expect(queuedTurnSendAt(steer)).toBe("tool-boundary");
  });

  it("keeps sending into the turn on a server without the flag", () => {
    expect(resolveThreadOutboxDelivery({ ...steer, serverSendAt: false })).toBe("send");
    expect(queuedTurnSendAt({ ...steer, serverSendAt: false })).toBeUndefined();
  });

  it("is an ordinary row for a held thread, and nothing for an idle thread, a creation or queue mode", () => {
    expect(resolveThreadOutboxDelivery({ ...steer, threadHeld: true })).toBe("queue");
    expect(queuedTurnSendAt({ ...steer, threadHeld: true })).toBeUndefined();
    expect(resolveThreadOutboxDelivery({ ...steer, threadBusy: false })).toBe("send");
    expect(queuedTurnSendAt({ ...steer, threadBusy: false })).toBeUndefined();
    expect(queuedTurnSendAt({ ...steer, isCreation: true })).toBeUndefined();
    expect(queuedTurnSendAt({ ...steer, mode: "queue" })).toBeUndefined();
  });

  it("stamps the row's sendAt only when given", () => {
    const base = {
      message: {
        commandId: CommandId.make("c1"),
        threadId: ThreadId.make("t1"),
        messageId: MessageId.make("m1"),
        text: "go",
        createdAt: "2026-09-15T10:00:00Z",
      },
      attachments: [],
      modelSelection: { instanceId: ProviderInstanceId.make("p1"), model: "m" },
      queueId: QueueId.make("q1"),
    };
    expect(queueTurnCommandInput(base)).not.toHaveProperty("sendAt");
    expect(queueTurnCommandInput({ ...base, sendAt: "tool-boundary" }).sendAt).toBe(
      "tool-boundary",
    );
  });
});

describe("queueTurnCommandInput (#812)", () => {
  it("keeps the outbox ids and stamps the given queue id", () => {
    const attachments = [
      { type: "file" as const, id: "f1", name: "a.txt", mimeType: "text/plain", sizeBytes: 1 },
    ];
    expect(
      queueTurnCommandInput({
        message: {
          commandId: CommandId.make("cmd-1"),
          threadId: thread,
          messageId: MessageId.make("msg-1"),
          text: "later",
          createdAt: "2026-09-12T00:00:00.000Z",
        },
        attachments,
        modelSelection: {
          instanceId: ProviderInstanceId.make("claude-agent"),
          model: "claude-opus-5",
        },
        queueId: QueueId.make("q-1"),
      }),
    ).toEqual({
      commandId: "cmd-1",
      threadId: "thread-1",
      queueId: "q-1",
      message: { messageId: "msg-1", role: "user", text: "later", attachments },
      modelSelection: { instanceId: "claude-agent", model: "claude-opus-5" },
      createdAt: "2026-09-12T00:00:00.000Z",
    });
  });
});
