import Foundation

/// The stats days this Mac folds for its team (#1592): what `team-days`
/// answers the desktop's Team publisher, which sends them to Infinitus
/// Connect. Owns the fold memo #499 introduced — one fold per scan
/// generation, kept until the next, the raw entries given back once
/// folded — so the verb answers from the memo and never re-folds the
/// corpus (#251). The hooks are the app's (StatsModel through AppModel);
/// tests hand in a scan directly.
public final class TeamDays {
    /// True when this instance scans its transcripts for itself.
    public var ownsScan: () -> Bool = { false }
    /// The last finished scan's entries; nil before one has run to its end.
    public var scanEntries: () -> [String: StatsScanner.FileEntry]? = { nil }
    /// Bumped with every table handed over.
    public var scanGeneration: () -> Int = { 0 }
    /// The table of that generation was folded and can go.
    public var scanConsumed: (Int) -> Void = { _ in }
    /// Nothing to fold: ask for a scan, answer next time.
    public var scanRequested: () -> Void = {}
    public var calendar: Calendar = .current

    /// What the last call could not answer: set while a scan is wanted,
    /// cleared by the fold that satisfies it. The app's scan gate reads it.
    public private(set) var scanWanted = false

    public struct Reply: Codable, Equatable, Sendable {
        /// Day key → the day, compacted (no per-minute tokens, sessions
        /// or repos: the tallies and the peak stay).
        public var days: [String: Stats.Day]
        /// The private projects, as `team-exclude` took them.
        public var exclusions: [String]
        /// The scan generation the fold came from; 0 with no fold yet.
        public var generation: Int
    }

    private struct Fold {
        var generation: Int
        var exclusions: TeamExclusions
        var floorDay: String
        var days: [String: Stats.Day]
    }

    public let paths: TeamPaths
    private var fold: Fold?

    public init(paths: TeamPaths) { self.paths = paths }

    /// The folded days inside the last `days` days, from the memo when
    /// its generation, exclusions and floor day still match, from a fresh
    /// fold of the scan's table otherwise. Without a table (the first scan
    /// after launch still running, or one given back) it asks for a scan
    /// and answers empty with generation 0.
    public func reply(days: Int, now: Date = Date()) -> Reply {
        let exclusions = TeamExclusions.load(paths: paths)
        let floorDay = TeamFold.floorDay(now: now, historyDays: days, calendar: calendar)
        let generation = scanGeneration()
        if let fold, fold.generation == generation, fold.exclusions == exclusions, fold.floorDay == floorDay {
            return Reply(days: fold.days, exclusions: exclusions.projects, generation: fold.generation)
        }
        guard ownsScan(), let entries = scanEntries() else {
            scanWanted = true
            scanRequested()
            return Reply(days: [:], exclusions: exclusions.projects, generation: 0)
        }
        let collected = TeamFold.collect(entries: TeamFold.inWindow(entries, floorDay: floorDay), exclusions: exclusions)
        let compacted = collected.days.mapValues { $0.compacted() }
        fold = Fold(generation: generation, exclusions: exclusions, floorDay: floorDay, days: compacted)
        scanWanted = false
        scanConsumed(generation)
        return Reply(days: compacted, exclusions: exclusions.projects, generation: generation)
    }
}
