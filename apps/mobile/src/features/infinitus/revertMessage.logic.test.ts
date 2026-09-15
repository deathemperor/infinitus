import type { MessageId, OrchestrationThread } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import { restoreFilesConfirmText, revertTurnCountByUserMessageId } from "./revertMessage.logic";

type Message = OrchestrationThread["messages"][number];

function message(id: string, role: "user" | "assistant"): Message {
  return { id, role } as unknown as Message;
}

function checkpoint(checkpointTurnCount: number, assistantMessageId: string | null) {
  return { checkpointTurnCount, assistantMessageId: assistantMessageId as MessageId | null };
}

describe("revertTurnCountByUserMessageId", () => {
  it("maps each user message to the checkpoint before the turn it started", () => {
    const map = revertTurnCountByUserMessageId({
      messages: [
        message("u1", "user"),
        message("a1", "assistant"),
        message("u2", "user"),
        message("a2a", "assistant"),
        message("a2b", "assistant"),
      ],
      checkpoints: [checkpoint(1, "a1"), checkpoint(2, "a2b")],
    });
    expect([...map]).toEqual([
      ["u1", 0],
      ["u2", 1],
    ]);
  });

  it("skips a user message whose turn has no checkpointed assistant message", () => {
    const map = revertTurnCountByUserMessageId({
      messages: [
        message("u1", "user"),
        message("a1", "assistant"),
        message("u2", "user"),
        message("a2", "assistant"),
      ],
      checkpoints: [checkpoint(2, "a2"), checkpoint(3, null)],
    });
    expect([...map]).toEqual([["u2", 1]]);
  });

  it("stops the walk at the next user message", () => {
    const map = revertTurnCountByUserMessageId({
      messages: [message("u1", "user"), message("u2", "user"), message("a2", "assistant")],
      checkpoints: [checkpoint(1, "a2")],
    });
    expect([...map]).toEqual([["u2", 0]]);
  });

  it("names the checkpoint the web's confirm names", () => {
    expect(restoreFilesConfirmText(3)).toBe(
      "Restore the files to checkpoint 3? The chat stays as it is.",
    );
  });
});
