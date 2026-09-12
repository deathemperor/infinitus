import type { InfinitusManifestCommand } from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  MAX_PUSH_TITLE_LENGTH,
  manifestHasPush,
  shouldPushPhase,
  threadPhasePayload,
} from "./infinitusPushBridge.logic.ts";

const command = (
  name: string,
  stdin?: string | null,
  summary = "…({kind, threadId, title, phase, detail?, local?}); `local: false` skips…",
): InfinitusManifestCommand => ({
  name,
  args: [],
  options: [],
  effect: "write",
  summary,
  replyShape: "",
  ...(stdin === undefined ? {} : { stdin }),
});

describe("push bridge logic (#269 G)", () => {
  it("pushes a change into a phase a person acts on, never a first sighting or a repeat", () => {
    expect(shouldPushPhase("running", "waiting_for_approval")).toBe(true);
    expect(shouldPushPhase("running", "waiting_for_input")).toBe(true);
    expect(shouldPushPhase("running", "completed")).toBe(true);
    expect(shouldPushPhase("running", "failed")).toBe(true);
    expect(shouldPushPhase("completed", "running")).toBe(false);
    expect(shouldPushPhase("completed", "starting")).toBe(false);
    expect(shouldPushPhase("running", "stale")).toBe(false);
    expect(shouldPushPhase(undefined, "completed")).toBe(false);
    expect(shouldPushPhase("completed", "completed")).toBe(false);
  });

  it("encodes the verb's payload with the title cut to size", () => {
    expect(
      JSON.parse(
        threadPhasePayload({ threadId: "thread-1", title: "  Fix the build ", phase: "failed" }),
      ),
    ).toEqual({
      kind: "thread.phase",
      threadId: "thread-1",
      title: "Fix the build",
      phase: "failed",
      local: false,
    });
    const long = "x".repeat(MAX_PUSH_TITLE_LENGTH + 20);
    const title = JSON.parse(
      threadPhasePayload({ threadId: "thread-1", title: long, phase: "completed" }),
    ).title as string;
    expect(title).toHaveLength(MAX_PUSH_TITLE_LENGTH);
    expect(title.endsWith("…")).toBe(true);
  });

  it("gates on a push verb that takes a payload and knows the local flag", () => {
    expect(manifestHasPush([command("push", "payload")])).toBe(true);
    // An app from before the flag would post its own notice beside the desktop's.
    expect(manifestHasPush([command("push", "payload", "A thread phase on stdin.")])).toBe(false);
    expect(manifestHasPush([command("push", "secret")])).toBe(false);
    expect(manifestHasPush([command("push")])).toBe(false);
    expect(manifestHasPush([command("status")])).toBe(false);
  });
});
