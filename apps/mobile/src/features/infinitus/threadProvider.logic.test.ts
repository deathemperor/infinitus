import type { ServerConfig } from "@infinitus/contracts";
import { describe, expect, it } from "vite-plus/test";

import { threadProviderSnapshot } from "./threadProvider.logic";

const config = {
  providers: [
    { instanceId: "claude-1", driver: "claudeAgent" },
    { instanceId: "codex-1", driver: "codex" },
  ],
} as unknown as ServerConfig;

describe("threadProviderSnapshot", () => {
  it("prefers the running session's instance over the model selection", () => {
    expect(
      threadProviderSnapshot(config, {
        session: { providerInstanceId: "codex-1" },
        modelSelection: { instanceId: "claude-1" },
      } as never)?.driver,
    ).toBe("codex");
    expect(
      threadProviderSnapshot(config, {
        session: null,
        modelSelection: { instanceId: "claude-1" },
      } as never)?.driver,
    ).toBe("claudeAgent");
  });

  it("is null without a config or a matching instance", () => {
    const thread = { session: null, modelSelection: { instanceId: "gone" } } as never;
    expect(threadProviderSnapshot(null, thread)).toBeNull();
    expect(threadProviderSnapshot(config, thread)).toBeNull();
  });
});
