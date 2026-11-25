import { MessageId } from "@infinitus/contracts";
import { afterEach, describe, expect, it } from "vite-plus/test";

import { appAtomRegistry } from "./atom-registry";
import {
  beginDispatchingQueuedMessage,
  dispatchingQueuedMessagesAtom,
  finishDispatchingQueuedMessage,
  markDispatchingQueuedMessageSending,
  reclaimQueuedMessageFromDispatch,
} from "./queued-message-dispatch";

const messageId = MessageId.make("message-1");
const otherId = MessageId.make("message-2");

afterEach(() => {
  appAtomRegistry.set(dispatchingQueuedMessagesAtom, {});
});

describe("queued message dispatch phases", () => {
  it("publishes the upload phase, then the send phase, then nothing", () => {
    const signal = beginDispatchingQueuedMessage(messageId);
    expect(appAtomRegistry.get(dispatchingQueuedMessagesAtom)).toEqual({
      [messageId]: "uploading",
    });
    expect(markDispatchingQueuedMessageSending(messageId)).toBe(true);
    expect(appAtomRegistry.get(dispatchingQueuedMessagesAtom)).toEqual({
      [messageId]: "sending",
    });
    finishDispatchingQueuedMessage(messageId);
    expect(appAtomRegistry.get(dispatchingQueuedMessagesAtom)).toEqual({});
    expect(signal.aborted).toBe(false);
  });

  it("reclaims a message that is not being dispatched without touching the dispatch", () => {
    const signal = beginDispatchingQueuedMessage(messageId);
    expect(reclaimQueuedMessageFromDispatch(otherId)).toBe(true);
    expect(signal.aborted).toBe(false);
    expect(appAtomRegistry.get(dispatchingQueuedMessagesAtom)).toEqual({
      [messageId]: "uploading",
    });
  });

  it("aborts the upload when the message is reclaimed, so the send never starts", () => {
    const signal = beginDispatchingQueuedMessage(messageId);
    expect(reclaimQueuedMessageFromDispatch(messageId)).toBe(true);
    expect(signal.aborted).toBe(true);
    expect(markDispatchingQueuedMessageSending(messageId)).toBe(false);
    expect(appAtomRegistry.get(dispatchingQueuedMessagesAtom)).toEqual({
      [messageId]: "uploading",
    });
  });

  it("refuses to reclaim a message whose send is in flight", () => {
    const signal = beginDispatchingQueuedMessage(messageId);
    markDispatchingQueuedMessageSending(messageId);
    expect(reclaimQueuedMessageFromDispatch(messageId)).toBe(false);
    expect(signal.aborted).toBe(false);
  });

  it("reclaims one of two concurrent dispatches without touching the other", () => {
    const signal = beginDispatchingQueuedMessage(messageId);
    const otherSignal = beginDispatchingQueuedMessage(otherId);
    expect(reclaimQueuedMessageFromDispatch(otherId)).toBe(true);
    expect(otherSignal.aborted).toBe(true);
    expect(signal.aborted).toBe(false);
    expect(markDispatchingQueuedMessageSending(messageId)).toBe(true);
    expect(markDispatchingQueuedMessageSending(otherId)).toBe(false);
    expect(appAtomRegistry.get(dispatchingQueuedMessagesAtom)).toEqual({
      [messageId]: "sending",
      [otherId]: "uploading",
    });
  });

  it("only a dispatching message may finish or flip to sending", () => {
    beginDispatchingQueuedMessage(messageId);
    expect(markDispatchingQueuedMessageSending(otherId)).toBe(false);
    finishDispatchingQueuedMessage(otherId);
    expect(appAtomRegistry.get(dispatchingQueuedMessagesAtom)).toEqual({
      [messageId]: "uploading",
    });
  });
});
