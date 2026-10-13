// The fork's aggregator cases (#779 account attribution), beside upstream's
// `usageAggregation.test.ts`; the fixtures are copies of that file's.
import { describe, expect, it } from "@effect/vitest";

import { UsageAggregator } from "./usageAggregation.ts";
import { priceUsage, type RateTable } from "./usagePricing.ts";
import type { UsageRecord } from "@infinitus/provider-core/server/usage";

const rates: RateTable = new Map([
  [
    "claude-fable-5",
    {
      inputCostPerToken: 1e-5,
      outputCostPerToken: 5e-5,
      cacheReadCostPerToken: 1e-6,
      cacheCreationCostPerToken: 1.25e-5,
      fast: {
        inputCostPerToken: 2e-5,
        outputCostPerToken: 1e-4,
        cacheReadCostPerToken: 2e-6,
        cacheCreationCostPerToken: 2.5e-5,
      },
      ultrafast: null,
    },
  ],
]);

function record(overrides: Partial<UsageRecord> = {}): UsageRecord {
  return {
    provider: "claude",
    // 2026-08-07T04:05Z is still Aug 6 in Los Angeles.
    timestampMs: Date.parse("2026-08-07T04:05:13.944Z"),
    model: "claude-fable-5",
    sessionId: "session-a",
    totals: {
      uncachedInputTokens: 100,
      cachedInputTokens: 1000,
      cacheCreationTokens: 10,
      outputTokens: 50,
      reasoningTokens: 0,
    },
    reportedCostUsd: null,
    speed: "standard",
    dedupeKey: null,
    ...overrides,
  };
}

function aggregate(records: readonly UsageRecord[]) {
  const aggregator = new UsageAggregator({
    timeZone: "UTC",
    sinceDay: "2026-08-01",
    untilDay: "2026-08-31",
    rates,
  });
  for (const item of records) aggregator.add(item);
  return aggregator.finish();
}

describe("UsageAggregator account attribution", () => {
  it("attributes Claude records to the account the hook names, the rest to unattributed or notClaude", () => {
    const oneRecordUsd = priceUsage(rates, record()).costUsd;
    const aggregator = new UsageAggregator({
      timeZone: "UTC",
      sinceDay: "2026-08-01",
      untilDay: "2026-08-31",
      rates,
      attribute: (timestampMs) =>
        timestampMs < Date.parse("2026-08-07T04:05:13Z") ? "one@example.invalid" : null,
    });
    aggregator.add(record({ timestampMs: Date.parse("2026-08-07T04:05:12Z") }));
    aggregator.add(record({ timestampMs: Date.parse("2026-08-07T04:05:12Z"), dedupeKey: "a" }));
    aggregator.add(record({ timestampMs: Date.parse("2026-08-07T04:05:13Z") }));
    aggregator.add(record({ provider: "codex", model: "gpt-5.6-sol" }));
    aggregator.add(record({ timestampMs: Date.parse("2026-07-01T12:00:00Z") }));
    const result = aggregator.finish();

    expect(result.attribution).toEqual({
      lines: [
        {
          email: "one@example.invalid",
          totals: {
            uncachedInputTokens: 200,
            cachedInputTokens: 2000,
            cacheCreationTokens: 20,
            outputTokens: 100,
            reasoningTokens: 0,
          },
          costUsd: expect.closeTo(oneRecordUsd * 2, 9),
          records: 2,
        },
      ],
      unattributed: {
        totals: {
          uncachedInputTokens: 100,
          cachedInputTokens: 1000,
          cacheCreationTokens: 10,
          outputTokens: 50,
          reasoningTokens: 0,
        },
        costUsd: expect.closeTo(oneRecordUsd, 9),
        records: 1,
      },
      notClaude: { costUsd: 0, records: 1 },
    });
    // Unchanged: the buckets never learn about accounts.
    expect(result.buckets).toHaveLength(2);
  });

  it("orders attributed lines by cost, highest first", () => {
    const aggregator = new UsageAggregator({
      timeZone: "UTC",
      sinceDay: "2026-08-01",
      untilDay: "2026-08-31",
      rates,
      attribute: (timestampMs) =>
        timestampMs % 2 === 0 ? "small@example.invalid" : "big@example.invalid",
    });
    aggregator.add(record({ timestampMs: Date.parse("2026-08-07T04:05:12.000Z") }));
    aggregator.add(record({ timestampMs: Date.parse("2026-08-07T04:05:12.001Z") }));
    aggregator.add(record({ timestampMs: Date.parse("2026-08-07T04:05:12.003Z") }));

    expect(aggregator.finish().attribution?.lines.map((line) => line.email)).toEqual([
      "big@example.invalid",
      "small@example.invalid",
    ]);
  });

  it("carries no attribution without a hook", () => {
    expect(aggregate([record()]).attribution).toBeUndefined();
  });
});
