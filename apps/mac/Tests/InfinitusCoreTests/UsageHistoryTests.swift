import XCTest
@testable import InfinitusCore

final class UsageHistoryTests: XCTestCase {
    private func win(_ pct: Double, resetsAt: Double?) -> UsageSample.Window {
        .init(pct: pct, resetsAt: resetsAt)
    }

    private func sample(t: Double, email: String = "a@x", number: Int = 1,
                        fh: UsageSample.Window? = nil,
                        sd: UsageSample.Window? = nil,
                        scoped: [String: UsageSample.Window]? = nil) -> UsageSample {
        UsageSample(t: t, email: email, number: number,
                    fiveHour: fh, sevenDay: sd, scoped: scoped)
    }

    // MARK: file round-trip

    func testAppendLoadPruneRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uh-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("h.jsonl")
        let s1 = sample(t: 100, sd: win(10, resetsAt: 7000))
        let s2 = sample(t: 200, sd: win(20, resetsAt: 7000))
        try UsageHistory.append([s1], to: url)
        try UsageHistory.append([s2], to: url)
        XCTAssertEqual(UsageHistory.load(url: url), [s1, s2])
        // torn tail line is skipped, not fatal
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd(); try h.write(contentsOf: Data("{\"t\": 3".utf8)); try h.close()
        XCTAssertEqual(UsageHistory.load(url: url).count, 2)
        let kept = try UsageHistory.prune(url: url, cutoff: Date(timeIntervalSince1970: 150))
        XCTAssertEqual(kept, 1)
        XCTAssertEqual(UsageHistory.load(url: url), [s2])
    }

    func testMergeDedupesAcrossMachines() {
        let a = sample(t: 100, sd: win(10, resetsAt: 7000))
        let b = sample(t: 200, sd: win(20, resetsAt: 7000))
        let merged = UsageHistory.merge([[a, b], [a]])   // second machine saw a too
        XCTAssertEqual(merged, [a, b])
    }

    func testDownsampleKeepsLastPerBucket() {
        let s = [sample(t: 10, sd: win(1, resetsAt: nil)),
                 sample(t: 50, sd: win(2, resetsAt: nil)),
                 sample(t: 70, sd: win(3, resetsAt: nil))]
        let thin = UsageHistory.downsample(s, bucket: 60)
        XCTAssertEqual(thin.map(\.t), [50, 70])
    }

    func testSamplesFromAccountsParsesEngineStamps() throws {
        let json = """
        {"number": 3, "email": "e@x", "organizationName": "o",
         "organizationUuid": "u", "isOrganization": true, "active": false,
         "usageStatus": "ok", "usageFetchedAt": "2026-09-01T03:19:14Z",
         "usage": {"fiveHour": {"pct": 6.0,
                                "resetsAt": "2026-09-01T08:19:59.569190+00:00"},
                   "sevenDay": {"pct": 2.0},
                   "scoped": [{"pct": 3.0, "name": "Fable",
                               "resetsAt": "2026-09-07T14:59:59.569546+00:00"}]}}
        """
        let account = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
        let s = UsageHistory.samples(accounts: [account])
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].email, "e@x")
        XCTAssertEqual(s[0].t, UsageHistory.parseISO("2026-09-01T03:19:14Z")!
            .timeIntervalSince1970)
        XCTAssertEqual(s[0].fiveHour?.pct, 6.0)
        XCTAssertNotNil(s[0].fiveHour?.resetsAt)   // fractional-second form
        XCTAssertNil(s[0].sevenDay?.resetsAt)
        XCTAssertEqual(s[0].scoped?["Fable"]?.pct, 3.0)
    }

    // MARK: waste generations

    func testGenerationClosesOnLaterReset() {
        let s = [sample(t: 100, sd: win(60, resetsAt: 1000)),
                 sample(t: 500, sd: win(79, resetsAt: 1000.4)),  // jitter: same gen
                 sample(t: 1200, sd: win(1, resetsAt: 606000))]  // rolled over
        let gens = WasteMath.generations(s, now: Date(timeIntervalSince1970: 1300))
        XCTAssertEqual(gens.count, 1)
        XCTAssertEqual(gens[0].window, "7d")
        XCTAssertEqual(gens[0].finalPct, 79)
        XCTAssertEqual(gens[0].wastePct, 21)
        XCTAssertEqual(gens[0].resetAt, 1000)
        XCTAssertEqual(gens[0].observationGap, 500)
    }

    func testGenerationClosesWhenWindowVanishes() {
        let s = [sample(t: 100, sd: win(88, resetsAt: 1000)),
                 sample(t: 1200, sd: win(0, resetsAt: nil))]
        let gens = WasteMath.generations(s, now: Date(timeIntervalSince1970: 1300))
        XCTAssertEqual(gens.count, 1)
        XCTAssertEqual(gens[0].finalPct, 88)
    }

    func testOpenGenerationClosesOncePastNow() {
        let s = [sample(t: 100, sd: win(45, resetsAt: 1000))]
        XCTAssertTrue(WasteMath.generations(
            s, now: Date(timeIntervalSince1970: 900)).isEmpty)   // still in flight
        let gens = WasteMath.generations(s, now: Date(timeIntervalSince1970: 1100))
        XCTAssertEqual(gens.count, 1)
        XCTAssertEqual(gens[0].wastePct, 55)
    }

    func testScopedWindowsTrackIndependentlyAndFiveHourIgnored() {
        let s = [sample(t: 100, fh: win(99, resetsAt: 300),
                        sd: win(10, resetsAt: 1000),
                        scoped: ["Fable": win(70, resetsAt: 1000)]),
                 sample(t: 1200, fh: win(1, resetsAt: 18300),
                        sd: win(0, resetsAt: 606000),
                        scoped: ["Fable": win(0, resetsAt: 606000)])]
        let gens = WasteMath.generations(s, now: Date(timeIntervalSince1970: 1300))
        XCTAssertEqual(gens.count, 2)   // 7d + Fable; NO 5h generation
        XCTAssertEqual(Set(gens.map(\.window)), ["7d", "Fable"])
    }
}
