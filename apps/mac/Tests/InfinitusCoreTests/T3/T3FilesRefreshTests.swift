import XCTest
@testable import InfinitusCore

/// The Files tab's re-list edges and its truncated notice — the cheap stand-in
/// for `useWorkspaceMutationRefresh` (`FileBrowserPanel.tsx:267-271`,
/// `useWorkspaceMutationRefresh.ts:17-36`).
final class T3FilesRefreshTests: XCTestCase {
    private func signal(_ threadId: String?,
                        _ turn: T3Thread.Turn.State?) -> T3FilesRefresh.Signal {
        T3FilesRefresh.Signal(threadId: threadId, turnState: turn)
    }

    // MARK: - shouldRelist

    func testASettledTurnRelists() {
        XCTAssertTrue(T3FilesRefresh.shouldRelist(from: signal("a", .running),
                                                  to: signal("a", .completed)))
    }

    /// An interrupted turn wrote whatever it wrote before the stop, and an
    /// errored one may have half-written a file.
    func testAnInterruptedOrErroredTurnRelistsToo() {
        XCTAssertTrue(T3FilesRefresh.shouldRelist(from: signal("a", .running),
                                                  to: signal("a", .interrupted)))
        XCTAssertTrue(T3FilesRefresh.shouldRelist(from: signal("a", .running),
                                                  to: signal("a", .error)))
    }

    /// The turn that just STARTED has not run a tool yet.
    func testATurnStartingDoesNotRelist() {
        XCTAssertFalse(T3FilesRefresh.shouldRelist(from: signal("a", .completed),
                                                   to: signal("a", .running)))
        XCTAssertFalse(T3FilesRefresh.shouldRelist(from: signal("a", nil),
                                                   to: signal("a", .running)))
    }

    func testNoChangeDoesNotRelist() {
        XCTAssertFalse(T3FilesRefresh.shouldRelist(from: signal("a", .running),
                                                   to: signal("a", .running)))
        XCTAssertFalse(T3FilesRefresh.shouldRelist(from: signal("a", .completed),
                                                   to: signal("a", .completed)))
    }

    /// A switch inside one project never remounts the browser, so the edge has
    /// to carry it.
    func testAThreadSwitchRelistsWhateverTheTurnsSay() {
        XCTAssertTrue(T3FilesRefresh.shouldRelist(from: signal("a", .completed),
                                                  to: signal("b", .completed)))
        XCTAssertTrue(T3FilesRefresh.shouldRelist(from: signal("a", .running),
                                                  to: signal("b", .running)))
        XCTAssertTrue(T3FilesRefresh.shouldRelist(from: signal("a", nil),
                                                  to: signal(nil, nil)))
    }

    // MARK: - the notice

    func testTheTruncatedNoticeIsUpstreamsCopy() {
        XCTAssertEqual(T3FilesRefresh.truncatedNotice,
                       "Some workspace entries are not shown.")
    }
}
