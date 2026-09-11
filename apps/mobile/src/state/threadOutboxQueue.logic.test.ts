import { ThreadId } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import { isThreadHeld, queueBehindRunningTurn } from "./threadOutboxQueue.logic";

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
