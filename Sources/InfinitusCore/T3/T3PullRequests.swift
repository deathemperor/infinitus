import Foundation

/// The right panel's Pull request tab, read through the GitHub CLI — the
/// design spec's F bullet ("Pull requests = `gh pr list --json` per project").
///
/// Upstream's own panel talks to its server, which talks to `gh` in exactly
/// this shape (`apps/server/src/pullRequest/GitHubPullRequestCli.ts`, whose
/// reads are `gh pr list/view --json <fields>` per project cwd) and hands the
/// page the contract in `packages/contracts/src/pullRequest.ts:466-502`
/// (`PullRequestListEntry`). The names here mirror that contract —
/// `headBranch`/`baseBranch` rather than gh's `headRefName`/`baseRefName`,
/// `checksState` for the one-word rollup a row wears — and the mapping from
/// gh's JSON is the server's own (`gitHubPullRequestJson.ts:1221-1318`,
/// `pullRequestChecks.ts:30-56`), so the same rollup produces the same word
/// here as on the web page.
///
/// Foundation only, and every process spawn is behind `GhRunner` /
/// `GitRunner`: the decode and the check arithmetic are pure, so the tests
/// read canned `gh` output rather than a live repository.
///
/// NOT ported this round, each with its upstream line:
/// - the review and comment threads (`PullRequestTimelineTab.tsx`,
///   `PullRequestReactions.tsx:1-60`, `contracts/pullRequest.ts:186-210`'s
///   `PullRequestComment`).
/// - every write action — merge, ready, draft, close, reopen, update-branch,
///   auto-merge, revert, approve-workflows (`contracts/pullRequest.ts:78-100`
///   `PullRequestAction`) — and the checkout command
///   (`PullRequestDetailPanel.tsx:2054-2070`).
/// - title/body editing (`PullRequestDetailPanel.tsx:2004-2045`,
///   `PullRequestMarkdownEditor.tsx`).
/// - the list's search, filters, labels and involvement narrowing
///   (`PullRequestListFilters.tsx`, `contracts/pullRequest.ts:48-66`), the
///   `+N -N` diff stat (`pullRequestPresentation.tsx:344-366`, whose counts
///   `gh pr list` does not carry anyway) and the per-project spread of a
///   whole workspace (`pullRequestProjectFilter.logic.ts`).
/// - mergeability and base freshness (`contracts/pullRequest.ts:73,116`):
///   `gh pr list` reports neither, so a row's glyph never says "conflicts".
public enum T3PullRequests: Sendable {

    // MARK: - The shapes (`contracts/pullRequest.ts`)

    /// `PullRequestState` (`:17`). gh writes them upper-case.
    public enum State: String, Codable, Sendable {
        case open, closed, merged
        static func read(_ raw: String) -> State? { State(rawValue: raw.lowercased()) }
    }

    /// `PullRequestReviewDecision` (`:28-33`). gh sends `""` where a host
    /// summarises no review, which is nothing rather than a verdict
    /// (`gitHubPullRequestJson.ts:1176-1187`).
    public enum ReviewDecision: String, Codable, Sendable {
        case approved, changesRequested = "changes-requested", reviewRequired = "review-required"
        static func read(_ raw: String?) -> ReviewDecision? {
            switch raw?.trimmingCharacters(in: .whitespaces).uppercased() {
            case "APPROVED": return .approved
            case "CHANGES_REQUESTED": return .changesRequested
            case "REVIEW_REQUIRED": return .reviewRequired
            default: return nil
            }
        }
    }

    /// `PullRequestCheckStatus` (`:132-144`).
    public enum CheckStatus: String, Codable, Sendable {
        case pending, actionRequired = "action-required", success, failure
        case skipped, neutral, cancelled
    }

    /// `PullRequestChecksState` (`:70`) — the one glyph a list row carries.
    public enum ChecksState: String, Codable, Sendable { case passing, failing, pending }

    /// `PullRequestActor` (`:122-127`). `gh pr list --json author` reports no
    /// avatar, so `avatarUrl` is always nil here and the initial stands in
    /// (`pullRequestPresentation.tsx:280-300`).
    public struct Actor: Codable, Sendable, Equatable {
        public let login: String
        public let name: String?
        public let avatarUrl: String?
        public init(login: String, name: String? = nil, avatarUrl: String? = nil) {
            self.login = login; self.name = name; self.avatarUrl = avatarUrl
        }
    }

    /// `PullRequestCheck` (`:147-152`).
    public struct Check: Codable, Sendable, Equatable {
        public let name: String
        public let status: CheckStatus
        public let description: String?
        public let url: String?
        public init(name: String, status: CheckStatus, description: String? = nil, url: String? = nil) {
            self.name = name; self.status = status; self.description = description; self.url = url
        }
    }

    /// One pull request, as a list row and as the detail header read it.
    public struct Entry: Codable, Sendable, Equatable {
        public let number: Int
        public let title: String
        public let url: String
        public let author: Actor?
        public let headBranch: String
        public let baseBranch: String
        public let state: State
        public let isDraft: Bool
        public let updatedAt: Date
        public let reviewDecision: ReviewDecision?
        /// The rollup's checks, one row per check rather than per run
        /// (`pullRequestChecks.ts:30`).
        public let checks: [Check]
        /// The word the row wears, worked out the server's way over the raw
        /// rollup (`gitHubPullRequestJson.ts:1307-1318`).
        public let checksState: ChecksState?

        public init(number: Int, title: String, url: String, author: Actor?, headBranch: String,
                    baseBranch: String, state: State, isDraft: Bool, updatedAt: Date,
                    reviewDecision: ReviewDecision? = nil, checks: [Check] = [],
                    checksState: ChecksState? = nil) {
            self.number = number; self.title = title; self.url = url; self.author = author
            self.headBranch = headBranch; self.baseBranch = baseBranch; self.state = state
            self.isDraft = isDraft; self.updatedAt = updatedAt
            self.reviewDecision = reviewDecision; self.checks = checks; self.checksState = checksState
        }
    }

    // MARK: - Failures

    /// Why the tab has nothing to ask — the `prAvailable` gate
    /// (`RightPanelTabs.tsx:359`) answered in words.
    public enum Unavailable: Error, Sendable, Equatable {
        /// No `gh` on PATH.
        case cliMissing
        /// The cwd is not a work tree, or its `origin` is not on github.com.
        case noGitHubRemote

        public var message: String {
            switch self {
            case .cliMissing:
                return "Install the GitHub CLI (gh) to see this project's pull requests."
            case .noGitHubRemote:
                return "This project has no GitHub remote."
            }
        }
    }

    /// A read that could not answer. `failed` carries gh's own stderr, which
    /// is what names the fix (`gh auth login`) — upstream's card shows the
    /// message it is given rather than inferring one
    /// (`PullRequestsUnavailableState.tsx:32-35`).
    public enum LoadError: Error, Sendable, Equatable {
        case unavailable(Unavailable)
        case failed(String)
        /// gh answered something this cannot read
        /// (`GitHubPullRequestCli.ts:110`).
        case unreadable(String)

        public var message: String {
            switch self {
            case .unavailable(let why): return why.message
            case .failed(let detail): return detail
            case .unreadable(let operation):
                return "GitHub CLI returned an unreadable \(operation) response."
            }
        }
    }

    /// A field gh answered that no `Entry` can be built from.
    struct Malformed: Error, Sendable, Equatable { let field: String }

    // MARK: - gh's own JSON

    /// The fields every read asks for. One list, so the list and the current
    /// branch's pull request decode through the same shape.
    public static let jsonFields = "number,title,state,isDraft,headRefName,baseRefName,author,url,updatedAt,statusCheckRollup,reviewDecision"
    /// `--limit`: a project's open pull requests, not its history.
    public static let listLimit = 50

    /// `gh pr list --json …`'s array.
    struct RawEntry: Decodable {
        var number: Int?
        var title: String?
        var state: String?
        var isDraft: Bool?
        var headRefName: String?
        var baseRefName: String?
        var author: RawActor?
        var url: String?
        var updatedAt: String?
        var statusCheckRollup: [RawCheck]?
        var reviewDecision: String?
    }

    struct RawActor: Decodable {
        var login: String?
        var name: String?
    }

    /// A rollup row: a check run (`status` + a `conclusion` that only exists
    /// once it completed) or a commit status (`state`)
    /// (`gitHubPullRequestJson.ts:1221-1247`).
    struct RawCheck: Decodable {
        var name: String?
        var context: String?
        var status: String?
        var conclusion: String?
        var state: String?
        var description: String?
        var detailsUrl: String?
        var targetUrl: String?
        var workflowName: String?
        var completedAt: String?
        var startedAt: String?
    }

    /// `gh pr view --json body`.
    struct RawBody: Decodable { var body: String? }

    public static func decodeList(_ data: Data) throws -> [Entry] {
        try JSONDecoder().decode([RawEntry].self, from: data).map { try entry(from: $0) }
    }

    public static func decodeEntry(_ data: Data) throws -> Entry {
        try entry(from: try JSONDecoder().decode(RawEntry.self, from: data))
    }

    public static func decodeBody(_ data: Data) throws -> String {
        try JSONDecoder().decode(RawBody.self, from: data).body ?? ""
    }

    static func entry(from raw: RawEntry) throws -> Entry {
        guard let number = raw.number, number > 0 else { throw Malformed(field: "number") }
        guard let title = trimmed(raw.title) else { throw Malformed(field: "title") }
        guard let url = trimmed(raw.url) else { throw Malformed(field: "url") }
        guard let stateText = trimmed(raw.state), let state = State.read(stateText) else {
            throw Malformed(field: "state")
        }
        guard let head = trimmed(raw.headRefName) else { throw Malformed(field: "headRefName") }
        guard let base = trimmed(raw.baseRefName) else { throw Malformed(field: "baseRefName") }
        guard let updatedAt = timestamp(raw.updatedAt) else { throw Malformed(field: "updatedAt") }
        return Entry(number: number, title: title, url: url, author: actor(raw.author),
                     headBranch: head, baseBranch: base, state: state,
                     isDraft: raw.isDraft ?? false, updatedAt: updatedAt,
                     reviewDecision: ReviewDecision.read(raw.reviewDecision),
                     checks: checks(rollup: raw.statusCheckRollup),
                     checksState: checksState(rollup: raw.statusCheckRollup))
    }

    static func actor(_ raw: RawActor?) -> Actor? {
        guard let login = trimmed(raw?.login) else { return nil }
        return Actor(login: login, name: trimmed(raw?.name), avatarUrl: nil)
    }

    static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// What GitHub writes where a run has not reached that moment yet, which
    /// is not a time (`gitHubPullRequestJson.ts:1250`).
    static let unsetTimestamp = "0001-01-01T00:00:00Z"

    /// Cached: a fresh `ISO8601DateFormatter` builds an ICU calendar, and a
    /// rollup of fifty pull requests would build hundreds of them.
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func timestamp(_ value: String?) -> Date? {
        guard let text = trimmed(value), text != unsetTimestamp else { return nil }
        return iso.date(from: text) ?? isoFractional.date(from: text)
    }

    // MARK: - The checks arithmetic (`gitHubPullRequestJson.ts`, `pullRequestChecks.ts`)

    /// `toCheckStatus` verbatim (`gitHubPullRequestJson.ts:1221-1247`): a run
    /// that has not completed is pending whatever it may later conclude, and
    /// a commit status's `state` stands in for a run's `conclusion`.
    static func checkStatus(_ raw: RawCheck) -> CheckStatus {
        let status = raw.status?.trimmingCharacters(in: .whitespaces).uppercased()
        if let status, status != "COMPLETED", !status.isEmpty { return .pending }
        switch (raw.conclusion ?? raw.state)?.trimmingCharacters(in: .whitespaces).uppercased() {
        case "SUCCESS": return .success
        case "ACTION_REQUIRED": return .actionRequired
        case "FAILURE", "ERROR", "TIMED_OUT", "STARTUP_FAILURE": return .failure
        case "CANCELLED": return .cancelled
        case "SKIPPED": return .skipped
        case "PENDING", "EXPECTED": return .pending
        default: return .neutral
        }
    }

    /// One rollup row as the deduper reads it (`:1263-1288`): the check, the
    /// workflow that owns it, and when the run last had something to say — a
    /// queued run reports a completion time it has not reached, so its start
    /// stands in.
    struct CheckEntry: Sendable, Equatable {
        let check: Check
        let workflowName: String?
        let at: String?
    }

    static func checkEntries(rollup: [RawCheck]?) -> [CheckEntry] {
        (rollup ?? []).compactMap { raw in
            guard let name = trimmed(raw.name) ?? trimmed(raw.context) else { return nil }
            let at = realTimestamp(raw.completedAt) ?? realTimestamp(raw.startedAt)
            return CheckEntry(check: Check(name: name, status: checkStatus(raw),
                                           description: trimmed(raw.description),
                                           url: trimmed(raw.detailsUrl) ?? trimmed(raw.targetUrl)),
                              workflowName: trimmed(raw.workflowName), at: at)
        }
    }

    static func realTimestamp(_ value: String?) -> String? {
        guard let text = trimmed(value), text != unsetTimestamp else { return nil }
        return text
    }

    /// Only a row the rollup gives no name of any kind (`:1256-1258`).
    static func isNameless(_ raw: RawCheck) -> Bool {
        trimmed(raw.name) == nil && trimmed(raw.context) == nil
    }

    /// `dedupeChecks` (`pullRequestChecks.ts:30-56`): one row per check rather
    /// than per run of it — the name qualified by its workflow identifies it,
    /// the newest run wins, the order is the host's own held at the place each
    /// check first appeared, and two survivors sharing a name are written
    /// `workflow / name` the way GitHub writes them itself.
    static func dedupe(_ entries: [CheckEntry]) -> [Check] {
        var order: [String] = []
        var newest: [String: CheckEntry] = [:]
        for entry in entries {
            let key = "\(entry.workflowName ?? "") \(entry.check.name)"
            guard let kept = newest[key] else {
                order.append(key)
                newest[key] = entry
                continue
            }
            if isAtLeastAsNew(entry.at, kept.at) { newest[key] = entry }
        }
        let survivors = order.compactMap { newest[$0] }
        var countsByName: [String: Int] = [:]
        for entry in survivors { countsByName[entry.check.name, default: 0] += 1 }
        return survivors.map { entry in
            guard let workflow = entry.workflowName, !workflow.isEmpty,
                  (countsByName[entry.check.name] ?? 0) > 1 else { return entry.check }
            return Check(name: "\(workflow) / \(entry.check.name)", status: entry.check.status,
                         description: entry.check.description, url: entry.check.url)
        }
    }

    /// ISO-8601 timestamps in UTC compare correctly as plain text
    /// (`pullRequestChecks.ts:3-7`); a tie goes to whichever came last,
    /// because a host lists a re-run after the run it repeats.
    static func isAtLeastAsNew(_ candidate: String?, _ kept: String?) -> Bool {
        guard let candidate else { return kept == nil }
        guard let kept else { return true }
        return candidate >= kept
    }

    /// The rollup's checks, deduped (`gitHubPullRequestJson.ts:1320-1324`).
    static func checks(rollup: [RawCheck]?) -> [Check] {
        dedupe(checkEntries(rollup: rollup))
    }

    /// `rollupChecksState` (`:1307-1318`): a failure outranks anything still
    /// running, and a head commit with no checks at all shows nothing rather
    /// than a green tick it never earned. Counted off the deduped checks, so
    /// the word and the list under it cannot disagree.
    ///
    /// Note the one place upstream disagrees with itself: this rollup counts a
    /// cancelled run as neither, where the page's own
    /// `pullRequestChecksState` (`pullRequestPresentation.tsx:196-204`) reads
    /// it as failing. A row here comes from the same rollup the server reads,
    /// so it answers the server's way.
    static func checksState(rollup: [RawCheck]?) -> ChecksState? {
        var statuses = checks(rollup: rollup).map(\.status)
        statuses += (rollup ?? []).filter(isNameless).map(checkStatus)
        if statuses.isEmpty { return nil }
        if statuses.contains(.failure) { return .failing }
        if statuses.contains(.pending) || statuses.contains(.actionRequired) { return .pending }
        return statuses.contains(.success) ? .passing : nil
    }

    /// `isWorkflowApprovalCheck` (`pullRequestPresentation.tsx:152-158`): a
    /// fork's workflow waiting to be allowed to run, which reads differently
    /// from a check waiting on somebody.
    static func isWorkflowApproval(_ check: Check) -> Bool {
        guard check.status == .actionRequired, let url = check.url else { return false }
        return url.range(of: "/actions/runs/[0-9]+(/|$)", options: .regularExpression) != nil
    }

    /// `summarizePullRequestChecks` (`pullRequestPresentation.tsx:421-446`) —
    /// the sentence under a detail header, in GitHub's own arithmetic.
    public static func summarize(checks: [Check]) -> String {
        if checks.isEmpty { return "No checks reported" }
        let actionRequired = checks.filter { $0.status == .actionRequired }
        let workflowApprovals = actionRequired.filter(isWorkflowApproval).count
        let otherActionRequired = actionRequired.count - workflowApprovals
        let failed = checks.filter { $0.status == .failure || $0.status == .cancelled }.count
        let pending = checks.filter { $0.status == .pending }.count
        let passed = checks.filter { $0.status == .success }.count
        if failed > 0 { return "\(failed) of \(checks.count) failing" }
        if workflowApprovals > 0 && otherActionRequired > 0 {
            return "\(workflowApprovals) \(workflowApprovals == 1 ? "workflow" : "workflows") and \(otherActionRequired) \(otherActionRequired == 1 ? "check" : "checks") awaiting action"
        }
        if workflowApprovals > 0 {
            return "\(workflowApprovals) \(workflowApprovals == 1 ? "workflow" : "workflows") awaiting approval"
        }
        if otherActionRequired > 0 {
            return "\(otherActionRequired) \(otherActionRequired == 1 ? "check" : "checks") awaiting action"
        }
        if pending > 0 { return "\(pending) of \(checks.count) running" }
        return passed == checks.count ? "All checks passed" : "\(passed) of \(checks.count) passing"
    }

    /// `CHECKS_STATE_PRESENTATION`'s headline (`pullRequestPresentation.tsx:165-181`)
    /// — GitHub's own wording for the rollup, so a reader who knows that page
    /// reads this one the same way.
    public static func checksStateLabel(_ state: ChecksState) -> String {
        switch state {
        case .passing: return "All checks have passed"
        case .failing: return "Some checks were not successful"
        case .pending: return "Some checks haven't completed yet"
        }
    }

    /// `resolvePullRequestState`'s label (`pullRequestPresentation.tsx:41-83`),
    /// minus the conflict case `gh pr list` cannot report.
    public static func stateLabel(state: State, isDraft: Bool) -> String {
        switch state {
        case .merged: return "Merged"
        case .closed: return "Closed"
        case .open: return isDraft ? "Draft" : "Open"
        }
    }

    // MARK: - The availability gate (`RightPanelTabs.tsx:359`)

    /// Whether a remote URL is on github.com — the host itself, so
    /// `github.com.example.com` and `notgithub.com` are not it. Both git's
    /// forms: `git@github.com:owner/repo.git` and any URL with a host.
    public static func isGitHubRemote(_ url: String) -> Bool {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return host(ofRemote: text)?.lowercased() == "github.com"
    }

    static func host(ofRemote text: String) -> String? {
        if text.contains("://") { return URL(string: text)?.host }
        // scp-like: `[user@]host:path`, where the host ends at the first colon.
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let authority = String(text[text.startIndex..<colon])
        guard let at = authority.lastIndex(of: "@") else { return authority.isEmpty ? nil : authority }
        let host = String(authority[authority.index(after: at)...])
        return host.isEmpty ? nil : host
    }

    /// `nil` when the tab can read pull requests here: `gh` on PATH and a cwd
    /// whose `origin` is a GitHub remote. The remote is checked first — it is
    /// a file read where the gh probe is a spawn, and it is what decides
    /// whether gh may be run for this cwd at all.
    public static func availability(cwd: String,
                                   gh: GhRunner = GhRunner(),
                                   git: GitRunner = GitRunner(timeout: 5)) -> Unavailable? {
        guard let remote = try? git.run(["remote", "get-url", "origin"], cwd: cwd),
              isGitHubRemote(remote) else { return .noGitHubRemote }
        guard (try? gh.run(["--version"], cwd: cwd)) != nil else { return .cliMissing }
        return nil
    }

    /// The `prAvailable` gate itself.
    public static func available(cwd: String,
                                gh: GhRunner = GhRunner(),
                                git: GitRunner = GitRunner(timeout: 5)) -> Bool {
        availability(cwd: cwd, gh: gh, git: git) == nil
    }

    // MARK: - The reads

    /// The project's open pull requests, newest activity first — gh's own
    /// order (`gh pr list` sorts by created, the page re-reads nothing).
    public static func list(cwd: String, limit: Int = listLimit,
                            gh: GhRunner = GhRunner(),
                            git: GitRunner = GitRunner(timeout: 5)) -> Result<[Entry], LoadError> {
        if let why = availability(cwd: cwd, gh: gh, git: git) { return .failure(.unavailable(why)) }
        do {
            let data = try gh.run(["pr", "list", "--json", jsonFields, "--limit", String(limit)], cwd: cwd)
            return .success(try decodeList(data))
        } catch let failure as GhRunner.Failure {
            return .failure(.failed(failure.description))
        } catch {
            return .failure(.unreadable("list"))
        }
    }

    /// The pull request for the checked-out branch, or nil where the branch
    /// has none — which is what `gh pr view` says by failing
    /// ("no pull requests found for branch …"). A caller reaches this after
    /// `list` succeeded, so an auth or network failure has already been
    /// reported and what is left is the branch having nothing.
    public static func current(cwd: String,
                              gh: GhRunner = GhRunner(),
                              git: GitRunner = GitRunner(timeout: 5)) -> Result<Entry?, LoadError> {
        if let why = availability(cwd: cwd, gh: gh, git: git) { return .failure(.unavailable(why)) }
        guard let data = try? gh.run(["pr", "view", "--json", jsonFields], cwd: cwd) else {
            return .success(nil)
        }
        do { return .success(try decodeEntry(data)) } catch { return .failure(.unreadable("view")) }
    }

    /// One pull request's markdown body, which the detail renders through the
    /// chat's own markdown (`PullRequestMarkdown.tsx:38-50`).
    public static func body(cwd: String, number: Int,
                           gh: GhRunner = GhRunner()) -> Result<String, LoadError> {
        do {
            let data = try gh.run(["pr", "view", String(number), "--json", "body"], cwd: cwd)
            return .success(try decodeBody(data))
        } catch let failure as GhRunner.Failure {
            return .failure(.failed(failure.description))
        } catch {
            return .failure(.unreadable("view"))
        }
    }
}

/// `gh` as a child process, synchronous — callers run it off the main thread.
/// `GitRunner`'s shape (`Checkpoints.swift:222`), with gh's own quiet
/// environment: no pager, no colour, no update notifier, and no prompt, so a
/// read either answers or fails rather than waiting on a terminal nobody is
/// looking at. Secrets never travel on argv — gh reads its own auth.
public struct GhRunner: Sendable {
    public var timeout: TimeInterval
    public init(timeout: TimeInterval = 20) { self.timeout = timeout }

    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let status: Int32
        public let stderr: String
        public var description: String {
            stderr.isEmpty ? "gh exited \(status)" : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Raw stdout — every caller here decodes JSON from it.
    public func run(_ args: [String], cwd: String) throws -> Data {
        #if os(Windows) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        // No child processes here; the phone reads pull requests over the
        // mirror if it ever shows them.
        throw Failure(status: 127, stderr: "gh runs on the Mac (and Linux) only")
        #else
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["gh"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["GH_PAGER"] = "cat"
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["NO_COLOR"] = "1"
        env["CLICOLOR"] = "0"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        // Drain both pipes before waiting: fifty rows with their rollups fill
        // stdout's buffer and the child blocks on write otherwise.
        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else {
            throw Failure(status: p.terminationStatus, stderr: String(decoding: stderrData, as: UTF8.self))
        }
        return stdoutData
        #endif
    }
}
