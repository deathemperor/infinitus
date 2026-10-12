import { describe, expect, it } from "vite-plus/test";

import { claudeCacheTtlSeconds, normalizeClaudeTurnTokenUsage } from "./ClaudeTurnTokenUsage.ts";

/** Fork (#1557): the prompt cache TTL from a Claude result's `usage.cache_creation`. */
describe("claudeCacheTtlSeconds", () => {
  it("answers an hour when any write was 1-hour, else five minutes, else nothing", () => {
    expect(
      claudeCacheTtlSeconds({ ephemeral_5m_input_tokens: 10, ephemeral_1h_input_tokens: 5 }),
    ).toBe(3600);
    expect(
      claudeCacheTtlSeconds({ ephemeral_5m_input_tokens: 10, ephemeral_1h_input_tokens: 0 }),
    ).toBe(300);
    expect(
      claudeCacheTtlSeconds({ ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: 0 }),
    ).toBe(undefined);
    expect(claudeCacheTtlSeconds(undefined)).toBeUndefined();
    expect(claudeCacheTtlSeconds([3600])).toBeUndefined();
    expect(claudeCacheTtlSeconds({ ephemeral_1h_input_tokens: "5" })).toBeUndefined();
  });

  it("rides on the normalized turn usage only when the turn wrote the cache", () => {
    const warm = normalizeClaudeTurnTokenUsage(
      {
        subtype: "success",
        usage: {
          input_tokens: 1,
          output_tokens: 1,
          cache_creation_input_tokens: 3,
          cache_read_input_tokens: 0,
          cache_creation: { ephemeral_5m_input_tokens: 3, ephemeral_1h_input_tokens: 0 },
        },
      },
      false,
      "completed",
    );
    expect(warm).toMatchObject({ usageStatus: "complete", cacheTtlSeconds: 300 });
    const none = normalizeClaudeTurnTokenUsage(
      { subtype: "success", usage: { input_tokens: 1, output_tokens: 1 } },
      false,
      "completed",
    );
    expect(none).not.toHaveProperty("cacheTtlSeconds");
  });
});
