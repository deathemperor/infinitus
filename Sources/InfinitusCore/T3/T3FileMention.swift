import Foundation

/// The `@` menu's files: the project's tracked (and untracked-but-not-ignored)
/// paths, ranked against what was typed after the `@`.
///
/// Upstream asks its server for `projects.searchEntries`
/// (`apps/server/src/ws.ts:2256`), which is a native `FileFinder` index
/// (`WorkspaceSearchIndex.ts:300-327`) — a binary this port has no equivalent
/// of. So the list comes from `git ls-files` (a bounded `FileManager` walk
/// behind it) and the ranking is the repo's own TypeScript one: `scoreQueryMatch`
/// / `scoreSubsequenceMatch` (`packages/shared/src/searchRanking.ts:22-136`)
/// with the tiers the file tree scores paths on
/// (`apps/mobile/src/features/files/fileTree.ts:130-143`).
///
/// Foundation only, so the phone builds it too — the `git` subprocess is
/// guarded exactly as `Checkpoints.run` guards its own (Checkpoints.swift:234).
public enum T3FileMention: Sendable {
    /// The menu's row cap (`rank`'s default), as the composer offers it.
    public static let limit = 12
    /// `WORKSPACE_INDEX_MAX_ENTRIES`' job: a monorepo's checkout is not walked
    /// into the millions for a menu of twelve rows.
    public static let maxListed = 20_000
    /// What the fallback walk never descends into.
    public static let skippedDirectories: Set<String> = [".git", "node_modules", ".build"]

    // MARK: - Listing

    /// Relative paths under `cwd`, `git ls-files` first. Blocking: the caller
    /// runs it off the main actor (the composer's detached load). `limit`
    /// bounds both sources — the file browser asks for one over its own cap
    /// so it can tell a full listing from a truncated one.
    public static func list(cwd: String, fileManager: FileManager = .default,
                            limit: Int = maxListed) -> [String] {
        if let tracked = gitListed(cwd: cwd, limit: limit), !tracked.isEmpty { return tracked }
        return walk(cwd: cwd, fileManager: fileManager, maxEntries: limit)
    }

    /// `--cached --others --exclude-standard`: what the repo tracks plus what
    /// it does not ignore — upstream's index excludes gitignored files and
    /// nothing else (`server.test.ts:6810`). `-z` because git quotes odd
    /// filenames otherwise. nil = no repo here (or no git), so the walk answers.
    static func gitListed(cwd: String, limit: Int = maxListed) -> [String]? {
        #if os(Windows) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        // No child processes here (Checkpoints.swift:234 makes the same call);
        // the walk covers every platform.
        return nil
        #else
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: killer)
        // Drain before waiting: a big checkout fills the pipe's buffer and the
        // child blocks on write otherwise (the lesson in Checkpoints.run).
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        let paths = String(decoding: data, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        return Array(paths.prefix(limit))
        #endif
    }

    /// The fallback: every file under `cwd` but the build and vendor trees,
    /// capped. `enumerator(atPath:)` yields paths relative to the directory,
    /// sidestepping the symlink-resolved absolute URLs `enumerator(at:)`
    /// returns (the reason SlashCommands.swift:54-58 uses it too).
    static func walk(cwd: String, fileManager: FileManager = .default,
                     maxEntries: Int = maxListed) -> [String] {
        guard maxEntries > 0, let enumerator = fileManager.enumerator(atPath: cwd) else { return [] }
        var out: [String] = []
        for case let relative as String in enumerator {
            let name = (relative as NSString).lastPathComponent
            let path = (cwd as NSString).appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if skippedDirectories.contains(name) { enumerator.skipDescendants() }
                continue
            }
            out.append(relative)
            if out.count >= maxEntries { break }
        }
        return out
    }

    /// What picking a row inserts. Upstream writes a markdown link
    /// (`serializeComposerFileLink`, `composerTrigger.ts:29-32`) because its
    /// composer renders one; the consumer here is Claude Code, whose mention
    /// syntax IS `@<path>`, so the bare path is what goes in.
    public static func insertion(for path: String) -> String { "@\(path) " }


    // MARK: - Ranking

    /// A path with its lowercased UTF-16 form already built, and where its last
    /// component starts in it. Preparing the list once per project is what
    /// keeps a keystroke's ranking allocation-free — the composer caches these
    /// per cwd and only the query changes.
    public struct Candidate: Sendable {
        public let path: String
        let units: ContiguousArray<UInt16>
        let nameOffset: Int

        public init(path: String) {
            self.path = path
            let lowered = ContiguousArray(path.lowercased().utf16)
            var offset = 0
            for index in lowered.indices where lowered[index] == 0x2F { offset = index + 1 }
            self.units = lowered
            self.nameOffset = min(offset, lowered.count)
        }
    }

    public static func candidates(_ paths: [String]) -> [Candidate] { paths.map(Candidate.init) }

    public static func rank(paths: [String], query: String, limit: Int = limit) -> [String] {
        rank(candidates(paths), query: query, limit: limit)
    }

    /// `searchSlashCommandItems`' shape (`composerSlashCommandSearch.ts:76-113`):
    /// no query keeps the list as it came in; otherwise every candidate is
    /// scored, the unscored dropped, and the best `limit` kept — sorted by
    /// score with the path as the tie-breaker, which is what
    /// `insertRankedSearchResult`'s bounded insertion (`searchRanking.ts:138-192`)
    /// produces.
    public static func rank(_ candidates: [Candidate], query: String, limit: Int = limit) -> [String] {
        guard limit > 0 else { return [] }
        // `normalizeSearchQuery` (`searchRanking.ts:7-20`).
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return candidates.prefix(limit).map(\.path) }
        var ranked: [(path: String, score: Int)] = []
        ContiguousArray(normalized.utf16).withUnsafeBufferPointer { needle in
            for candidate in candidates {
                guard let score = score(candidate, query: needle) else { continue }
                ranked.append((candidate.path, score))
            }
        }
        // `compareRankedSearchResults` (`:138-145`) compares the score, then
        // the tie-breaker — ordinally here, not `localeCompare`, so the order
        // is the same in every locale (and on every platform).
        ranked.sort { $0.score == $1.score ? $0.path < $1.path : $0.score < $1.score }
        return ranked.prefix(limit).map(\.path)
    }

    /// The filename tier is `fileTree.ts:132-141`'s exactly (its
    /// `boundaryMarkers` included); the whole relative path is the secondary
    /// value, offset by 20 the way `composerSlashCommandSearch.ts:59-66`
    /// offsets a command's description behind its name — so an exact filename
    /// beats every path match, and a path match beats a fuzzy filename. The
    /// lower of the two wins (`:73`).
    static func score(_ candidate: Candidate, query: UnsafeBufferPointer<UInt16>) -> Int? {
        candidate.units.withUnsafeBufferPointer { full -> Int? in
            // Every tier needs the query to at least be a subsequence of the
            // value, and the filename is a subrange of the path: one cheap
            // pass rejects the whole candidate before the tiers are tried.
            guard subsequenceScore(full, query) != nil else { return nil }
            let name = UnsafeBufferPointer(rebasing: full[candidate.nameOffset...])
            let byName = scoreQueryMatch(value: name, query: query, exactBase: 0, prefixBase: 2,
                                         boundaryBase: 4, includesBase: 6, fuzzyBase: 100,
                                         boundaryMarkers: pathBoundaryMarkers)
            // The path tier's best possible score is its `exactBase`, so a
            // filename that scored better than that cannot be improved on.
            if let byName, byName < 20 { return byName }
            let byPath = scoreQueryMatch(value: full, query: query, exactBase: 20, prefixBase: 22,
                                         boundaryBase: 24, includesBase: 26, fuzzyBase: 120,
                                         boundaryMarkers: pathBoundaryMarkers)
            switch (byName, byPath) {
            case let (byName?, byPath?): return min(byName, byPath)
            case let (byName?, nil): return byName
            case let (nil, byPath?): return byPath
            default: return nil
            }
        }
    }

    /// `fileTree.ts:140`.
    static let pathBoundaryMarkers: [UInt16] = Array("/-_.".utf16)
    /// `scoreQueryMatch`'s own default (`searchRanking.ts:114`).
    static let defaultBoundaryMarkers: [UInt16] = Array(" -_/".utf16)

    /// `scoreQueryMatch` (`searchRanking.ts:86-136`) — value and query are
    /// already trimmed and lowercased, as its doc requires; UTF-16 units, so
    /// the offsets the score is built from are the JS string's.
    ///
    /// Every marker upstream ever passes is one character
    /// (`searchRanking.ts:114`, `fileTree.ts:140`,
    /// `composerSlashCommandSearch.ts:57`), which makes
    /// `min(indexOf(marker + query) + marker.length)` over the markers exactly
    /// "the earliest occurrence of the query whose preceding unit is a marker"
    /// — one scan for the boundary and the contains tiers together instead of
    /// one per marker.
    static func scoreQueryMatch(value: UnsafeBufferPointer<UInt16>, query: UnsafeBufferPointer<UInt16>,
                                exactBase: Int, prefixBase: Int? = nil, boundaryBase: Int? = nil,
                                includesBase: Int? = nil, fuzzyBase: Int? = nil,
                                boundaryMarkers: [UInt16]) -> Int? {
        guard !value.isEmpty, !query.isEmpty, value.count >= query.count else { return nil }
        let penalty = min(64, max(0, value.count - query.count))   // `lengthPenalty` (`:54-56`)
        if value.count == query.count, matches(query, in: value, at: 0) { return exactBase }
        if let prefixBase, matches(query, in: value, at: 0) { return prefixBase + penalty }
        if boundaryBase != nil || includesBase != nil {
            var includesIndex = -1, boundaryIndex = -1
            var start = 0
            while start + query.count <= value.count {
                if matches(query, in: value, at: start) {
                    if includesIndex == -1 { includesIndex = start }
                    if start > 0, boundaryMarkers.contains(value[start - 1]) {
                        boundaryIndex = start
                        break
                    }
                }
                start += 1
            }
            if let boundaryBase, boundaryIndex >= 0 { return boundaryBase + boundaryIndex * 2 + penalty }
            if let includesBase, includesIndex >= 0 { return includesBase + includesIndex * 2 + penalty }
        }
        if let fuzzyBase, let fuzzy = subsequenceScore(value, query) { return fuzzyBase + fuzzy }
        return nil
    }

    /// `scoreSubsequenceMatch` (`:22-52`): the first match's offset, the gaps
    /// between matches, the span they cover and how much longer the value is.
    static func subsequenceScore(_ value: UnsafeBufferPointer<UInt16>,
                                 _ query: UnsafeBufferPointer<UInt16>) -> Int? {
        guard !query.isEmpty else { return 0 }
        var queryIndex = 0, firstMatch = -1, previousMatch = -1, gapPenalty = 0
        for valueIndex in value.indices where value[valueIndex] == query[queryIndex] {
            if firstMatch == -1 { firstMatch = valueIndex }
            if previousMatch != -1 { gapPenalty += valueIndex - previousMatch - 1 }
            previousMatch = valueIndex
            queryIndex += 1
            if queryIndex == query.count {
                let spanPenalty = valueIndex - firstMatch + 1 - query.count
                return firstMatch * 2 + gapPenalty * 3 + spanPenalty
                    + min(64, value.count - query.count)
            }
        }
        return nil
    }

    private static func matches(_ needle: UnsafeBufferPointer<UInt16>,
                                in haystack: UnsafeBufferPointer<UInt16>, at offset: Int) -> Bool {
        guard offset >= 0, haystack.count - offset >= needle.count else { return false }
        for index in needle.indices where haystack[offset + index] != needle[index] { return false }
        return true
    }

    // MARK: - The primitives over strings (what the transcribed tests pin)

    static func scoreQueryMatch(value: String, query: String, exactBase: Int,
                                prefixBase: Int? = nil, boundaryBase: Int? = nil,
                                includesBase: Int? = nil, fuzzyBase: Int? = nil,
                                boundaryMarkers: [String]? = nil) -> Int? {
        let markers = boundaryMarkers.map { $0.compactMap { $0.utf16.first } } ?? defaultBoundaryMarkers
        return ContiguousArray(value.utf16).withUnsafeBufferPointer { value in
            ContiguousArray(query.utf16).withUnsafeBufferPointer { query in
                scoreQueryMatch(value: value, query: query, exactBase: exactBase,
                                prefixBase: prefixBase, boundaryBase: boundaryBase,
                                includesBase: includesBase, fuzzyBase: fuzzyBase,
                                boundaryMarkers: markers)
            }
        }
    }

    static func scoreSubsequenceMatch(_ value: String, _ query: String) -> Int? {
        ContiguousArray(value.utf16).withUnsafeBufferPointer { value in
            ContiguousArray(query.utf16).withUnsafeBufferPointer { query in
                subsequenceScore(value, query)
            }
        }
    }
}
