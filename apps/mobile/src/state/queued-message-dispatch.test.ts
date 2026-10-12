import { MessageId } from "@infinitus/contracts";
import { afterEach, describe, expect, it } from "vite-plus/test";

import { appAtomRegistry } from "./atom-registry";
import {
  beginDispatchingQueuedMessage,
  dispatchingQueuedMessageAtom,
  finishDispatchingQueuedMessage,
  markDispatchingQueuedMessageSending,
  reclaimQueuedMessageFromDispatch,
} from "./queued-message-dispatch";

const messageId = MessageId.make("message-1");
const otherId = MessageId.make("message-2");

afterEach(() => {
  appAtomRegistry.set(dispatchingQueuedMessageAtom, null);
});

describe("queued message dispatch phases", () => {
  it("publishes the upload phase, then the send phase, then nothing", () => {
    const signal = beginDispatchingQueuedMessage(messageId);
    expect(appAtomRegistry.get(dispatchingQueuedMessageAtom)).toEqual({
      messageId,
      phase: "uploading",
    });
    expect(markDispatchingQueuedMessageSending(messageId)).toBe(true);
    expect(appAtomRegistry.get(dispatchingQueuedMessageAtom)).toEqual({
      messageId,
      phase: "sending",
    });
    finishDispatchingQueuedMessage(messageId);
    expect(appAtomRegistry.get(dispatchingQueuedMessageAtom)).toBeNull();
    expect(signal.aborted).toBe(false);
  });

  it("reclaims a message that is not being dispatched without touching the dispatch", () => {
    const signal = beginDispatchingQueuedMessage(messageId);
    expect(reclaimQueuedMessageFromDispatch(otherId)).toBe(true);
    expect(signal.aborted).toBe(false);
    expect(appAtomRegistry.get(dispatchingQueuedMessageAtom)).toEqual({
      messageId,
      phase: "uploading",
    });
  });

  it("aborts the upload when the message is reclaimed, so the send never starts", () => {
    const signal = beginDispatchingQueuedMessage(messageId);
    expect(reclaimQueuedMessageFromDispatch(messageId)).toBe(true);
    expect(signal.aborted).toBe(true);
    expect(markDispatchingQueuedMessageSending(messageId)).toBe(false);
    expect(appAtomRegistry.get(dispatchingQueuedMessageAtom)).toEqual({
      messageId,
      phase: "uploading",
    });
  });

  it("refuses to reclaim a message whose send is in flight", () => {
    const signal = beginDispatchingQueuedMessage(messageId);
    markDispatchingQueuedMessageSending(messageId);
    expect(reclaimQueuedMessageFromDispatch(messageId)).toBe(false);
    expect(signal.aborted).toBe(false);
  });

  it("only the current dispatch may finish or flip to sending", () => {
    beginDispatchingQueuedMessage(messageId);
    expect(markDispatchingQueuedMessageSending(otherId)).toBe(false);
    finishDispatchingQueuedMessage(otherId);
    expect(appAtomRegistry.get(dispatchingQueuedMessageAtom)).toEqual({
      messageId,
      phase: "uploading",
    });
  });
});
