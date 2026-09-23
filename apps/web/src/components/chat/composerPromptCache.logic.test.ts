import { promptCacheState } from "@infinitus/shared/threadUsage";
import { describe, expect, it } from "vite-plus/test";

import { promptCacheDetail } from "./composerPromptCache.logic";

describe("composer prompt cache tooltip", () => {
  it("tells a cold thread what the next message re-sends", () => {
    expect(promptCacheDetail({ kind: "cold", reason: "expired" }, 150_000)).toContain(
      "(≈ 150k tokens)",
    );
    expect(promptCacheDetail({ kind: "cold", reason: "expired" }, null)).not.toContain("tokens)");
    expect(promptCacheDetail({ kind: "cold", reason: "restart" }, null)).toContain(
      "session has stopped",
    );
  });

  it("names the time left and the cache's TTL while warm", () => {
    const warm = promptCacheState(
      { lastTurnAt: "2026-09-23T10:00:00.000Z", cacheExpiresAt: "2026-09-23T11:00:00.000Z" },
      Date.parse("2026-09-23T10:30:00.000Z"),
      true,
    );
    expect(warm && promptCacheDetail(warm, null)).toContain("30m more (1-hour cache)");
  });
});
