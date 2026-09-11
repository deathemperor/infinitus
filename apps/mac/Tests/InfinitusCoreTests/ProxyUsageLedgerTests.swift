import XCTest
@testable import InfinitusCore

final class ProxyUsageLedgerTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pul-\(UUID().uuidString)")
            .appendingPathComponent("usage.jsonl")
    }

    private func rawRecord(authIndex: String, model: String, timestamp: String,
                            uncached: Int, output: Int, cacheRead: Int, cacheWrite: Int,
                            extra: [String: Any] = [:]) -> [String: Any] {
        var d: [String: Any] = [
            "timestamp": timestamp,
            "auth_index": authIndex,
            "provider": "claude",
            "model": model,
            "token_breakdown": [
                "total_tokens": uncached + output + cacheRead + cacheWrite,
                "input": [
                    "total_tokens": uncached + cacheRead + cacheWrite,
                    "uncached_tokens": uncached,
                    "cache_read_tokens": cacheRead,
                    "cache_write_tokens": cacheWrite,
                ],
                "output": [
                    "total_tokens": output,
                    "non_reasoning_tokens": output,
                    "reasoning_tokens": 0,
                ],
                "unclassified_tokens": 0,
            ],
        ]
        for (k, v) in extra { d[k] = v }
        return d
    }

    // MARK: decodeQueue

    func testDecodeQueueSkipsMalformedAndIgnoresSensitiveKeys() throws {
        let good = rawRecord(authIndex: "a1", model: "claude-sonnet-4-5",
                              timestamp: "2026-09-01T10:00:00.123456789+07:00",
                              uncached: 1000, output: 100, cacheRead: 0, cacheWrite: 0,
                              extra: ["client_ip": "10.0.0.9", "api_key": "sk-secret"])
        let malformed: [String: Any] = ["timestamp": "not-a-date", "auth_index": "a2"]
        let notEvenAnObject = "oops"
        let arr: [Any] = [good, malformed, notEvenAnObject]
        let data = try JSONSerialization.data(withJSONObject: arr)

        let records = ProxyUsageRecord.decodeQueue(data)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].authIndex, "a1")

        let encoded = try JSONEncoder().encode(records[0])
        let line = String(data: encoded, encoding: .utf8)!
        XCTAssertFalse(line.contains("10.0.0.9"))
        XCTAssertFalse(line.contains("sk-secret"))
        XCTAssertFalse(line.contains("client_ip"))
        XCTAssertFalse(line.contains("api_key"))
    }

    func testTimestampParsingToleratesFractionalWidthAndOffset() {
        XCTAssertNotNil(ProxyUsageRecord.parseTimestamp("2026-09-01T10:00:00.123456789+07:00"))
        XCTAssertNotNil(ProxyUsageRecord.parseTimestamp("2026-09-01T10:00:00Z"))
        XCTAssertNil(ProxyUsageRecord.parseTimestamp("garbage"))
    }

    // MARK: append / records(since:) round trip

    func testAppendThenRecordsSinceRoundTrip() async throws {
        let url = tempURL()
        let ledger = ProxyUsageLedger(url: url)
        let old = ProxyUsageRecord(timestamp: "2020-01-01T00:00:00Z", authIndex: "a1",
                                    provider: "claude", model: "claude-sonnet-4-5",
                                    tokenBreakdown: .init())
        let recent = ProxyUsageRecord(timestamp: "2026-09-01T00:00:00Z", authIndex: "a1",
                                       provider: "claude", model: "claude-sonnet-4-5",
                                       tokenBreakdown: .init())
        try await ledger.append([old, recent])

        let since = ISO8601DateFormatter().date(from: "2025-01-01T00:00:00Z")!
        let got = try await ledger.records(since: since)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].timestamp, "2026-09-01T00:00:00Z")
    }

    // MARK: prune

    func testPruneDropsOldLinesWhenOverThreshold() async throws {
        let url = tempURL()
        let ledger = ProxyUsageLedger(url: url, pruneThresholdBytes: 0)
        let old = ProxyUsageRecord(timestamp: "2020-01-01T00:00:00Z", authIndex: "a1",
                                    provider: "claude", model: "claude-sonnet-4-5",
                                    tokenBreakdown: .init())
        let recent = ProxyUsageRecord(timestamp: "2026-09-01T00:00:00Z", authIndex: "a1",
                                       provider: "claude", model: "claude-sonnet-4-5",
                                       tokenBreakdown: .init())
        try await ledger.append([old])
        try await ledger.append([recent])   // threshold 0 forces a prune on this append

        let all = try await ledger.records(since: .distantPast)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].timestamp, "2026-09-01T00:00:00Z")
    }

    // MARK: price table

    func testPriceMatchesVariantSuffixAndDateSuffix() {
        XCTAssertNotNil(StaticPriceTable.price(model: "claude-fable-5[1m]"))
        XCTAssertNotNil(StaticPriceTable.price(model: "claude-haiku-4-5-20251001"))
        XCTAssertNil(StaticPriceTable.price(model: "gpt-5"))
    }

    // MARK: report()

    func testReportAggregatesPricesAndUnattributes() async throws {
        let url = tempURL()
        let ledger = ProxyUsageLedger(url: url)
        let now = ISO8601DateFormatter().date(from: "2026-09-02T12:00:00Z")!

        // Priced: sonnet-4-5, uncached 1_000_000 / output 100_000 /
        // read 1_000_000 / write 200_000 -> 3.0 + 1.5 + 0.3 + 0.75 = 5.55.
        let priced = ProxyUsageRecord(
            timestamp: "2026-09-02T10:00:00Z", authIndex: "known",
            provider: "claude", model: "claude-sonnet-4-5",
            tokenBreakdown: .init(
                totalTokens: 2_200_000,
                input: .init(totalTokens: 2_200_000, uncachedTokens: 1_000_000,
                             cacheReadTokens: 1_000_000, cacheWriteTokens: 200_000),
                output: .init(totalTokens: 100_000, nonReasoningTokens: 100_000, reasoningTokens: 0),
                unclassifiedTokens: 0))

        // Unpriced model.
        let unpriced = ProxyUsageRecord(
            timestamp: "2026-09-02T11:00:00Z", authIndex: "known",
            provider: "openai", model: "gpt-5",
            tokenBreakdown: .init(
                totalTokens: 500, input: .init(totalTokens: 500, uncachedTokens: 500),
                output: .init(), unclassifiedTokens: 0))

        // Unmapped auth_index -> unattributed.
        let unmapped = ProxyUsageRecord(
            timestamp: "2026-09-02T09:00:00Z", authIndex: "stranger",
            provider: "claude", model: "claude-sonnet-4-5",
            tokenBreakdown: .init(
                totalTokens: 1_000_000, input: .init(totalTokens: 1_000_000, uncachedTokens: 1_000_000),
                output: .init(), unclassifiedTokens: 0))

        // Old record, outside the 7-day window.
        let old = ProxyUsageRecord(
            timestamp: "2026-08-01T00:00:00Z", authIndex: "known",
            provider: "claude", model: "claude-sonnet-4-5",
            tokenBreakdown: .init(
                totalTokens: 1_000_000, input: .init(totalTokens: 1_000_000, uncachedTokens: 1_000_000),
                output: .init(), unclassifiedTokens: 0))

        try await ledger.append([priced, unpriced, unmapped, old])

        let report = await ledger.report(days: 7, numbers: ["known": 1],
                                          emails: ["known": "a@x.io"], now: now)

        XCTAssertEqual(report.accounts.count, 1)
        let bucket = report.accounts[0]
        XCTAssertEqual(bucket.number, 1)
        XCTAssertEqual(bucket.email, "a@x.io")
        XCTAssertEqual(bucket.messages, 2)
        XCTAssertEqual(bucket.estimatedUSD, 5.55, accuracy: 1e-9)

        XCTAssertEqual(report.unpricedTokens, 500)

        XCTAssertNotNil(report.unattributed)
        XCTAssertEqual(report.unattributed?.messages, 1)
        XCTAssertNil(report.unattributed?.number)

        // Daily slices: known-account day should be its own slice, separate
        // from the unattributed day (same date, account nil).
        let dailyForKnown = report.daily?.first { $0.account == 1 }
        XCTAssertNotNil(dailyForKnown)
        XCTAssertEqual(dailyForKnown?.messages, 2)
        let dailyUnattributed = report.daily?.first { $0.account == nil }
        XCTAssertNotNil(dailyUnattributed)

        // 5.55 (known) + 3.0 (unattributed: sonnet-4-5, 1M uncached tokens).
        XCTAssertEqual(report.estimatedTotalUSD, 8.55, accuracy: 1e-9)
        XCTAssertEqual(report.priceTable.source, StaticPriceTable.source)
        XCTAssertEqual(report.priceTable.date, StaticPriceTable.date)
    }
}
