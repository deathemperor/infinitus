import XCTest
@testable import InfinitusCore

final class T3SidebarListTests: XCTestCase {
    private func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    private let NOW = ISO8601DateFormatter().date(from: "2026-06-02T00:00:00Z")!
    typealias L = T3SidebarList
    private let items: [L.ListItem] = [
        .marker(.pinnedHeader), .thread(key: "e:p1", section: .pinned), .marker(.pinnedDivider),
        .thread(key: "e:a1", section: .active), .thread(key: "e:a2", section: .active),
        .marker(.snoozedHeader), .thread(key: "e:z1", section: .snoozed),
        .marker(.settledHeader), .thread(key: "e:s1", section: .settled)]

    func testMarkerIds() {
        XCTAssertEqual(L.ListItem.marker(.pinnedDivider).id, "sidebar-marker-pinned-divider")
        XCTAssertEqual(L.ListItem.thread(key: "e:a1", section: .active).id, "e:a1")
    }
    func testDropTargetReadsTheSectionOffTheMarkers() {
        // a2 dropped onto p1's slot lands in pinned, after nothing (index 1)
        let t = L.dropTarget(items: items, activeKey: "e:a2", overId: "e:p1")!
        XCTAssertEqual(t.section, .pinned); XCTAssertEqual(t.pinnedOrder, ["e:a2", "e:p1"]); XCTAssertEqual(t.activeOrder, ["e:a1"])
        // into the settled block
        XCTAssertEqual(L.dropTarget(items: items, activeKey: "e:a1", overId: "e:s1")?.section, .settled)
        // the snoozed shelf is never a target
        XCTAssertNil(L.dropTarget(items: items, activeKey: "e:a1", overId: "e:z1"))
        XCTAssertNil(L.dropTarget(items: items, activeKey: "nope", overId: "e:a1"))
        XCTAssertNil(L.dropTarget(items: items, activeKey: "sidebar-marker-pinned-header", overId: "e:a1"))
    }
    // Additional coverage transcribed from `resolveSidebarDropTarget` in Sidebar.logic.test.ts,
    // using its own two-pinned/two-active/one-snoozed/one-settled fixture.
    func testDropTargetArrayMovePlacementAndEdgeMarkers() {
        let fixture: [L.ListItem] = [
            .marker(.pinnedHeader), .thread(key: "p1", section: .pinned), .thread(key: "p2", section: .pinned), .marker(.pinnedDivider),
            .thread(key: "a1", section: .active), .thread(key: "a2", section: .active),
            .marker(.snoozedHeader), .thread(key: "z1", section: .snoozed),
            .marker(.settledHeader), .thread(key: "s1", section: .settled)]
        func resolve(_ active: String, _ over: String) -> L.DropTarget? { L.dropTarget(items: fixture, activeKey: active, overId: over) }

        // "a marker hovered from below lands above it": dragging a1 onto the divider — divider
        // shifts down, a1 becomes the last pinned row.
        XCTAssertEqual(resolve("a1", L.ListItem.marker(.pinnedDivider).id),
                        .init(section: .pinned, pinnedOrder: ["p1", "p2", "a1"], activeOrder: ["a2"]))
        // dragging p2 down onto the divider — divider shifts up, p2 is the first Active row (unpin).
        XCTAssertEqual(resolve("p2", L.ListItem.marker(.pinnedDivider).id),
                        .init(section: .active, pinnedOrder: ["p1"], activeOrder: ["p2", "a1", "a2"]))
        // the settled header from above settles; from below the gap lands in the snoozed shelf,
        // which is never a target.
        XCTAssertEqual(resolve("a2", L.ListItem.marker(.settledHeader).id)?.section, .settled)
        XCTAssertNil(resolve("s1", L.ListItem.marker(.settledHeader).id))

        // reorders inside the pinned block with the dragged row at the over slot
        XCTAssertEqual(resolve("p1", "p2"), .init(section: .pinned, pinnedOrder: ["p2", "p1"], activeOrder: ["a1", "a2"]))
        XCTAssertEqual(resolve("a2", "p1"), .init(section: .pinned, pinnedOrder: ["a2", "p1", "p2"], activeOrder: ["a1"]))

        // lands first in Pinned when hovering its permanent header
        XCTAssertEqual(resolve("a2", L.ListItem.marker(.pinnedHeader).id), .init(section: .pinned, pinnedOrder: ["a2", "p1", "p2"], activeOrder: ["a1"]))

        // reorders active rows in either direction without changing sections
        XCTAssertEqual(resolve("a1", "a2"), .init(section: .active, pinnedOrder: ["p1", "p2"], activeOrder: ["a2", "a1"]))
        XCTAssertEqual(resolve("a2", "a1"), .init(section: .active, pinnedOrder: ["p1", "p2"], activeOrder: ["a2", "a1"]))

        // "reads the section off the markers above the gap" — the two sub-cases the earlier
        // one-pinned-row floor fixture couldn't express (it only has p1, not p1+p2).
        XCTAssertEqual(resolve("s1", "a1"), .init(section: .active, pinnedOrder: ["p1", "p2"], activeOrder: ["s1", "a1", "a2"]))
        XCTAssertEqual(resolve("p1", "a2"), .init(section: .active, pinnedOrder: ["p2"], activeOrder: ["a1", "a2", "p1"]))

        // rejects ids not in the list
        XCTAssertNil(resolve("a1", "nope")); XCTAssertNil(resolve("nope", "a1"))
        XCTAssertNil(resolve(L.ListItem.marker(.pinnedDivider).id, "a1"))
    }
    // "keeps marker-like scoped thread keys draggable" — a thread key that shares the marker id
    // *prefix* (but not a real marker's id) is still resolved as a thread, not misread as a
    // marker: `ListItem` discriminates by case, not by sniffing the id string.
    func testDropTargetKeepsMarkerLikeScopedThreadKeysDraggable() {
        let key = "sidebar-marker-scoped-thread"
        let list: [L.ListItem] = [.marker(.pinnedHeader), .thread(key: key, section: .pinned), .thread(key: "env:other", section: .pinned), .marker(.pinnedDivider)]
        XCTAssertEqual(Set(list.map(\.id)).count, list.count)
        XCTAssertEqual(L.dropTarget(items: list, activeKey: key, overId: "env:other"), .init(section: .pinned, pinnedOrder: ["env:other", key], activeOrder: []))
    }
    func testDropTargetLandsOnAnEmptySectionsPlaceholderOrHeader() {
        let withPlaceholder: [L.ListItem] = [
            .marker(.pinnedHeader), .marker(.pinnedDivider), .thread(key: "a1", section: .active),
            .marker(.settledHeader), .marker(.settledPlaceholder)]
        XCTAssertEqual(L.dropTarget(items: withPlaceholder, activeKey: "a1", overId: L.ListItem.marker(.settledPlaceholder).id),
                        .init(section: .settled, pinnedOrder: [], activeOrder: []))
        let emptyPinned: [L.ListItem] = [.marker(.pinnedHeader), .marker(.pinnedDivider), .thread(key: "a1", section: .active)]
        XCTAssertEqual(L.dropTarget(items: emptyPinned, activeKey: "a1", overId: L.ListItem.marker(.pinnedHeader).id),
                        .init(section: .pinned, pinnedOrder: ["a1"], activeOrder: []))
        XCTAssertEqual(L.dropTarget(items: emptyPinned, activeKey: "a1", overId: L.ListItem.marker(.pinnedDivider).id),
                        .init(section: .pinned, pinnedOrder: ["a1"], activeOrder: []))
    }
    func testDropVerb() {
        XCTAssertNil(L.dropVerb(from: .active, to: nil)); XCTAssertNil(L.dropVerb(from: .active, to: .active)); XCTAssertNil(L.dropVerb(from: .active, to: .snoozed))
        XCTAssertEqual(L.dropVerb(from: .active, to: .pinned), .pin); XCTAssertEqual(L.dropVerb(from: .active, to: .settled), .settle)
        XCTAssertEqual(L.dropVerb(from: .pinned, to: .active), .unpin); XCTAssertEqual(L.dropVerb(from: .settled, to: .active), .unsettle)
        XCTAssertEqual(L.dropVerb(from: .snoozed, to: .active), .wake)
    }
    func testPlanDropPinReorderAndNone() {
        let keys: [String: String?] = ["e:p1": "bb", "e:p2": "dd", "e:p3": "ff"]
        func input(_ active: String, _ section: L.Section, _ target: L.DropTarget) -> L.DropInput {
            L.DropInput(activeKey: active, activeSection: section, target: target, pinnedOrder: ["e:p1", "e:p2", "e:p3"], pinnedKeysById: keys,
                        activeOrder: ["e:a1", "e:a2"], activeKeysById: ["e:a1": nil, "e:a2": nil])
        }
        // "allows old-server pinned reordering while rejecting settlement" — the positive half:
        // a pinned reorder still succeeds even when `supportsSettlement` is false.
        var oldServerReorder = input("e:p1", .pinned, .init(section: .pinned, pinnedOrder: ["e:p2", "e:p1", "e:p3"], activeOrder: []))
        oldServerReorder.supportsSettlement = false
        guard case .reorderPinned = L.planDrop(oldServerReorder) else { return XCTFail("expected reorderPinned") }
        // same order → none
        XCTAssertEqual(L.planDrop(input("e:p1", .pinned, .init(section: .pinned, pinnedOrder: ["e:p1", "e:p2", "e:p3"], activeOrder: ["e:a1", "e:a2"]))), .none)
        // p1 moved between p2 and p3 → one key write "e"
        XCTAssertEqual(L.planDrop(input("e:p1", .pinned, .init(section: .pinned, pinnedOrder: ["e:p2", "e:p1", "e:p3"], activeOrder: ["e:a1", "e:a2"]))),
                       .reorderPinned(order: ["e:p2", "e:p1", "e:p3"], assignments: [.init(id: "e:p1", orderKey: "e")]))
        // an active row dropped into pinned → pin with its key, no extras
        XCTAssertEqual(L.planDrop(input("e:a1", .active, .init(section: .pinned, pinnedOrder: ["e:p1", "e:p2", "e:a1", "e:p3"], activeOrder: ["e:a2"]))),
                       .pin(order: ["e:p1", "e:p2", "e:a1", "e:p3"], orderKey: "e", extraAssignments: []))
        // "pins a foreign thread with a key between its new neighbors" — the empty-pool half:
        // pinning the only thread into an otherwise-empty pinned section still yields a key.
        let emptyPool = L.DropInput(activeKey: "e:a1", activeSection: .active, target: .init(section: .pinned, pinnedOrder: ["e:a1"], activeOrder: []),
                                     pinnedOrder: [], pinnedKeysById: [:], activeOrder: ["e:a2"], activeKeysById: ["e:a2": nil])
        guard case let .pin(_, emptyOrderKey, _) = L.planDrop(emptyPool), emptyOrderKey != nil else { return XCTFail("expected a defined orderKey") }
        // pinned row dropped into active → move-active with unpin; keyless neighbours materialise the section
        guard case let .moveActive(order, assignments, unpin, unsettle, unsnooze) =
                L.planDrop(input("e:p1", .pinned, .init(section: .active, pinnedOrder: ["e:p2", "e:p3"], activeOrder: ["e:a1", "e:p1", "e:a2"]))) else { return XCTFail() }
        XCTAssertEqual(order, ["e:a1", "e:p1", "e:a2"]); XCTAssertEqual(assignments.map(\.orderKey), ["gn", "nb", "tn"]); XCTAssertTrue(unpin); XCTAssertFalse(unsettle); XCTAssertFalse(unsnooze)
        // settle
        XCTAssertEqual(L.planDrop(input("e:a1", .active, .init(section: .settled, pinnedOrder: [], activeOrder: []))), .settle)
        XCTAssertEqual(L.planDrop(input("e:s1", .settled, .init(section: .settled, pinnedOrder: [], activeOrder: []))), .none)
        var unsupported = input("e:a1", .active, .init(section: .settled, pinnedOrder: [], activeOrder: [])); unsupported.supportsSettlement = false
        XCTAssertEqual(L.planDrop(unsupported), .none)
        // reorderable gate refuses a plan touching a foreign row
        var gated = input("e:p1", .pinned, .init(section: .active, pinnedOrder: ["e:p2", "e:p3"], activeOrder: ["e:a1", "e:p1", "e:a2"])); gated.activeReorderableKeys = ["e:p1"]
        XCTAssertEqual(L.planDrop(gated), .none)
        // "settles anything dropped on Settled except a settled thread" — the remaining sources.
        XCTAssertEqual(L.planDrop(input("e:p1", .pinned, .init(section: .settled, pinnedOrder: [], activeOrder: []))), .settle)
        XCTAssertEqual(L.planDrop(input("e:z1", .snoozed, .init(section: .settled, pinnedOrder: [], activeOrder: []))), .settle)
    }
    // `it.each` "moves a $section thread to the chosen Active slot" — pinned/settled/snoozed sources.
    func testPlanDropMovesAHiddenSectionThreadToTheChosenActiveSlot() {
        let pinnedKeys: [String: String?] = ["p1": "f", "p2": "m", "p3": "t"]
        let activeKeys: [String: String?] = ["a1": "f", "a2": "m", "a3": "t"]
        for (key, section, unpin, unsettle, unsnooze) in [
            ("p2", L.Section.pinned, true, false, false),
            ("s1", L.Section.settled, false, true, false),
            ("z1", L.Section.snoozed, false, false, true),
        ] {
            let order = ["a1", key, "a2", "a3"]
            let plan = L.planDrop(.init(activeKey: key, activeSection: section, target: .init(section: .active, pinnedOrder: [], activeOrder: order),
                                          pinnedOrder: ["p1", "p2", "p3"], pinnedKeysById: pinnedKeys, activeOrder: ["a1", "a2", "a3"], activeKeysById: activeKeys))
            guard case let .moveActive(o, a, u1, u2, u3) = plan else { return XCTFail("expected moveActive for \(key)") }
            XCTAssertEqual(o, order); XCTAssertEqual(a.map(\.id), [key])
            XCTAssertTrue(a[0].orderKey > "f" && a[0].orderKey < "m")
            XCTAssertEqual(u1, unpin); XCTAssertEqual(u2, unsettle); XCTAssertEqual(u3, unsnooze)
        }
    }
    // `it.each` "clears a snoozed thread's $state state before waking it into Active".
    func testPlanDropClearsASnoozedThreadsHiddenStateBeforeWakingIt() {
        for (activePinned, activeSettled) in [(true, false), (false, true), (true, true)] {
            var input = L.DropInput(activeKey: "z1", activeSection: .snoozed,
                                     target: .init(section: .active, pinnedOrder: ["p1", "p2", "p3"], activeOrder: ["a1", "z1", "a2", "a3"]),
                                     pinnedOrder: ["p1", "p2", "p3"], pinnedKeysById: ["p1": "f", "p2": "m", "p3": "t"],
                                     activeOrder: ["a1", "a2", "a3"], activeKeysById: ["a1": "f", "a2": "m", "a3": "t"])
            input.activePinned = activePinned; input.activeSettled = activeSettled
            let plan = L.planDrop(input)
            guard case let .moveActive(order, assignments, unpin, unsettle, unsnooze) = plan else { return XCTFail() }
            XCTAssertEqual(order, ["a1", "z1", "a2", "a3"]); XCTAssertEqual(assignments.map(\.id), ["z1"])
            XCTAssertEqual(unpin, activePinned); XCTAssertEqual(unsettle, activeSettled); XCTAssertTrue(unsnooze)
        }
    }
    // `it.each` "reserves hidden %s slots during a drop" — pinned and active.
    func testPlanDropReservesHiddenSlotsDuringADrop() {
        let pinnedKeys: [String: String?] = ["p1": "f", "p2": "m", "p3": "t"]
        let activeKeys: [String: String?] = ["a1": "f", "a2": "m", "a3": "t"]
        for section in [L.Section.pinned, .active] {
            let order = section == .pinned ? ["p2", "p1", "p3"] : ["a2", "a1", "a3"]
            let moved = section == .pinned ? "p1" : "a1"
            var keys = section == .pinned ? pinnedKeys : activeKeys
            let reserved = T3ThreadSort.pinOrderKeyBetween(keys[order[0]]!, keys[order[2]]!)!
            keys["snoozed"] = reserved
            let input = L.DropInput(activeKey: moved, activeSection: section,
                                     target: .init(section: section == .pinned ? .pinned : .active,
                                                    pinnedOrder: section == .pinned ? order : [], activeOrder: section == .active ? order : []),
                                     pinnedOrder: section == .pinned ? ["p1", "p2", "p3"] : [], pinnedKeysById: section == .pinned ? keys : pinnedKeys,
                                     activeOrder: section == .active ? ["a1", "a2", "a3"] : [], activeKeysById: section == .active ? keys : activeKeys)
            let plan = L.planDrop(input)
            let assignments: [T3ThreadSort.Assignment]
            switch plan {
            case let .reorderPinned(_, a): assignments = a
            case let .moveActive(_, a, _, _, _): assignments = a
            default: return XCTFail("expected a reorder for \(section)")
            }
            XCTAssertEqual(assignments.count, 1)
            XCTAssertNotEqual(assignments[0].orderKey, reserved)
        }
    }
    // "reorders an already-pinned snoozed thread after pinning wakes it"
    func testPlanDropReordersAnAlreadyPinnedSnoozedThreadAfterPinningWakesIt() {
        let pinnedKeys: [String: String?] = ["p1": "f", "p2": "m", "p3": "t", "z1": "x"]
        var input = L.DropInput(activeKey: "z1", activeSection: .snoozed,
                                 target: .init(section: .pinned, pinnedOrder: ["p1", "z1", "p2", "p3"], activeOrder: []),
                                 pinnedOrder: ["p1", "p2", "p3"], pinnedKeysById: pinnedKeys, activeOrder: [], activeKeysById: [:])
        input.activePinned = true
        let plan = L.planDrop(input)
        guard case let .pin(_, orderKey, extra) = plan, let key = orderKey else { return XCTFail() }
        XCTAssertEqual(extra, [.init(id: "z1", orderKey: key)])
        XCTAssertTrue(key > "f" && key < "m")
    }
    // "requires Active ordering support only for the threads whose keys must change"
    func testPlanDropRequiresActiveReorderableOnlyForChangedKeys() {
        let base = L.DropInput(activeKey: "a3", activeSection: .active, target: .init(section: .active, pinnedOrder: [], activeOrder: ["a1", "a3", "a2"]),
                                pinnedOrder: [], pinnedKeysById: [:], activeOrder: ["a1", "a2", "a3"], activeKeysById: ["a1": "f", "a2": "m", "a3": "t"])
        var gatedOk = base; gatedOk.activeReorderableKeys = ["a3"]
        guard case .moveActive = L.planDrop(gatedOk) else { return XCTFail() }
        var gatedNeedsMore = base; gatedNeedsMore.activeKeysById = ["a1": nil, "a2": "m", "a3": "t"]; gatedNeedsMore.activeReorderableKeys = ["a3"]
        XCTAssertEqual(L.planDrop(gatedNeedsMore), .none)
        var gatedEmpty = base; gatedEmpty.activeReorderableKeys = []
        XCTAssertEqual(L.planDrop(gatedEmpty), .none)
    }
    // "rejects $activeSection drops that require rewriting a disabled neighbor" — active/pinned sources.
    func testPlanDropRejectsDropsThatRequireRewritingADisabledNeighbor() {
        let pinnedKeys: [String: String?] = ["p1": "f", "p2": nil, "p3": "t"]
        for (activeKey, section, order) in [
            ("a1", L.Section.active, ["p1", "p3", "a1", "p2"]),
            ("p1", L.Section.pinned, ["p3", "p1", "p2"]),
        ] {
            var input = L.DropInput(activeKey: activeKey, activeSection: section, target: .init(section: .pinned, pinnedOrder: order, activeOrder: []),
                                     pinnedOrder: ["p1", "p3", "p2"], pinnedKeysById: pinnedKeys, activeOrder: [], activeKeysById: [:])
            input.reorderableKeys = ["p1", "p3", activeKey]
            XCTAssertEqual(L.planDrop(input), .none, "expected none for \(activeKey)")
        }
    }
    // "uses keyed disabled neighbors as anchors without writing to them" — both sub-cases succeed
    // (contrast with the rejects-test above, where the anchor itself needed a write).
    func testPlanDropUsesKeyedDisabledNeighborsAsAnchorsWithoutWritingToThem() {
        let pinnedKeys: [String: String?] = ["p1": "f", "p2": "m", "p3": "t"]
        var insertion = L.DropInput(activeKey: "a1", activeSection: .active, target: .init(section: .pinned, pinnedOrder: ["p1", "a1", "p2", "p3"], activeOrder: []),
                                     pinnedOrder: ["p1", "p2", "p3"], pinnedKeysById: pinnedKeys, activeOrder: ["a1"], activeKeysById: [:])
        insertion.reorderableKeys = ["a1"]
        guard case let .pin(order, orderKey, extra) = L.planDrop(insertion), let key = orderKey else { return XCTFail("expected pin") }
        XCTAssertEqual(order, ["p1", "a1", "p2", "p3"]); XCTAssertTrue(key > "f" && key < "m"); XCTAssertEqual(extra, [])

        var reorder = L.DropInput(activeKey: "p3", activeSection: .pinned, target: .init(section: .pinned, pinnedOrder: ["p1", "p3", "p2"], activeOrder: []),
                                   pinnedOrder: ["p1", "p2", "p3"], pinnedKeysById: pinnedKeys, activeOrder: [], activeKeysById: [:])
        reorder.reorderableKeys = ["p3"]
        guard case let .reorderPinned(_, assignments) = L.planDrop(reorder) else { return XCTFail("expected reorderPinned") }
        XCTAssertEqual(assignments.map(\.id), ["p3"])
        XCTAssertTrue(assignments[0].orderKey > "f" && assignments[0].orderKey < "m")
    }
    // "rewrites the section when a foreign thread lands next to a keyless pin"
    func testPlanDropRewritesTheSectionWhenAForeignThreadLandsNextToAKeylessPin() {
        let pinnedKeys: [String: String?] = ["p1": nil, "p2": "m", "p3": "t"]
        let input = L.DropInput(activeKey: "a1", activeSection: .active, target: .init(section: .pinned, pinnedOrder: ["p1", "a1", "p2", "p3"], activeOrder: []),
                                 pinnedOrder: ["p1", "p2", "p3"], pinnedKeysById: pinnedKeys, activeOrder: ["a1"], activeKeysById: [:])
        guard case let .pin(order, orderKey, extra) = L.planDrop(input), let key = orderKey else { return XCTFail("expected pin") }
        XCTAssertEqual(extra.map(\.id), ["p1", "p2", "p3"])
        var byId: [String: String] = ["a1": key]
        for e in extra { byId[e.id] = e.orderKey }
        let ordered = order.map { byId[$0]! }
        XCTAssertEqual(ordered, ordered.sorted())
    }
    // "saves the first Active reorder, then moves only one key on subsequent drops" — a two-step
    // round trip through `T3ThreadSort.sortActive`.
    func testPlanDropSavesTheFirstActiveReorderThenMovesOnlyOneKeyOnSubsequentDrops() {
        var rows = ["a1", "a2", "a3"].map { T3Thread(id: $0, title: "T", createdAt: NOW, updatedAt: NOW) }
        let firstOrder = ["a2", "a3", "a1"]
        let firstInput = L.DropInput(activeKey: "a1", activeSection: .active, target: .init(section: .active, pinnedOrder: [], activeOrder: firstOrder),
                                      pinnedOrder: [], pinnedKeysById: [:], activeOrder: ["a1", "a2", "a3"], activeKeysById: ["a1": nil, "a2": nil, "a3": nil])
        guard case let .moveActive(_, firstAssignments, unpin, unsettle, unsnooze) = L.planDrop(firstInput) else { return XCTFail("expected moveActive") }
        XCTAssertFalse(unpin || unsettle || unsnooze)
        var savedKeys: [String: String?] = ["a1": nil, "a2": nil, "a3": nil]
        for a in firstAssignments { savedKeys[a.id] = a.orderKey }
        for i in rows.indices { rows[i].activeOrderKey = savedKeys[rows[i].id] ?? nil }
        XCTAssertEqual(T3ThreadSort.sortActive(rows).map(\.id), firstOrder)

        let secondOrder = ["a2", "a1", "a3"]
        let secondInput = L.DropInput(activeKey: "a1", activeSection: .active, target: .init(section: .active, pinnedOrder: [], activeOrder: secondOrder),
                                       pinnedOrder: [], pinnedKeysById: [:], activeOrder: firstOrder, activeKeysById: savedKeys)
        guard case let .moveActive(_, secondAssignments, _, _, _) = L.planDrop(secondInput) else { return XCTFail("expected moveActive") }
        XCTAssertEqual(secondAssignments.map(\.id), ["a1"])   // only the moved row's key changes
        for a in secondAssignments { savedKeys[a.id] = a.orderKey }
        for i in rows.indices { rows[i].activeOrderKey = savedKeys[rows[i].id] ?? nil }
        XCTAssertEqual(T3ThreadSort.sortActive(rows).map(\.id), secondOrder)
    }
    func testApplyDrop() {
        var t = T3Thread(id: "t", title: "T", createdAt: d("2026-06-01T00:00:00Z"), updatedAt: d("2026-06-01T00:00:00Z"))
        t.snoozedAt = NOW; t.snoozedUntil = NOW.addingTimeInterval(3600); t.pinnedAt = d("2026-06-01T01:00:00Z"); t.pinOrderKey = "m"
        let settled = L.applyDrop(t, section: .settled, now: NOW)
        XCTAssertEqual(settled.settledOverride, .settled); XCTAssertEqual(settled.settledAt, NOW); XCTAssertNil(settled.pinnedAt); XCTAssertNil(settled.pinOrderKey)
        XCTAssertNil(settled.snoozedAt); XCTAssertNil(settled.snoozedUntil); XCTAssertNil(settled.unsettledAt)
        let back = L.applyDrop(settled, section: .active, now: NOW.addingTimeInterval(60), orderKey: "q")
        XCTAssertEqual(back.settledOverride, .active); XCTAssertNil(back.settledAt); XCTAssertEqual(back.unsettledAt, NOW.addingTimeInterval(60)); XCTAssertEqual(back.activeOrderKey, "q")
        let pinned = L.applyDrop(t, section: .pinned, now: NOW)
        XCTAssertEqual(pinned.pinnedAt, d("2026-06-01T01:00:00Z")); XCTAssertEqual(pinned.pinOrderKey, "m")      // kept when no key given
        XCTAssertEqual(L.applyDrop(t, section: .pinned, now: NOW, orderKey: "z").pinOrderKey, "z")
        // active without a key leaves activeOrderKey untouched
        t.activeOrderKey = "k"; XCTAssertEqual(L.applyDrop(t, section: .active, now: NOW).activeOrderKey, "k")
    }
    // `it.each` "preserves the active sort anchor when clearing a $state" — pin/snooze/snoozed-pin.
    func testApplyDropPreservesTheActiveSortAnchorWhenClearingAParkedState() {
        let created = d("2026-03-09T08:00:00Z")
        for (pinnedAt, pinOrderKey, snoozedAt, snoozedUntil) in [
            (created, "m" as String?, nil as Date?, nil as Date?),
            (nil as Date?, nil as String?, created, d("2026-03-10T08:00:00Z") as Date?),
            (created, "m" as String?, created, d("2026-03-10T08:00:00Z") as Date?),
        ] {
            var t = T3Thread(id: "dragged", title: "T", createdAt: created, updatedAt: d("2026-03-09T09:00:00Z"))
            t.pinnedAt = pinnedAt; t.pinOrderKey = pinOrderKey; t.snoozedAt = snoozedAt; t.snoozedUntil = snoozedUntil
            t.settledOverride = .active; t.unsettledAt = d("2026-03-09T09:00:00Z")
            let preview = L.applyDrop(t, section: .active, now: NOW)
            XCTAssertNil(preview.pinnedAt); XCTAssertNil(preview.pinOrderKey); XCTAssertNil(preview.snoozedAt); XCTAssertNil(preview.snoozedUntil)
        }
    }
    // "previews an un-settle at the same active position as the eventual server row"
    func testApplyDropPreviewsAnUnsettleAtTheSameActivePositionAsTheEventualServerRow() {
        let earlier = d("2026-03-09T09:00:00Z")
        var t = T3Thread(id: "dragged", title: "T", createdAt: d("2026-03-09T08:00:00Z"), updatedAt: d("2026-03-09T08:00:00Z"))
        t.settledOverride = .settled; t.settledAt = earlier
        let preview = L.applyDrop(t, section: .active, now: NOW)
        XCTAssertEqual(preview.settledOverride, .active); XCTAssertNil(preview.settledAt); XCTAssertEqual(preview.unsettledAt, NOW)
        let newer = T3Thread(id: "newer", title: "T", createdAt: NOW.addingTimeInterval(-3600), updatedAt: NOW.addingTimeInterval(-3600))
        XCTAssertEqual(T3ThreadSort.sortActive([newer, preview]).map(\.id), ["dragged", "newer"])
    }
    // "clears underlying pinning and settlement when waking into Active"
    func testApplyDropClearsUnderlyingPinningAndSettlementWhenWakingIntoActive() {
        let earlier = d("2026-03-09T09:00:00Z"), wakeAt = d("2026-03-10T08:00:00Z")
        var t = T3Thread(id: "dragged", title: "T", createdAt: d("2026-03-09T08:00:00Z"), updatedAt: d("2026-03-09T08:00:00Z"))
        t.pinnedAt = earlier; t.pinOrderKey = "m"; t.snoozedAt = earlier; t.snoozedUntil = wakeAt
        t.settledOverride = .settled; t.settledAt = earlier
        let preview = L.applyDrop(t, section: .active, now: NOW)
        XCTAssertNil(preview.pinnedAt); XCTAssertNil(preview.pinOrderKey); XCTAssertNil(preview.snoozedAt); XCTAssertNil(preview.snoozedUntil)
        XCTAssertEqual(preview.settledOverride, .active); XCTAssertNil(preview.settledAt); XCTAssertEqual(preview.unsettledAt, NOW)
    }
    // "retains a snoozed thread's earlier settlement and its position when settling again"
    func testApplyDropRetainsASnoozedThreadsEarlierSettlementWhenSettlingAgain() {
        let earlier = d("2026-03-09T09:00:00Z"), wakeAt = d("2026-03-10T08:00:00Z"), newerCreated = d("2026-03-09T11:00:00Z")
        var t = T3Thread(id: "dragged", title: "T", createdAt: d("2026-03-09T08:00:00Z"), updatedAt: d("2026-03-09T08:00:00Z"))
        t.snoozedAt = earlier; t.snoozedUntil = wakeAt; t.settledOverride = .settled; t.settledAt = earlier
        let preview = L.applyDrop(t, section: .settled, now: NOW)
        XCTAssertNil(preview.snoozedAt); XCTAssertNil(preview.snoozedUntil)
        XCTAssertEqual(preview.settledOverride, .settled); XCTAssertEqual(preview.settledAt, earlier)  // kept, not bumped to `now`
        // order check: a row already settled later ("newer", 11:00) stays ahead of one whose
        // settlement wasn't bumped (retained at 09:00). No ported "sortSettled" exists yet on this
        // branch (Task 11/12 territory) — `T3ThreadSort.settledTimestamp` is the timestamp such a
        // sort (most-recently-settled first) would key on.
        var existing = T3Thread(id: "newer", title: "T", createdAt: newerCreated, updatedAt: newerCreated)
        existing.settledOverride = .settled; existing.settledAt = newerCreated
        XCTAssertGreaterThan(T3ThreadSort.settledTimestamp(existing)!, T3ThreadSort.settledTimestamp(preview)!)
    }
    // "previews a new settlement at the same position as the eventual server row"
    func testApplyDropPreviewsANewSettlementAtTheSamePositionAsTheEventualServerRow() {
        let earlier = d("2026-03-09T09:00:00Z"), wakeAt = d("2026-03-10T08:00:00Z"), newerCreated = d("2026-03-09T11:00:00Z")
        var t = T3Thread(id: "dragged", title: "T", createdAt: d("2026-03-09T08:00:00Z"), updatedAt: d("2026-03-09T08:00:00Z"))
        t.pinnedAt = earlier; t.pinOrderKey = "m"; t.snoozedAt = earlier; t.snoozedUntil = wakeAt; t.unsettledAt = earlier
        let preview = L.applyDrop(t, section: .settled, now: NOW)
        XCTAssertEqual(preview.settledOverride, .settled); XCTAssertEqual(preview.settledAt, NOW); XCTAssertNil(preview.unsettledAt)
        XCTAssertNil(preview.pinnedAt); XCTAssertNil(preview.pinOrderKey)
        var existing = T3Thread(id: "newer", title: "T", createdAt: newerCreated, updatedAt: newerCreated)
        existing.settledOverride = .settled; existing.settledAt = newerCreated
        // dragged settles right now (June); the existing row settled back in March — dragged
        // leads a most-recently-settled-first list.
        XCTAssertGreaterThan(T3ThreadSort.settledTimestamp(preview)!, T3ThreadSort.settledTimestamp(existing)!)
    }
    // "pins a settled thread at its requested slot and projects the re-entry stamp"
    func testApplyDropPinsASettledThreadAndProjectsTheReEntryStamp() {
        let earlier = d("2026-03-09T09:00:00Z"), wakeAt = d("2026-03-10T08:00:00Z")
        var t = T3Thread(id: "dragged", title: "T", createdAt: d("2026-03-09T08:00:00Z"), updatedAt: d("2026-03-09T08:00:00Z"))
        t.snoozedAt = earlier; t.snoozedUntil = wakeAt; t.settledOverride = .settled; t.settledAt = earlier
        let preview = L.applyDrop(t, section: .pinned, now: NOW, orderKey: "m")
        XCTAssertEqual(preview.pinnedAt, NOW); XCTAssertEqual(preview.pinOrderKey, "m")
        XCTAssertNil(preview.snoozedAt); XCTAssertNil(preview.snoozedUntil)
        XCTAssertEqual(preview.settledOverride, .active); XCTAssertNil(preview.settledAt); XCTAssertEqual(preview.unsettledAt, NOW)
    }
    // "keeps an existing pin's timestamp and key unless the drop supplies a new key"
    func testApplyDropKeepsAnExistingPinsTimestampAndKeyUnlessTheDropSuppliesANewKey() {
        let earlier = d("2026-03-09T09:00:00Z"), wakeAt = d("2026-03-10T08:00:00Z")
        var t = T3Thread(id: "dragged", title: "T", createdAt: d("2026-03-09T08:00:00Z"), updatedAt: d("2026-03-09T08:00:00Z"))
        t.pinnedAt = earlier; t.pinOrderKey = "t"; t.snoozedAt = earlier; t.snoozedUntil = wakeAt
        t.settledOverride = .active; t.unsettledAt = earlier
        let unchangedSlot = L.applyDrop(t, section: .pinned, now: NOW)
        XCTAssertEqual(unchangedSlot.pinnedAt, earlier); XCTAssertEqual(unchangedSlot.pinOrderKey, "t"); XCTAssertNil(unchangedSlot.snoozedAt); XCTAssertNil(unchangedSlot.snoozedUntil)
        XCTAssertEqual(L.applyDrop(t, section: .pinned, now: NOW, orderKey: "m").pinOrderKey, "m")
    }
    // "keeps an Active drop at its chosen position after unpinning" / "clears the manual Active
    // position when settling so reopening returns to the top" — both round-trip through
    // `T3ThreadSort.sortActive`.
    func testApplyDropKeepsAnActiveDropAtItsChosenPositionAfterUnpinning() {
        var t = T3Thread(id: "dragged", title: "T", createdAt: d("2026-03-09T08:00:00Z"), updatedAt: d("2026-03-09T08:00:00Z"))
        t.pinnedAt = d("2026-03-09T09:00:00Z"); t.pinOrderKey = "g"; t.activeOrderKey = "z"
        let preview = L.applyDrop(t, section: .active, now: NOW, orderKey: "m")
        XCTAssertNil(preview.pinnedAt); XCTAssertNil(preview.pinOrderKey); XCTAssertEqual(preview.activeOrderKey, "m")
        var before = T3Thread(id: "before", title: "T", createdAt: d("2026-03-09T08:00:00Z"), updatedAt: d("2026-03-09T08:00:00Z")); before.activeOrderKey = "f"
        var after = T3Thread(id: "after", title: "T", createdAt: d("2026-03-09T08:00:00Z"), updatedAt: d("2026-03-09T08:00:00Z")); after.activeOrderKey = "t"
        XCTAssertEqual(T3ThreadSort.sortActive([after, preview, before]).map(\.id), ["before", "dragged", "after"])
    }
    func testApplyDropClearsTheManualActivePositionWhenSettlingSoReopeningReturnsToTheTop() {
        var t = T3Thread(id: "dragged", title: "T", createdAt: d("2026-03-09T08:00:00Z"), updatedAt: d("2026-03-09T08:00:00Z")); t.activeOrderKey = "z"
        let settled = L.applyDrop(t, section: .settled, now: NOW)
        XCTAssertNil(settled.activeOrderKey)
        let reopened = L.applyDrop(settled, section: .active, now: NOW.addingTimeInterval(1))
        let newer = T3Thread(id: "newer", title: "T", createdAt: NOW.addingTimeInterval(-3600), updatedAt: NOW.addingTimeInterval(-3600))
        XCTAssertEqual(T3ThreadSort.sortActive([newer, reopened]).map(\.id), ["dragged", "newer"])
    }
    func testHasUnseenCompletion() {
        var t = T3Thread(id: "t", title: "T", createdAt: d("2026-06-01T00:00:00Z"), updatedAt: d("2026-06-01T00:00:00Z"))
        XCTAssertFalse(L.hasUnseenCompletion(t))
        t.latestTurn = .init(state: .completed, requestedAt: d("2026-06-01T10:00:00Z"), startedAt: nil, completedAt: d("2026-06-01T10:05:00Z"))
        XCTAssertFalse(L.hasUnseenCompletion(t))          // never visited: nothing to compare
        t.lastVisitedAt = d("2026-06-01T10:00:00Z"); XCTAssertTrue(L.hasUnseenCompletion(t))
        t.lastVisitedAt = d("2026-06-01T10:06:00Z"); XCTAssertFalse(L.hasUnseenCompletion(t))
    }
    func testAdjacentThreadId() {
        XCTAssertNil(L.adjacentThreadId([String](), current: nil, direction: .next))
        XCTAssertEqual(L.adjacentThreadId(["a", "b", "c"], current: nil, direction: .next), "a")
        XCTAssertEqual(L.adjacentThreadId(["a", "b", "c"], current: nil, direction: .previous), "c")
        XCTAssertEqual(L.adjacentThreadId(["a", "b", "c"], current: "b", direction: .next), "c")
        XCTAssertNil(L.adjacentThreadId(["a", "b", "c"], current: "c", direction: .next))
        XCTAssertNil(L.adjacentThreadId(["a", "b", "c"], current: "a", direction: .previous))
        XCTAssertNil(L.adjacentThreadId(["a", "b", "c"], current: "zz", direction: .next))
    }
    func testOrderByPreferredIds() {
        XCTAssertEqual(L.orderByPreferredIds(["a", "b", "c"], preferred: [], id: { $0 }), ["a", "b", "c"])
        XCTAssertEqual(L.orderByPreferredIds(["a", "b", "c"], preferred: ["c", "zz", "a"], id: { $0 }), ["c", "a", "b"])
        // duplicate preference ids consume distinct items
        XCTAssertEqual(L.orderByPreferredIds(["x1", "x2", "y"], preferred: ["x", "x"], id: { $0 }, preferenceIds: { [String($0.prefix(1))] }), ["x1", "x2", "y"])
    }
    func testPrewarmLimit() {
        XCTAssertEqual(L.threadIdsToPrewarm([1, 2, 3, 4, 5]), [1, 2, 3])
        XCTAssertEqual(L.threadIdsToPrewarm([1, 2], limit: -1), [])
        // "returns no thread ids when the limit is zero"
        XCTAssertEqual(L.threadIdsToPrewarm([1, 2], limit: 0), [])
    }
    func testRowStyle() {
        XCTAssertEqual(L.rowStyle(isActive: true, isSelected: true), .init(background: .active, foreground: .foreground, medium: true))
        XCTAssertEqual(L.rowStyle(isActive: false, isSelected: true), .init(background: .selected, foreground: .foreground, medium: false))
        XCTAssertEqual(L.rowStyle(isActive: true, isSelected: false), .init(background: .active, foreground: .foreground, medium: true))
        XCTAssertEqual(L.rowStyle(isActive: false, isSelected: false), .init(background: .none, foreground: .muted, medium: false))
    }
    // `searchSidebarThreadsByTitle`: case-insensitive substring match; an empty (or blank) query
    // returns no results upstream — the brief's own floor case ("" -> both threads) contradicted
    // that, so this follows Sidebar.logic.ts (`if (normalizedQuery.length === 0) return []`).
    func testSearchByTitle() {
        let a = T3Thread(id: "a", title: "Fix Login", createdAt: NOW, updatedAt: NOW), b = T3Thread(id: "b", title: "Greeting", createdAt: NOW, updatedAt: NOW)
        XCTAssertEqual(L.searchByTitle([a, b], query: " login ").map(\.id), ["a"])
        XCTAssertEqual(L.searchByTitle([a, b], query: "").map(\.id), [])
        XCTAssertEqual(L.searchByTitle([a, b], query: "   ").map(\.id), [])
    }
    // "matches thread titles case-insensitively and preserves their order" — three threads,
    // two matches out of order-preserving source order.
    func testSearchByTitleMatchesCaseInsensitivelyAndPreservesOrder() {
        let t1 = T3Thread(id: "thread-1", title: "Fix workspace search", createdAt: NOW, updatedAt: NOW)
        let t2 = T3Thread(id: "thread-2", title: "Review providers", createdAt: NOW, updatedAt: NOW)
        let t3 = T3Thread(id: "thread-3", title: "WORKTREE cleanup", createdAt: NOW, updatedAt: NOW)
        XCTAssertEqual(L.searchByTitle([t1, t2, t3], query: "work").map(\.id), ["thread-1", "thread-3"])
    }

    // Not ported, and why:
    // - Every hook/DOM-only describe the brief names to skip (`useSidebarRowSubscriptionLease`,
    //   `useRetainedValue`, `animateSidebarLayoutChanges`, `shouldClearThreadSelectionOnMouseDown`,
    //   `isTrailingDoubleClick`, context-menu builders, `ThreadJumpHintVisibilityController`) plus
    //   `deleteSelectedThreadEntries`/`archiveSelectedThreadEntries`/bulk-context-menu describes,
    //   `isContextMenuPointerDown`, `resolveSidebarThreadStatus`/`resolveThreadStatusPill`,
    //   `filterSidebarProjectScopeItems`/`reduceSidebarProjectScopeMenuState`,
    //   `resolveWorkingStartedAt`/`formatWorkingDurationLabel`, `resolveProjectStatusIndicator`,
    //   `getFallbackThreadIdAfterDelete`, and the project-sort describes
    //   (`sortProjectsForSidebar`/`sortScopedProjectsForSidebar`/`sortLogicalProjectsForSidebar`) —
    //   none of these are exports this task's Interfaces block lists.
    // - `searchSidebarThreadsByTitle`'s "does not match project metadata" `it`: `T3Thread` has no
    //   separate project-metadata field for `searchByTitle` to accidentally match in the first
    //   place, so this is guaranteed by the type, not worth a redundant test.
    // - `orderItemsByPreferredIds`'s "honors projectOrder physical keys via getProjectOrderKey" `it`
    //   exercises a project-specific ordering key function from a different module
    //   (`logicalProject.ts`), not `orderByPreferredIds` itself.
}
