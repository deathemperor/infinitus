import XCTest
import InfinitusCore
@testable import InfinitusWinUI

final class SettingsPanesDataTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SettingsPanesDataTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        WinUsageHistoryRecorder.resetForTesting()
    }

    override func tearDownWithError() throws {
        WinUsageHistoryRecorder.resetForTesting()
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Event Store Tests

    func testEventStoreRoundTrip() throws {
        let file = tempDir.appendingPathComponent("events.jsonl")
        let e1 = StatsEvent(at: Date(timeIntervalSince1970: 1000), kind: "switch", icon: "arrow.left.arrow.right", text: "switched to alpha")
        let e2 = StatsEvent(at: Date(timeIntervalSince1970: 2000), kind: "death", icon: "skull", text: "alpha is out")
        let e3 = StatsEvent(at: Date(timeIntervalSince1970: 3000), kind: "revival", icon: "sparkles", text: "alpha is back")

        WinEventStore.append(e1, to: file)
        WinEventStore.append(e2, to: file)
        WinEventStore.append(e3, to: file)

        let loaded = WinEventStore.load(from: file)
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded[0].kind, "switch")
        XCTAssertEqual(loaded[0].text, "switched to alpha")
        XCTAssertEqual(loaded[1].kind, "death")
        XCTAssertEqual(loaded[2].kind, "revival")
    }

    func testEventStoreSkipsTornLine() throws {
        let file = tempDir.appendingPathComponent("events.jsonl")
        let e1 = StatsEvent(at: Date(timeIntervalSince1970: 1000), kind: "switch", icon: "arrow.left.arrow.right", text: "switch 1")
        let e2 = StatsEvent(at: Date(timeIntervalSince1970: 2000), kind: "switch", icon: "arrow.left.arrow.right", text: "switch 2")
        WinEventStore.append(e1, to: file)
        WinEventStore.append(e2, to: file)

        // Append a torn / truncated line
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"at\":\"2026-09-05T00:00:00Z\",\"kind\":\"death".utf8))

        let loaded = WinEventStore.load(from: file)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].text, "switch 1")
        XCTAssertEqual(loaded[1].text, "switch 2")
    }

    func testEventStorePrunesOlderThan400Days() throws {
        let file = tempDir.appendingPathComponent("events.jsonl")
        let now = Date(timeIntervalSince1970: 100_000_000)
        let oldInstant = now.addingTimeInterval(-450 * 86_400) // 450 days ago -> pruned
        let recentInstant = now.addingTimeInterval(-10 * 86_400) // 10 days ago -> kept

        let oldEvt = StatsEvent(at: oldInstant, kind: "switch", icon: "arrow", text: "old")
        let newEvt = StatsEvent(at: recentInstant, kind: "switch", icon: "arrow", text: "new")

        WinEventStore.append(oldEvt, to: file)
        WinEventStore.append(newEvt, to: file)

        XCTAssertEqual(WinEventStore.load(from: file).count, 2)

        WinEventStore.prune(now: now, fileURL: file)

        let loaded = WinEventStore.load(from: file)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].text, "new")
    }

    // MARK: - Usage History Recorder Tests

    func testUsageHistoryDedupesOnPollInstant() throws {
        let file = tempDir.appendingPathComponent("usage-history.jsonl")

        let acc1 = Account(
            number: 1, email: "alpha@example.com",
            usage: Usage(fiveHour: UsageWindow(pct: 42.0, resetsAt: "2026-09-05T12:00:00Z")),
            usageFetchedAt: "2026-09-05T10:00:00Z"
        )

        // Tick 1
        WinUsageHistoryRecorder.record(accounts: [acc1], to: file)
        let loaded1 = UsageHistory.load(url: file)
        XCTAssertEqual(loaded1.count, 1)
        XCTAssertEqual(loaded1[0].email, "alpha@example.com")
        XCTAssertEqual(loaded1[0].fiveHour?.pct, 42.0)

        // Tick 2 with same usageFetchedAt -> should dedupe and not append
        WinUsageHistoryRecorder.record(accounts: [acc1], to: file)
        let loaded2 = UsageHistory.load(url: file)
        XCTAssertEqual(loaded2.count, 1, "Duplicate poll instant should be deduped")

        // Tick 3 with newer usageFetchedAt -> should append
        let acc1NewPoll = Account(
            number: 1, email: "alpha@example.com",
            usage: Usage(fiveHour: UsageWindow(pct: 45.0, resetsAt: "2026-09-05T12:00:00Z")),
            usageFetchedAt: "2026-09-05T10:05:00Z"
        )
        WinUsageHistoryRecorder.record(accounts: [acc1NewPoll], to: file)
        let loaded3 = UsageHistory.load(url: file)
        XCTAssertEqual(loaded3.count, 2)
        XCTAssertEqual(loaded3[1].fiveHour?.pct, 45.0)
    }

    // MARK: - Chart Geometry Tests

    func testChartBarsHandleDegenerateInput() {
        let bounds = (x: Int32(0), y: Int32(0), width: Int32(100), height: Int32(50))

        // Empty values
        let empty = ChartMath.barRects(values: [], in: bounds)
        XCTAssertTrue(empty.isEmpty)

        // All-zero values
        let zeros = ChartMath.barRects(values: [0, 0, 0], in: bounds)
        XCTAssertEqual(zeros.count, 3)
        for b in zeros {
            XCTAssertEqual(b.height, 0)
            XCTAssertEqual(b.y, 50) // on baseline
        }

        // Single value
        let single = ChartMath.barRects(values: [50.0], in: bounds)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].width, 100)
        XCTAssertEqual(single[0].height, 50)
        XCTAssertEqual(single[0].y, 0)

        // Negative values clamped
        let neg = ChartMath.barRects(values: [-10.0, -5.0], in: bounds)
        XCTAssertEqual(neg.count, 2)
        for b in neg {
            XCTAssertEqual(b.height, 0)
        }

        // Normal values
        let normal = ChartMath.barRects(values: [10.0, 20.0], in: bounds, gap: 0)
        XCTAssertEqual(normal.count, 2)
        XCTAssertEqual(normal[0].width, 50)
        XCTAssertEqual(normal[1].width, 50)
        XCTAssertEqual(normal[0].height, 25)
        XCTAssertEqual(normal[1].height, 50)
    }

    // MARK: - Heatmap Indexing Tests

    func testHeatmapIndexing() {
        // Monday = 0, hour 0 -> slot 0
        XCTAssertEqual(ChartMath.heatmapIndex(day: 0, hour: 0), 0)
        // Monday hour 23 -> slot 23
        XCTAssertEqual(ChartMath.heatmapIndex(day: 0, hour: 23), 23)
        // Tuesday hour 0 -> slot 24
        XCTAssertEqual(ChartMath.heatmapIndex(day: 1, hour: 0), 24)
        // Sunday (6) hour 23 -> slot 167
        XCTAssertEqual(ChartMath.heatmapIndex(day: 6, hour: 23), 167)

        // Check deconstruction round-trip
        for slot in 0..<168 {
            let (d, h) = ChartMath.heatmapDayHour(from: slot)
            XCTAssertEqual(ChartMath.heatmapIndex(day: d, hour: h), slot)
        }

        // Compare with Stats.hourSlot for a known Monday date
        // 2026-08-31 was a Monday
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 8; comps.day = 31; comps.hour = 14
        let monday14 = cal.date(from: comps)!
        let expectedSlot = 0 * 24 + 14
        XCTAssertEqual(Stats.hourSlot(monday14, calendar: cal), expectedSlot)
        XCTAssertEqual(ChartMath.heatmapIndex(day: 0, hour: 14), expectedSlot)
    }

    // MARK: - Stats Chunk Loop Tests

    func testStatsChunkLoopStopsWhenStuck() {
        var state = StatsChunkLoop.State()

        // Pass 1: consumed 1000 bytes out of 2000
        let step1 = StatsChunkLoop.StepInput(remainingFiles: 5, bytesTotal: 2000, bytesRemaining: 1000)
        let (prog1, stop1) = state.step(input: step1)
        XCTAssertFalse(stop1)
        XCTAssertFalse(prog1.stuck)

        // Pass 2: fake scanner makes NO progress (bytesRemaining unchanged at 1000)
        let step2 = StatsChunkLoop.StepInput(remainingFiles: 5, bytesTotal: 2000, bytesRemaining: 1000)
        let (prog2, stop2) = state.step(input: step2)
        XCTAssertTrue(prog2.stuck, "Should detect stuck state when bytesRemaining does not decrease")
        XCTAssertTrue(stop2, "Loop must stop when stuck")
    }

    func testStatsChunkLoopStopsWhenFinished() {
        var state = StatsChunkLoop.State()

        let step1 = StatsChunkLoop.StepInput(remainingFiles: 2, bytesTotal: 2000, bytesRemaining: 1000)
        let (_, stop1) = state.step(input: step1)
        XCTAssertFalse(stop1)

        let step2 = StatsChunkLoop.StepInput(remainingFiles: 0, bytesTotal: 2000, bytesRemaining: 0)
        let (prog2, stop2) = state.step(input: step2)
        XCTAssertFalse(prog2.stuck)
        XCTAssertTrue(stop2, "Loop must stop when remainingFiles is 0")
        XCTAssertTrue(state.isDone)
    }
}
