import XCTest
@testable import InfinitusCore

final class T3ThreadSortTests: XCTestCase {
    private func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    private func t(_ id: String, created: String = "2026-06-01T00:00:00Z", _ build: (inout T3Thread) -> Void = { _ in }) -> T3Thread {
        var x = T3Thread(id: id, title: id, createdAt: d(created), updatedAt: d(created)); build(&x); return x
    }
    private func t(_ id: String, environmentId: String, created: String = "2026-06-01T00:00:00Z", _ build: (inout T3Thread) -> Void = { _ in }) -> T3Thread {
        var x = T3Thread(id: id, environmentId: environmentId, title: id, createdAt: d(created), updatedAt: d(created)); build(&x); return x
    }

    // MARK: - the brief's floor cases

    func testSpreadKeys() {
        XCTAssertEqual(T3ThreadSort.spreadPinOrderKeys(count: 3), ["gn", "nb", "tn"])
    }
    func testKeyBetween() {
        XCTAssertEqual(T3ThreadSort.pinOrderKeyBetween("dd", "ff"), "e")
        XCTAssertEqual(T3ThreadSort.pinOrderKeyBetween("e", "ff"), "f")
        XCTAssertEqual(T3ThreadSort.pinOrderKeyBetween("bb", "dd"), "c")
        XCTAssertEqual(T3ThreadSort.pinOrderKeyBetween(nil, nil), "n")
        XCTAssertNil(T3ThreadSort.pinOrderKeyBetween("ff", "dd"))
        XCTAssertNil(T3ThreadSort.pinOrderKeyBetween("da", "ff"))      // trailing "a" is corrupt
        XCTAssertNil(T3ThreadSort.pinOrderKeyBetween("d1", nil))       // non-alphabet digit
        XCTAssertEqual(T3ThreadSort.pinOrderKeyBetween("d", "db"), "dan")   // consecutive digits after the shared "d": midpoint("", "b") = "a" + midpoint("", "") = "an"
        // A stray character never reaches midpoint through the public entry — isValidKey
        // rejects it first, same as upstream's isValidPinOrderKey — but must not crash either way.
        XCTAssertNil(T3ThreadSort.pinOrderKeyBetween("a-", "z"))
        XCTAssertNil(T3ThreadSort.pinOrderKeyBetween("A", "z"))
        // Direct call to the internal `midpoint`, bypassing isValidKey, exercises the
        // -1-tolerant arithmetic itself: da = -1 for "-" (not in the digit alphabet).
        // Upstream: `PIN_ORDER_DIGITS.charAt(-1)` is "" (JS `charAt` on an out-of-range
        // index), so `pinOrderMidpoint("-", "a")` = "" + `pinOrderMidpoint("", "")` = "n".
        // The old force-unwrapping code (`digits.firstIndex(of: a.first!)!`) crashed here.
        XCTAssertEqual(T3ThreadSort.midpoint("-", "a"), "n")
    }
    func testPlanPinnedMoveMaterialisesKeylessSections() {
        let ids = ["e:a", "e:b", "e:c"]
        let plan = T3ThreadSort.planPinnedMove(orderedIds: ids, keysById: ["e:a": nil, "e:b": nil, "e:c": nil], movedId: "e:c", direction: .up)!
        XCTAssertEqual(plan, [.init(id: "e:a", orderKey: "gn"), .init(id: "e:c", orderKey: "nb"), .init(id: "e:b", orderKey: "tn")])
        XCTAssertNil(T3ThreadSort.planPinnedMove(orderedIds: ids, keysById: [:], movedId: "e:a", direction: .up))
        XCTAssertNil(T3ThreadSort.planPinnedMove(orderedIds: ids, keysById: [:], movedId: "zz", direction: .down))
    }
    func testPlanPinnedReorderWritesOnlyTheMovedKeyBetweenKeyedNeighbours() {
        let keys: [String: String?] = ["m0": "bb", "m1": "dd", "m2": "ff"]
        XCTAssertEqual(T3ThreadSort.planPinnedReorder(orderedIds: ["m1", "m0", "m2"], keysById: keys, movedId: "m0"), [.init(id: "m0", orderKey: "e")])
        // a hidden row holding "e" is reserved: the next free key is "f"
        var reserved = keys; reserved["hidden"] = "e"
        XCTAssertEqual(T3ThreadSort.planPinnedReorder(orderedIds: ["m1", "m0", "m2"], keysById: reserved, movedId: "m0"), [.init(id: "m0", orderKey: "f")])
        XCTAssertEqual(T3ThreadSort.planPinnedReorder(orderedIds: ["m1", "m0", "m2"], keysById: keys, movedId: "nope"), [])
    }
    func testSortActiveKeylessFirstThenKeys() {
        let out = T3ThreadSort.sortActive([
            t("oldest", created: "2026-06-01T08:00:00Z"), t("keyed-t") { $0.activeOrderKey = "t" },
            t("newest", created: "2026-06-01T12:00:00Z"), t("keyed-f") { $0.activeOrderKey = "f" },
            t("middle", created: "2026-06-01T10:00:00Z")])
        XCTAssertEqual(out.map(\.id), ["newest", "middle", "oldest", "keyed-f", "keyed-t"])
    }
    func testSortActiveReanchorsOnUnsettledAt() {
        let out = T3ThreadSort.sortActive([
            t("old-unsettled", created: "2026-06-01T08:00:00Z") { $0.unsettledAt = self.d("2026-06-01T13:00:00Z") },
            t("newest", created: "2026-06-01T12:00:00Z"), t("middle", created: "2026-06-01T10:00:00Z")])
        XCTAssertEqual(out.map(\.id), ["old-unsettled", "newest", "middle"])
    }
    func testSortPinnedKeyedFirstThenNewestCreated() {
        let out = T3ThreadSort.sortPinned([
            t("keyless-old", created: "2026-06-01T08:00:00Z"), t("k-t") { $0.pinOrderKey = "t" },
            t("keyless-new", created: "2026-06-01T12:00:00Z"), t("k-f") { $0.pinOrderKey = "f" }])
        XCTAssertEqual(out.map(\.id), ["k-f", "k-t", "keyless-new", "keyless-old"])
    }
    func testSettledTimestampPrefersSettledAtThenLatestStamp() {
        XCTAssertEqual(T3ThreadSort.settledTimestamp(t("a") { $0.settledAt = self.d("2026-06-01T12:00:00Z"); $0.latestUserMessageAt = self.d("2026-06-01T20:00:00Z") }), d("2026-06-01T12:00:00Z"))
        XCTAssertEqual(T3ThreadSort.settledTimestamp(t("b") { $0.latestUserMessageAt = self.d("2026-06-01T09:00:00Z"); $0.latestTurn = .init(state: .completed, requestedAt: self.d("2026-06-01T09:00:00Z"), startedAt: nil, completedAt: self.d("2026-06-01T09:10:00Z")) }), d("2026-06-01T09:10:00Z"))
        XCTAssertEqual(T3ThreadSort.settledTimestamp(t("c")), d("2026-06-01T00:00:00Z"))   // updatedAt
    }
    func testSortThreadsDescendingWithIdTiebreak() {
        let out = T3ThreadSort.sortThreads([t("a"), t("b"), t("c", created: "2026-06-01T01:00:00Z")], by: .createdAt)
        XCTAssertEqual(out.map(\.id), ["c", "b", "a"])
    }

    // MARK: - threadSort.test.ts, transcribed one `it` per method

    // describe("resolveSettledThreadTimestamp")
    func testPrefersThePersistedSettlementStampOverLaterActivity() {
        let thread = t("thread-1") {
            $0.settledAt = self.d("2026-03-09T10:00:00Z")
            $0.latestUserMessageAt = self.d("2026-03-09T11:00:00Z")
            $0.updatedAt = self.d("2026-03-09T12:00:00Z")
        }
        XCTAssertEqual(T3ThreadSort.settledTimestamp(thread), d("2026-03-09T10:00:00Z"))
    }
    // upstream also covers a malformed settledAt string; T3Thread.settledAt is a
    // typed Date? and can't hold a malformed value, so only the "missing" half ports.
    func testFallsBackToTheLatestActivityWhenTheStampIsMissing() {
        let withMessage = t("thread-1") {
            $0.latestUserMessageAt = self.d("2026-03-09T11:00:00Z")
            $0.updatedAt = self.d("2026-03-09T12:00:00Z")
        }
        XCTAssertEqual(T3ThreadSort.settledTimestamp(withMessage), d("2026-03-09T11:00:00Z"))
        let withoutMessage = t("thread-1") { $0.updatedAt = self.d("2026-03-09T12:00:00Z") }
        XCTAssertEqual(T3ThreadSort.settledTimestamp(withoutMessage), d("2026-03-09T12:00:00Z"))
    }

    // describe("sortThreads")
    // Upstream's two cases exercise malformed ISO strings and a `messages` array
    // scan; T3Thread has neither (Date is always valid, no messages field — the
    // brief collapses the host-side scan to `latestUserMessageAt ?? updatedAt`).
    // These port the surviving behaviour: updatedAt fallback, then
    // latestUserMessageAt precedence, under `.updatedAt` order.
    func testSortThreadsFallsBackToUpdatedAtWhenLatestUserMessageAtIsMissing() {
        let sorted = T3ThreadSort.sortThreads([
            t("thread-1", created: "2026-03-09T10:00:00Z") { $0.updatedAt = self.d("2026-03-09T10:05:00Z") },
            t("thread-3", created: "2026-03-09T10:06:00Z") { $0.updatedAt = self.d("2026-03-09T10:06:00Z") },
            t("thread-2", created: "2026-03-09T10:00:00Z") { $0.updatedAt = self.d("2026-03-09T10:00:00Z") },
        ], by: .updatedAt)
        XCTAssertEqual(sorted.map(\.id), ["thread-3", "thread-1", "thread-2"])
    }
    func testSortThreadsPrefersLatestUserMessageAtOverUpdatedAtWhenBothArePresent() {
        let sorted = T3ThreadSort.sortThreads([
            t("thread-1", created: "2026-03-09T10:00:00Z") {
                $0.updatedAt = self.d("2026-03-09T10:00:00Z")
                $0.latestUserMessageAt = self.d("2026-03-09T10:20:00Z")
            },
            t("thread-2", created: "2026-03-09T10:15:00Z") { $0.updatedAt = self.d("2026-03-09T10:15:00Z") },
        ], by: .updatedAt)
        XCTAssertEqual(sorted.map(\.id), ["thread-1", "thread-2"])
    }

    // describe("planPinnedReorder with hidden rows")
    func testKeepsHiddenSlotsAvailableWhenInsertingBetweenVisibleNeighbours() {
        let midpoint = T3ThreadSort.pinOrderKeyBetween("f", "t")!
        let keysById: [String: String?] = ["a": "f", "b": "t", "moved": "z", "snoozed": midpoint]
        let assignments = T3ThreadSort.planPinnedReorder(orderedIds: ["a", "moved", "b"], keysById: keysById, movedId: "moved")
        XCTAssertEqual(assignments.count, 1)
        let key = assignments[0].orderKey
        XCTAssertTrue(key > "f" && key < "t")
        XCTAssertNotEqual(key, midpoint)
        XCTAssertEqual(assignments[0].id, "moved")
    }
    func testMaterializesKeylessRowsWithoutOverwritingHiddenSlots() {
        let reserved = T3ThreadSort.spreadPinOrderKeys(count: 6)
        var keysById: [String: String?] = ["a": nil, "b": nil, "c": nil]
        for (i, key) in reserved.enumerated() { keysById["hidden-\(i)"] = key }
        let assignments = T3ThreadSort.planPinnedReorder(orderedIds: ["c", "a", "b"], keysById: keysById, movedId: "c")
        XCTAssertEqual(assignments.map(\.id), ["c", "a", "b"])
        let keys = assignments.map(\.orderKey)
        XCTAssertEqual(keys.sorted(), keys)
        XCTAssertEqual(Set(keys).count, 3)
        XCTAssertTrue(keys.allSatisfy { !reserved.contains($0) })
    }

    // describe("planPinnedMove")
    func testMovesAThreadUpWithASingleKeyWrite() {
        let assignments = T3ThreadSort.planPinnedMove(orderedIds: ["a", "b", "c"], keysById: ["a": "f", "b": "m", "c": "t"], movedId: "c", direction: .up)!
        XCTAssertEqual(assignments.count, 1)
        XCTAssertEqual(assignments[0].id, "c")
        XCTAssertTrue(assignments[0].orderKey > "f" && assignments[0].orderKey < "m")
    }
    func testReturnsNilWhenTheMoveFallsOffTheEndOfTheList() {
        let keysById: [String: String?] = ["a": "f", "b": "m"]
        XCTAssertNil(T3ThreadSort.planPinnedMove(orderedIds: ["a", "b"], keysById: keysById, movedId: "a", direction: .up))
        XCTAssertNil(T3ThreadSort.planPinnedMove(orderedIds: ["a", "b"], keysById: keysById, movedId: "b", direction: .down))
    }
    func testMaterializesKeysForTheWholeSectionWhenANeighbourIsKeyless() {
        let assignments = T3ThreadSort.planPinnedMove(orderedIds: ["a", "b", "c"], keysById: ["a": nil, "b": "m", "c": nil], movedId: "b", direction: .up)!
        let keys = assignments.map(\.orderKey)
        XCTAssertEqual(keys.sorted(), keys)
    }

    // describe("sortPinnedThreadsByOrderKey")
    func testBreaksEqualKeysByIdThenEnvironmentSoMergedListsAreStableEverywhere() {
        let out = T3ThreadSort.sortPinned([
            t("thread-1", environmentId: "env-b", created: "2026-03-09T10:00:00Z") { $0.pinOrderKey = "m" },
            t("thread-1", environmentId: "env-a", created: "2026-03-09T11:00:00Z") { $0.pinOrderKey = "m" },
        ])
        XCTAssertEqual(out.map(\.environmentId), ["env-a", "env-b"])
    }

    // describe("generateSpreadPinOrderKeys")
    func testLeavesUniqueInsertableKeysForNThreads() {
        for count in [0, 1, 650, 675, 676, 1_001, 2_000] {
            let keys = T3ThreadSort.spreadPinOrderKeys(count: count)
            XCTAssertEqual(keys.count, count)
            XCTAssertEqual(Set(keys).count, count)
            XCTAssertEqual(keys.sorted(), keys)
            for index in 0..<keys.count {
                let before = index > 0 ? keys[index - 1] : nil
                let after = keys[index]
                XCTAssertNotEqual(after.last, "a")
                let between = T3ThreadSort.pinOrderKeyBetween(before, after)
                XCTAssertNotNil(between)
                XCTAssertTrue(between! < after)
                if let before { XCTAssertTrue(between! > before) }
            }
        }
    }

    // describe("sortActiveThreadsByOrderKey")
    func testKeepsNewAndReopenedThreadsAheadOfTheSavedOrder() {
        let out = T3ThreadSort.sortActive([
            t("arranged-first", created: "2026-03-09T09:00:00Z") { $0.activeOrderKey = "f" },
            t("new", created: "2026-03-09T11:00:00Z") { $0.activeOrderKey = nil },
            t("arranged-last", created: "2026-03-09T12:00:00Z") { $0.unsettledAt = self.d("2026-03-09T13:00:00Z"); $0.activeOrderKey = "t" },
            t("reopened", created: "2026-03-01T09:00:00Z") { $0.unsettledAt = self.d("2026-03-09T12:00:00Z") },
        ])
        XCTAssertEqual(out.map(\.id), ["reopened", "new", "arranged-first", "arranged-last"])
    }
    func testBreaksEqualOrderKeysAndTimestampsByThreadThenEnvironment() {
        for activeOrderKey: String? in [nil, "m"] {
            let threads = [
                t("thread-b", environmentId: "env-a", created: "2026-03-09T10:00:00Z") { $0.activeOrderKey = activeOrderKey },
                t("thread-a", environmentId: "env-b", created: "2026-03-09T10:00:00Z") { $0.activeOrderKey = activeOrderKey },
                t("thread-a", environmentId: "env-a", created: "2026-03-09T10:00:00Z") { $0.activeOrderKey = activeOrderKey },
            ]
            let out = T3ThreadSort.sortActive(threads).map { "\($0.id):\($0.environmentId)" }
            XCTAssertEqual(out, ["thread-a:env-a", "thread-a:env-b", "thread-b:env-a"])
        }
    }
    func testAppliesEveryMoveAcrossAMixedKeylessAndKeyedSection() {
        let threads = (0..<6).map { index in
            t(String(index), created: "2026-03-09T0\(6 - index):00:00Z") { $0.activeOrderKey = index < 3 ? nil : ["f", "m", "t"][index - 3] }
        }
        let ids = threads.map(\.id)
        let keysById: [String: String?] = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0.activeOrderKey) })
        for movedId in ids {
            for targetIndex in 0..<ids.count {
                var desired = ids.filter { $0 != movedId }
                desired.insert(movedId, at: targetIndex)
                let assignments = T3ThreadSort.planPinnedReorder(orderedIds: desired, keysById: keysById, movedId: movedId)
                let nextKeys: [String: String] = Dictionary(uniqueKeysWithValues: assignments.map { ($0.id, $0.orderKey) })
                let updated = threads.map { thread -> T3Thread in
                    var x = thread
                    if let key = nextKeys[thread.id] { x.activeOrderKey = key }
                    return x
                }
                XCTAssertEqual(T3ThreadSort.sortActive(updated).map(\.id), desired)
            }
        }
    }
    func testMovesAKeylessThreadIntoTheArrangedRunWithOneWrite() {
        let assignments = T3ThreadSort.planPinnedMove(
            orderedIds: ["new", "reopened", "first", "last"],
            keysById: ["new": nil, "reopened": nil, "first": "f", "last": "t"],
            movedId: "reopened", direction: .down)!
        XCTAssertEqual(assignments.count, 1)
        XCTAssertEqual(assignments[0].id, "reopened")
        XCTAssertTrue(assignments[0].orderKey > "f" && assignments[0].orderKey < "t")
    }
    func testMaterializesALargeActiveListWithoutChangingTheRequestedOrder() {
        let threads = (0..<1_200).map { index in t(String(index), created: "2026-03-09T10:00:00Z") }
        let orderedIds = threads.map(\.id).reversed().map { $0 }
        let keysById: [String: String?] = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0.activeOrderKey) })
        let assignments = T3ThreadSort.planPinnedReorder(orderedIds: orderedIds, keysById: keysById, movedId: orderedIds[0])
        let nextKeys: [String: String] = Dictionary(uniqueKeysWithValues: assignments.map { ($0.id, $0.orderKey) })
        let updated = threads.map { thread -> T3Thread in
            var x = thread
            x.activeOrderKey = nextKeys[thread.id]
            return x
        }
        XCTAssertEqual(T3ThreadSort.sortActive(updated).map(\.id), orderedIds)
    }
}
