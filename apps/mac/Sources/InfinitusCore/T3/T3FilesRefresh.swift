import Foundation

/// When the Files tab re-reads its listing, and what it says when the listing
/// did not fit.
///
/// Upstream re-lists on `useWorkspaceMutationRefresh`
/// (`FileBrowserPanel.tsx:267-271`): its server names the latest provider event
/// after which files on disk may have changed — a completed `file_change` or
/// `command_execution` tool (`useWorkspaceMutationRefresh.ts:17-36`) — and the
/// listing refreshes once per such event. This port has no per-tool mutation id
/// on the wire, so the cheap stand-in is the edge those events all sit inside:
/// the selected thread's turn leaving `running`. One re-read per turn instead of
/// one per mutating tool, no file watching and no timer, so idle cost is nil.
public enum T3FilesRefresh {
    /// What a re-list is decided from — the selected thread and the state of its
    /// latest turn, as `T3WorkspaceState` already publishes them.
    public struct Signal: Sendable, Equatable {
        public let threadId: String?
        public let turnState: T3Thread.Turn.State?
        public init(threadId: String?, turnState: T3Thread.Turn.State?) {
            self.threadId = threadId
            self.turnState = turnState
        }
    }

    /// True on two edges, and on no others:
    /// - the thread changed — the tab is keyed on the project's cwd
    ///   (`ChatView.tsx:8078`'s `key`), so a switch inside one project never
    ///   remounts the browser and its listing would otherwise stay as the
    ///   previous thread's turn left it;
    /// - the turn settled: it was running and no longer is (completed,
    ///   interrupted or errored alike — an interrupted turn can have written
    ///   just as much as a completed one).
    ///
    /// Never on a turn STARTING: nothing has run yet, and a re-list there would
    /// spawn a `git ls-files` on every send.
    public static func shouldRelist(from previous: Signal, to current: Signal) -> Bool {
        if previous.threadId != current.threadId { return true }
        return previous.turnState == .running && current.turnState != .running
    }

    /// `Listing.truncated`'s notice, verbatim (`FileBreadcrumbs.tsx:190` — the
    /// only place upstream words this; `FileBrowserPanel.tsx` shows no notice at
    /// all, and `FilePreviewPanel.tsx:1216` is about one file's contents being
    /// cut, not the listing). Upstream renders it as a disabled menu item under
    /// a separator at the BOTTOM of the entry list (`:187-192`), which is where
    /// the tree puts it too.
    public static let truncatedNotice = "Some workspace entries are not shown."
}
