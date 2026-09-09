import Foundation
import AppKit
import InfinitusCore

/// The selected thread's rows, long-polled the way `SessionChatStore`
/// polls one pid's feed (Task 9) — but reduced through `T3TimelineRows`
/// instead of the phone's flat item list, and keyed by session id
/// (`threadId`) so a resume (new pid, same thread) can `rebind` rather
/// than restart from a blank store.
@MainActor
final class T3TimelineStore: ObservableObject {
    @Published private(set) var rows: [T3TimelineRows.Row] = []
    @Published private(set) var timeline: SessionTimeline?
    /// Approvals + user inputs above the composer (Task 12).
    @Published private(set) var pending = PendingRequests.derive([])
    /// Owned usage limits (Task 12).
    @Published private(set) var limits: [LimitNote] = []
    /// No record for the pid (under this thread's session id) any more.
    /// Reset on every successful record lookup, not just a stamp
    /// change — otherwise the banner is reachable only briefly today
    /// because the state drops a vanished pid
    /// (https://github.com/deathemperor/infinitus/issues/400).
    @Published private(set) var gone = false

    let threadId: String
    /// Read off `image(id:)`, `nonisolated`, so this can't stay
    /// actor-isolated; only `start()`/`stop()`/`rebind(pid:)`, all
    /// main-actor methods, mutate it. (The polling loop's
    /// `Task.detached` captures `pid` by value instead — it never reads
    /// this property off-actor.)
    nonisolated(unsafe) private(set) var pid: Int32
    private weak var model: AppModel?
    private weak var window: T3WindowModel?
    private var loop: Task<Void, Never>?
    private var lastOwnedPending: [PendingRequest] = []
    private var lastFacts: SessionFacts?

    init(threadId: String, pid: Int32, model: AppModel, window: T3WindowModel) {
        self.threadId = threadId
        self.pid = pid
        self.model = model
        self.window = window
    }

    deinit { loop?.cancel() }

    func start() {
        guard loop == nil, let model else { return }
        let box = model.ownedBox
        let timelineCache = model.timelineCache
        let attentionStore = model.attentionStore
        let threadId = threadId
        loop = Task.detached(priority: .utility) { [pid, weak self] in
            var since: String?
            while !Task.isCancelled {
                let claudeDir = ClaudeSessions.configHome()
                // An owned session's prompts live in memory, not the
                // transcript: they ride the stamp, and its actor wakes
                // this wait the moment one parks (OwnedFeed).
                let owned = box.existing.flatMap { $0.ownedPids.contains(pid) ? $0 : nil }
                // 5 s: a stopped store's loop cannot see cancellation
                // inside waitForChange
                // (https://github.com/deathemperor/infinitus/issues/399);
                // a per-thread store churns on every sidebar click, so
                // the orphan window stays short.
                SessionFeedReader.waitForChange(pid: pid, claudeDir: claudeDir, since: since, wait: 5, poll: 1.0,
                                                decorate: { stamp in owned.map { OwnedFeed.decorate(stamp, pending: $0.pending(pid: pid), limits: $0.limits(pid: pid)) } ?? stamp },
                                                wake: owned?.wake)
                if Task.isCancelled { return }
                // A pid reuse by an unrelated session must not show as
                // this thread's transcript — only `gone`.
                guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid && $0.sessionId == threadId }) else {
                    await MainActor.run { [pid] in
                        guard let self, self.pid == pid else { return }
                        self.gone = true
                    }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }
                await MainActor.run { [pid] in
                    guard let self, self.pid == pid else { return }
                    self.gone = false
                }
                guard let raw = timelineCache.timeline(record: record, claudeDir: claudeDir) else {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                let ownedPending = owned?.pending(pid: pid) ?? []
                let ownedLimits = owned?.limits(pid: pid) ?? []
                let rawStamp = SessionFeedReader.stamp(record: record, claudeDir: claudeDir)
                let stamp = rawStamp.map { s in OwnedFeed.decorate(s, pending: ownedPending, limits: ownedLimits) }
                if stamp != since || since == nil {
                    since = stamp
                    // `pending` folds into `make`'s entries itself
                    // (`T3TimelineEntry.entries(from:pending:)`) — limits
                    // fold here so the published `timeline` and the facts
                    // below both carry them, but pending stays unfolded so
                    // it is never folded twice.
                    let withLimits = raw.appending(limits: ownedLimits)
                    let full = withLimits.appending(pending: ownedPending)
                    let facts = SessionFacts.derive(timeline: full, status: record.status,
                                                    attention: attentionStore.entry(sessionId: record.sessionId))
                    await MainActor.run { [pid] in
                        guard let self, self.pid == pid else { return }
                        self.timeline = withLimits
                        self.limits = ownedLimits
                        self.pending = PendingRequests.derive(full.activities)
                        self.lastOwnedPending = ownedPending
                        self.lastFacts = facts
                        self.applyRows(timeline: withLimits, ownedPending: ownedPending, facts: facts)
                    }
                }
                // No stamp to wait on (transcript not there yet): pace
                // the retry instead of spinning on an instant return.
                if since == nil { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// A resume lands a new pid under the same session — keep the store
    /// (and its rows' identity) rather than the caller tearing it down.
    func rebind(pid: Int32) {
        stop()
        self.pid = pid
        start()
    }

    /// `expandedTurnIds`/`expandedWorkGroupIds` changed: re-derive from the
    /// cached timeline, no disk read.
    func rederive() {
        guard let timeline else { return }
        applyRows(timeline: timeline, ownedPending: lastOwnedPending, facts: lastFacts)
    }

    private func applyRows(timeline built: SessionTimeline, ownedPending: [PendingRequest], facts: SessionFacts?) {
        let expandedTurnIds = window?.state.expandedTurnIds[threadId] ?? []
        let expandedWorkGroupIds = window?.state.expandedWorkGroupIds[threadId] ?? []
        let input = T3TimelineInput.make(timeline: built, pending: ownedPending, facts: facts,
                                         expandedTurnIds: expandedTurnIds, expandedWorkGroupIds: expandedWorkGroupIds)
        let next = T3TimelineRows.stable(previous: rows, next: T3TimelineRows.derive(input))
        if next != rows { rows = next }
    }

    /// A prompt image, read the way the mirror's image route reads it.
    nonisolated func image(id: String) -> NSImage? {
        let claudeDir = ClaudeSessions.configHome()
        guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid && $0.sessionId == threadId }),
              let image = SessionFeedReader.imageData(record: record, id: id, claudeDir: claudeDir,
                                                      attachmentsDir: SessionInput.defaultAttachmentsDir)
        else { return nil }
        return NSImage(data: image.data)
    }
}
