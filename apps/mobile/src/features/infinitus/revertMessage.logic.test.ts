import type { MessageId, OrchestrationThread } from "@infinitus/contracts";
import { describe, expect, it } from "vite-plus/test";

import {
  restoreFilesConfirmText,
  revertMenuActions,
  revertTurnCountByUserMessageId,
  revertedMessageEditableText,
} from "./revertMessage.logic";

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

describe("revertMenuActions", () => {
  it("offers every mode in the web's order when the provider rolls back and forks", () => {
    expect(revertMenuActions({ canRollback: true, canRestoreFiles: true, canFork: true })).toEqual([
      "files",
      "restore-files",
      "chat",
      "fork",
    ]);
  });

  it("keeps only the file restore and the fork without conversation rollback", () => {
    expect(revertMenuActions({ canRollback: false, canRestoreFiles: true, canFork: true })).toEqual(
      ["restore-files", "fork"],
    );
    expect(
      revertMenuActions({ canRollback: false, canRestoreFiles: true, canFork: false }),
    ).toEqual(["restore-files"]);
  });

  it("drops the two file modes in a shared project directory", () => {
    expect(revertMenuActions({ canRollback: true, canRestoreFiles: false, canFork: true })).toEqual(
      ["chat", "fork"],
    );
    expect(
      revertMenuActions({ canRollback: false, canRestoreFiles: false, canFork: false }),
    ).toEqual([]);
  });
});

describe("revertedMessageEditableText", () => {
  it("drops the effort prefix and the review comments appended after the text", () => {
    const text =
      'Ultrathink:\nFix the loop\n\n<review_comment file="a.ts">\nslow\n</review_comment>\n<review_comment file="b.ts">\nunused\n</review_comment>';
    expect(revertedMessageEditableText(text)).toBe("Fix the loop");
  });

  it("keeps a review comment block the user typed before more text", () => {
    const text = '<review_comment file="a.ts">\nslow\n</review_comment>\nand also this';
    expect(revertedMessageEditableText(text)).toBe(text);
  });
});
