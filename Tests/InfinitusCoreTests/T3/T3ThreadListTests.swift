import XCTest
@testable import InfinitusCore

final class T3ThreadListTests: XCTestCase {
    private let f: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private func d(_ s: String) -> Date { f.date(from: s.contains(".") ? s : s.replacingOccurrences(of: "Z", with: ".000Z"))! }
    private let NOW = ISO8601DateFormatter().date(from: "2026-06-02T00:00:00Z")!
    private func t(_ id: String, title: String? = nil, _ build: (inout T3Thread) -> Void = { _ in }) -> T3Thread {
        var x = T3Thread(id: id, title: title ?? id, createdAt: d("2026-06-01T00:00:00Z"), updatedAt: d("2026-06-01T00:00:00Z")); build(&x); return x
    }
    private func build(_ threads: [T3Thread], _ tweak: (inout T3ThreadList.Input) -> Void = { _ in }) -> T3ThreadList.Layout {
        var i = T3ThreadList.Input(threads: threads, now: NOW); tweak(&i); return T3ThreadList.buildItems(i)
    }

    // "places a persisted settled thread in the settled shelf"
    func testPersistedSettledThreadLandsOnTheShelf() {
        let l = build([t("linked-merged") { $0.settledOverride = .settled; $0.settledAt = self.NOW }])
        XCTAssertEqual(l.settledCount, 1); XCTAssertEqual(l.items[0].variant, .slim)
    }
    // "hides snoozed threads and counts them"
    func testHidesSnoozedAndCounts() {
        let l = build([t("active"), t("snoozed") { $0.snoozedUntil = self.d("2026-06-03T09:00:00Z"); $0.snoozedAt = self.d("2026-06-01T12:00:00Z") },
                       t("woken") { $0.snoozedUntil = self.d("2026-06-01T18:00:00Z"); $0.snoozedAt = self.d("2026-06-01T12:00:00Z") }])
        XCTAssertEqual(l.items.map(\.thread.id), ["active", "woken"]); XCTAssertEqual(l.snoozedCount, 1)
    }
    // "places settled pinned threads in the settled shelf"
    func testSettledPinnedGoesToTheShelf() {
        let l = build([t("active"), t("pinned-settled") { $0.pinnedAt = self.d("2026-06-01T12:00:00Z"); $0.settledOverride = .settled; $0.settledAt = self.d("2026-06-01T12:00:00Z") }])
        XCTAssertEqual(l.items.map(\.thread.id), ["active", "pinned-settled"]); XCTAssertEqual(l.items.map(\.pinned), [false, false]); XCTAssertEqual(l.settledCount, 1)
    }
    // "keeps active pinned threads in the pinned block"
    func testActivePinnedStaysPinned() {
        let l = build([t("pinned", title: "Pinned thread") { $0.pinnedAt = self.d("2026-06-01T12:00:00Z") }])
        XCTAssertEqual(l.items[0].thread.id, "pinned"); XCTAssertEqual(l.items[0].variant, .card); XCTAssertTrue(l.items[0].pinned); XCTAssertEqual(l.settledCount, 0)
    }
    // "snooze hides a pinned thread and wake restores it to the pinned block"
    func testSnoozeHidesPinnedAndWakeRestores() {
        let threads = [t("active"), t("pinned-snoozed") { $0.pinnedAt = self.d("2026-06-01T12:00:00Z"); $0.snoozedUntil = self.d("2026-06-03T09:00:00Z"); $0.snoozedAt = self.d("2026-06-01T11:00:00Z") }]
        let a = build(threads); XCTAssertEqual(a.items.map(\.thread.id), ["active"]); XCTAssertEqual(a.snoozedCount, 1)
        let b = build(threads) { $0.now = self.d("2026-06-03T10:00:00Z") }
        XCTAssertEqual(b.items.map(\.thread.id), ["pinned-snoozed", "active"]); XCTAssertTrue(b.items[0].pinned); XCTAssertEqual(b.snoozedCount, 0)
    }
    // "classifies snooze with the second-precise clock and reports the next wake"
    func testSecondPreciseClockAndNextWake() {
        let l = build([t("just-woke") { $0.snoozedUntil = self.d("2026-06-02T00:00:30Z"); $0.snoozedAt = self.d("2026-06-01T12:00:00Z") },
                       t("still-snoozed") { $0.snoozedUntil = self.d("2026-06-02T09:00:00Z"); $0.snoozedAt = self.d("2026-06-01T12:00:00Z") }]) { $0.now = self.d("2026-06-02T00:01:07.500Z") }
        XCTAssertEqual(l.items.map(\.thread.id), ["just-woke"]); XCTAssertEqual(l.snoozedCount, 1); XCTAssertEqual(l.nextSnoozeWakeAt, d("2026-06-02T09:00:00Z"))
    }
    // "builds snoozed rows between active and settled when the shelf is expanded"
    func testExpandedSnoozedShelfBetweenActiveAndSettled() {
        let l = build([t("active"), t("settled") { $0.settledOverride = .settled; $0.settledAt = self.NOW },
                       t("later") { $0.snoozedUntil = self.d("2026-06-03T09:00:00Z"); $0.snoozedAt = self.d("2026-06-01T12:00:00Z") },
                       t("sooner") { $0.snoozedUntil = self.d("2026-06-02T09:00:00Z"); $0.snoozedAt = self.d("2026-06-01T12:00:00Z") }]) { $0.snoozedShelfExpanded = true }
        XCTAssertEqual(l.items.map(\.thread.id), ["active", "sooner", "later", "settled"]); XCTAssertEqual(l.items.map(\.snoozed), [false, true, true, false])
        XCTAssertEqual(l.snoozedShelfHeaderIndex, 1); XCTAssertEqual(l.snoozedCount, 2)
    }
    // "collapses to a header-only shelf"
    func testCollapsedSnoozedShelfIsHeaderOnly() {
        let l = build([t("snoozed") { $0.snoozedUntil = self.d("2026-06-03T09:00:00Z"); $0.snoozedAt = self.d("2026-06-01T12:00:00Z") }])
        XCTAssertTrue(l.items.isEmpty); XCTAssertEqual(l.snoozedCount, 1); XCTAssertEqual(l.snoozedShelfHeaderIndex, 0)
    }
    // "keeps the selected thread on a collapsed shelf"
    func testSelectedStaysOnCollapsedSnoozedShelf() {
        let l = build([t("open") { $0.snoozedUntil = self.d("2026-06-03T09:00:00Z"); $0.snoozedAt = self.d("2026-06-01T12:00:00Z") },
                       t("other") { $0.snoozedUntil = self.d("2026-06-03T10:00:00Z"); $0.snoozedAt = self.d("2026-06-01T12:00:00Z") }]) { $0.selectedThreadKey = "environment-1:open" }
        XCTAssertEqual(l.items.map(\.thread.id), ["open"]); XCTAssertTrue(l.items[0].snoozed); XCTAssertEqual(l.snoozedCount, 2)
    }
    // "keeps snoozed threads visible on environments without the snooze capability"
    func testNoSnoozeCapabilityKeepsThreadVisible() {
        let l = build([t("snoozed") { $0.snoozedUntil = self.d("2026-06-03T09:00:00Z"); $0.snoozedAt = self.d("2026-06-01T12:00:00Z") }]) { $0.snoozeEnvironmentIds = [] }
        XCTAssertEqual(l.items.map(\.thread.id), ["snoozed"]); XCTAssertEqual(l.snoozedCount, 0)
    }
    // "partitions settled threads into a slim shelf"
    func testSettledShelfIsSlim() {
        let l = build([t("active"), t("settled") { $0.settledOverride = .settled; $0.settledAt = self.NOW }, t("settled-2") { $0.settledOverride = .settled; $0.settledAt = self.NOW }])
        XCTAssertEqual(l.items.map { [$0.thread.id, "\($0.variant)"] }, [["active", "card"], ["settled", "slim"], ["settled-2", "slim"]])
        XCTAssertEqual(l.items.map(\.isLast), [false, false, true]); XCTAssertEqual(l.settledCount, 2); XCTAssertEqual(l.settledShelfHeaderIndex, 1)
    }
    // "collapses settled threads to a counted shelf header"
    func testCollapsedSettledShelf() {
        let l = build([t("active"), t("settled") { $0.settledOverride = .settled; $0.settledAt = self.NOW }]) { $0.settledShelfExpanded = false }
        XCTAssertEqual(l.items.map(\.thread.id), ["active"]); XCTAssertEqual(l.settledCount, 1); XCTAssertEqual(l.settledShelfHeaderIndex, 1)
    }
    // "keeps the selected settled thread visible when its shelf is collapsed"
    func testSelectedSettledStaysVisibleWhenCollapsed() {
        let l = build([t("selected") { $0.settledOverride = .settled; $0.settledAt = self.NOW }, t("other") { $0.settledOverride = .settled; $0.settledAt = self.NOW }]) {
            $0.settledShelfExpanded = false; $0.selectedThreadKey = "environment-1:selected" }
        XCTAssertEqual(l.items.map(\.thread.id), ["selected"]); XCTAssertEqual(l.settledCount, 2); XCTAssertEqual(l.settledShelfHeaderIndex, 0)
    }
    // "keeps cards in creation order while settled sorts by recency"
    func testCardsInCreationOrder() {
        let l = build([t("older-created") { $0.createdAt = self.d("2026-06-01T08:00:00Z"); $0.updatedAt = self.NOW }, t("newer-created") { $0.createdAt = self.d("2026-06-01T12:00:00Z") }])
        XCTAssertEqual(l.items.map(\.thread.id), ["newer-created", "older-created"])
    }
    // "sorts settled threads by their persisted settlement timestamp"
    func testSettledSortsBySettledAt() {
        let l = build([t("settled-newer") { $0.settledOverride = .settled; $0.settledAt = self.d("2026-06-01T12:00:00Z"); $0.latestUserMessageAt = self.d("2026-06-01T08:00:00Z") },
                       t("settled-older") { $0.settledOverride = .settled; $0.settledAt = self.d("2026-06-01T10:00:00Z"); $0.latestUserMessageAt = self.d("2026-06-01T09:00:00Z") }])
        XCTAssertEqual(l.items.map(\.thread.id), ["settled-newer", "settled-older"])
    }
    // "keeps settled threads in the tail and filters by search query"
    func testSearchFiltersBothBlocks() {
        let l = build([t("match", title: "Fix login bug"), t("miss", title: "Greeting"), t("settled", title: "Fix login again") { $0.settledOverride = .settled; $0.settledAt = self.NOW }]) { $0.searchQuery = "login" }
        XCTAssertEqual(l.items.map { [$0.thread.id, "\($0.variant)"] }, [["match", "card"], ["settled", "slim"]])
    }
    // "includes a thread matched by message content"
    func testContentMatchKey() {
        let l = build([t("content-match", title: "Unrelated title")]) { $0.searchQuery = "relay reconnect"; $0.matchedThreadKeys = [T3ThreadList.searchMatchKey(environmentId: "environment-1", threadId: "content-match")] }
        XCTAssertEqual(l.items.map(\.thread.id), ["content-match"])
        XCTAssertEqual(T3ThreadList.searchMatchKey(environmentId: "environment-1", threadId: "content-match"), #"["environment-1","content-match"]"#)
    }
    // "scopes the flat list to one project" / "to every environment member of a logical project"
    func testProjectScope() {
        let a = build([t("included"), t("excluded") { $0.projectId = "project-2" }]) { $0.projectRefs = [.init(environmentId: "environment-1", projectId: "project-1")] }
        XCTAssertEqual(a.items.map(\.thread.id), ["included"])
        let b = build([t("local"), t("remote") { $0.environmentId = "environment-remote" }]) {
            $0.projectRefs = [.init(environmentId: "environment-1", projectId: "project-1"), .init(environmentId: "environment-remote", projectId: "project-1")] }
        XCTAssertEqual(b.items.map(\.thread.id), ["local", "remote"])
    }
    // "caps the settled tail at settledLimit and reports the hidden count"
    func testSettledPaging() {
        var threads = [t("active", title: "Active")]
        for i in 0..<4 {
            threads.append(t("settled-\(i)", title: "Settled \(i)") {
                $0.settledOverride = .settled; $0.settledAt = self.d("2026-06-01T0\(i):10:00Z"); $0.latestUserMessageAt = self.d("2026-06-01T0\(i):00:00Z")
                $0.latestTurn = .init(state: .completed, requestedAt: self.d("2026-06-01T0\(i):00:00Z"), startedAt: self.d("2026-06-01T0\(i):00:00Z"), completedAt: self.d("2026-06-01T0\(i):10:00Z")) })
        }
        let l = build(threads) { $0.settledLimit = 2 }
        XCTAssertEqual(l.hiddenSettledCount, 2); XCTAssertEqual(l.items.filter { $0.variant == .slim }.count, 2)
        XCTAssertEqual(l.items.map(\.thread.id), ["active", "settled-3", "settled-2"])
    }
    // "uses each saved order and excludes settled, snoozed, and archived rows"
    func testOrderedSection() {
        let rows = [t("active-later") { $0.activeOrderKey = "t" }, t("active-first") { $0.activeOrderKey = "f" }, t("active-new"),
                    t("pinned-later") { $0.pinnedAt = self.NOW; $0.pinOrderKey = "t"; $0.activeOrderKey = "f" },
                    t("pinned-first") { $0.pinnedAt = self.NOW; $0.pinOrderKey = "f"; $0.activeOrderKey = "t" },
                    t("settled") { $0.settledOverride = .settled }, t("archived") { $0.archivedAt = self.NOW },
                    t("snoozed") { $0.snoozedUntil = self.d("2026-06-03T10:00:00Z"); $0.snoozedAt = self.NOW },
                    t("pinned-snoozed") { $0.pinnedAt = self.NOW; $0.snoozedUntil = self.d("2026-06-03T10:00:00Z"); $0.snoozedAt = self.NOW }]
        XCTAssertEqual(T3ThreadList.orderedSection(rows, section: .active, now: NOW).map(\.id), ["active-new", "active-first", "active-later"])
        XCTAssertEqual(T3ThreadList.orderedSection(rows, section: .pinned, now: NOW).map(\.id), ["pinned-first", "pinned-later"])
    }
    // buildThreadListV2ListItems 1–4
    func testListItemsSplicePendingBetweenActiveAndSettled() {
        let layout = build([t("active"), t("settled") { $0.settledOverride = .settled; $0.settledAt = self.NOW }])
        let items = T3ThreadList.buildListItems(items: layout.items, pendingTasks: [.init(key: "queued-1", title: "queued-1"), .init(key: "queued-2", title: "queued-2")],
                                                settledCount: 1, settledShelfHeaderIndex: 1)
        XCTAssertEqual(items.map(\.id), ["v2-thread:environment-1:active", "v2-queued-1", "v2-queued-2", "v2-settled-shelf", "v2-thread:environment-1:settled"])
        XCTAssertEqual(items.filter { if case .pending(_, true) = $0 { return true } else { return false } }.count, 1)
    }
    func testListItemsEndWithPendingWhenNothingSettled() {
        let layout = build([t("active")])
        let items = T3ThreadList.buildListItems(items: layout.items, pendingTasks: [.init(key: "queued-1", title: "queued-1")])
        XCTAssertEqual(items.map(\.id), ["v2-thread:environment-1:active", "v2-queued-1"])
    }
    func testListItemsKeepSettledShelfWithoutPending() {
        let layout = build([t("active"), t("settled") { $0.settledOverride = .settled; $0.settledAt = self.NOW }])
        let items = T3ThreadList.buildListItems(items: layout.items, pendingTasks: [], settledCount: 1, settledShelfHeaderIndex: 1)
        XCTAssertEqual(items.map(\.id), ["v2-thread:environment-1:active", "v2-settled-shelf", "v2-thread:environment-1:settled"])
    }
    func testListItemsPlacePendingBeforeCollapsedSnoozedShelf() {
        let layout = build([t("active"), t("snoozed") { $0.snoozedUntil = self.d("2026-06-03T09:00:00Z"); $0.snoozedAt = self.d("2026-06-01T12:00:00Z") },
                            t("settled") { $0.settledOverride = .settled; $0.settledAt = self.NOW }])
        let items = T3ThreadList.buildListItems(items: layout.items, pendingTasks: [.init(key: "queued", title: "queued")], snoozedCount: 1, snoozedShelfExpanded: false,
                                                snoozedShelfHeaderIndex: 1, settledCount: 1, settledShelfHeaderIndex: 1)
        XCTAssertEqual(items.map(\.id), ["v2-thread:environment-1:active", "v2-queued", "v2-snoozed-shelf", "v2-settled-shelf", "v2-thread:environment-1:settled"])
    }
    func testListItemsCarryTheWakeLabel() {
        let layout = build([t("s") { $0.snoozedUntil = self.d("2026-06-02T02:00:00Z"); $0.snoozedAt = self.d("2026-06-01T12:00:00Z") }]) { $0.snoozedShelfExpanded = true }
        let items = T3ThreadList.buildListItems(items: layout.items, pendingTasks: [], snoozedCount: 1, snoozedShelfExpanded: true, snoozedShelfHeaderIndex: 0, snoozeLabelNow: NOW)
        guard case let .snoozedShelf(count, expanded) = items[0], case let .thread(_, label) = items[1] else { return XCTFail("\(items)") }
        XCTAssertEqual(count, 1); XCTAssertTrue(expanded); XCTAssertEqual(label, "2h")
    }
    // resolveThreadListV2SwipeActions
    func testSwipeActions() {
        XCTAssertEqual(T3ThreadList.swipeActions(variant: .card, settlementSupported: true, snoozeSupported: true, snoozable: true).primary, .settle)
        XCTAssertEqual(T3ThreadList.swipeActions(variant: .card, settlementSupported: true, snoozeSupported: true, snoozable: true).secondary, .snooze)
        XCTAssertEqual(T3ThreadList.swipeActions(variant: .slim, settlementSupported: true, snoozeSupported: true, snoozable: true).primary, .unsettle)
        XCTAssertEqual(T3ThreadList.swipeActions(variant: .slim, settlementSupported: true, snoozeSupported: true, snoozable: true).secondary, .snooze)
        XCTAssertEqual(T3ThreadList.swipeActions(variant: .slim, settlementSupported: true, snoozeSupported: true, snoozable: false).primary, .unsettle)
        XCTAssertNil(T3ThreadList.swipeActions(variant: .slim, settlementSupported: true, snoozeSupported: true, snoozable: false).secondary)
        XCTAssertNil(T3ThreadList.swipeActions(variant: .card, settlementSupported: true, snoozeSupported: false, snoozable: true).secondary)
        XCTAssertEqual(T3ThreadList.swipeActions(variant: .card, settlementSupported: false, snoozeSupported: false, snoozable: true).primary, .archive)
        XCTAssertEqual(T3ThreadList.swipeActions(variant: .slim, settlementSupported: true, snoozeSupported: true, snoozable: true, snoozed: true).primary, .unsnooze)
    }

    // MARK: - "queued messages keep a settled thread active" (upstream describe not in the brief's own case list, transcribed per dispatch instructions)

    // "lists the thread in the active block instead of the settled shelf"
    func testQueuedMessagesListTheThreadInTheActiveBlockInsteadOfTheSettledShelf() {
        let threads = [t("active", title: "Active"), t("settled", title: "Settled") { $0.settledOverride = .settled },
                       t("settled-queued", title: "Settled with outbox") { $0.settledOverride = .settled }]
        let l = build(threads) { $0.queuedThreadKeys = ["environment-1:settled-queued"] }
        XCTAssertEqual(l.items.map { [$0.thread.id, "\($0.variant)"] }, [["active", "card"], ["settled-queued", "card"], ["settled", "slim"]])
        XCTAssertEqual(l.settledCount, 1)
    }
    // "includes it in the reorderable active section"
    func testQueuedMessagesIncludesItInTheReorderableActiveSection() {
        let threads = [t("active", title: "Active"), t("settled", title: "Settled") { $0.settledOverride = .settled },
                       t("settled-queued", title: "Settled with outbox") { $0.settledOverride = .settled }]
        let queuedThreadKeys: Set<String> = ["environment-1:settled-queued"]
        XCTAssertEqual(T3ThreadList.orderedSection(threads, section: .active, now: NOW, queuedThreadKeys: queuedThreadKeys).map(\.id), ["active", "settled-queued"])
        XCTAssertEqual(T3ThreadList.orderedSection(threads, section: .active, now: NOW).map(\.id), ["active"])
    }

    // MARK: - Upstream describes covered by their owning port instead of duplicated here
    // (`resolveThreadListV2Status` → T3ThreadStatus, `resolveThreadListV2SnoozeGateExpiryMs`
    // → T3ThreadSettled.snoozeGateExpiry, `sortThreadsForListV2` → T3ThreadSort.sortActive;
    // none of these are re-exposed by T3ThreadList's own interface, so they are transcribed
    // here against the mapped function directly for full `it` coverage of threadListV2.ts.)

    // resolveThreadListV2Status: "prioritizes approval over a running session"
    func testStatusPrioritizesApprovalOverARunningSession() {
        var thread = t("t"); thread.hasPendingApprovals = true; thread.session = .init(status: .running, updatedAt: NOW)
        XCTAssertEqual(T3ThreadStatus(thread), .approval)
    }
    // resolveThreadListV2Status: "resolves ready for quiescent threads"
    func testStatusResolvesReadyForQuiescentThreads() {
        XCTAssertEqual(T3ThreadStatus(t("t")), .ready)
    }
    // resolveThreadListV2SnoozeGateExpiryMs: "reports when an unadopted turn's grace window lapses"
    func testSnoozeGateExpiryReportsWhenAnUnadoptedTurnsGraceWindowLapses() {
        var thread = t("t"); thread.latestUserMessageAt = d("2026-06-02T00:00:30Z")
        XCTAssertEqual(T3ThreadSettled.snoozeGateExpiry(thread, now: d("2026-06-02T00:01:00Z")), d("2026-06-02T00:02:30Z"))
    }
    // resolveThreadListV2SnoozeGateExpiryMs: "returns null once the thread is snoozable or when only data can unblock it"
    func testSnoozeGateExpiryReturnsNilOnceTheThreadIsSnoozableOrWhenOnlyDataCanUnblockIt() {
        XCTAssertNil(T3ThreadSettled.snoozeGateExpiry(t("ready", title: "Ready"), now: NOW))
        var blocked = t("blocked", title: "Blocked"); blocked.hasPendingApprovals = true; blocked.latestUserMessageAt = NOW
        XCTAssertNil(T3ThreadSettled.snoozeGateExpiry(blocked, now: NOW))
    }
    // sortThreadsForListV2: "honors a saved active order and leaves new threads above it"
    func testSortActiveHonorsASavedActiveOrderAndLeavesNewThreadsAboveIt() {
        let sorted = T3ThreadSort.sortActive([
            t("newer-arranged") { $0.createdAt = self.d("2026-06-01T12:00:00Z"); $0.activeOrderKey = "t" },
            t("older-arranged") { $0.createdAt = self.d("2026-06-01T08:00:00Z"); $0.activeOrderKey = "f" },
            t("new") { $0.createdAt = self.d("2026-06-01T13:00:00Z") }])
        XCTAssertEqual(sorted.map(\.id), ["new", "older-arranged", "newer-arranged"])
    }
    // sortThreadsForListV2: "orders by creation time, newest first, ignoring activity"
    func testSortActiveOrdersByCreationTimeNewestFirstIgnoringActivity() {
        let sorted = T3ThreadSort.sortActive([
            t("oldest") { $0.createdAt = self.d("2026-06-01T08:00:00Z") },
            t("newest") { $0.createdAt = self.d("2026-06-01T12:00:00Z") },
            t("middle") { $0.createdAt = self.d("2026-06-01T10:00:00Z") }])
        XCTAssertEqual(sorted.map(\.id), ["newest", "middle", "oldest"])
    }
    // sortThreadsForListV2: "surfaces an un-settled thread at the top via its re-entry stamp"
    func testSortActiveSurfacesAnUnsettledThreadAtTheTopViaItsReentryStamp() {
        let sorted = T3ThreadSort.sortActive([
            t("old-unsettled") { $0.createdAt = self.d("2026-06-01T08:00:00Z"); $0.unsettledAt = self.d("2026-06-01T13:00:00Z") },
            t("newest") { $0.createdAt = self.d("2026-06-01T12:00:00Z") },
            t("middle") { $0.createdAt = self.d("2026-06-01T10:00:00Z") }])
        XCTAssertEqual(sorted.map(\.id), ["old-unsettled", "newest", "middle"])
    }
}
