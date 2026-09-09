import SwiftUI
import UIKit
import XCTest
import InfinitusCore
import InfinitusUI
@testable import InfinitusMobile

/// Renders the T3 screens over fixture data and writes PNGs into the
/// app container's tmp/t3-shots (`xcrun simctl get_app_container <udid>
/// run.infinitus.mobile data`) and onto the test result as attachments —
/// the eyes on the clone between parity captures.
@MainActor final class T3RenderHarness: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_788_000_000)

    private static func at(_ s: Double) -> Date { now.addingTimeInterval(s) }

    static func conversation(prompt: SessionTimeline.Activity? = nil, running: Bool) -> TimelineFollower.State {
        var activities: [SessionTimeline.Activity] = [
            .init(id: "x1", tone: .tool, kind: "tool.started", summary: "Read SessionsScreen.swift", detail: nil,
                  payload: ["toolName": .string("Read")], turnId: "t2", sequence: 0, createdAt: at(61)),
            .init(id: "x2", tone: .tool, kind: "tool.started", summary: "swift build --product infinitusctl", detail: nil,
                  payload: ["toolName": .string("Bash")], turnId: "t2", sequence: 1, createdAt: at(62)),
        ]
        if let prompt { activities.append(prompt) }
        let timeline = SessionTimeline(
            turns: [
                .init(id: "t1", state: .completed, requestedAt: at(0), startedAt: at(0), completedAt: at(30),
                      userMessageId: "u1", assistantMessageId: "a1"),
                .init(id: "t2", state: running ? .running : .completed, requestedAt: at(60), startedAt: at(60),
                      completedAt: running ? nil : at(90), userMessageId: "u2", assistantMessageId: running ? nil : "a2"),
            ],
            messages: [
                .init(id: "u1", role: .user, text: "Why does the sessions list flicker when a row settles?", images: nil,
                      sender: nil, turnId: "t1", streaming: false, createdAt: at(0)),
                .init(id: "a1", role: .assistant, text: "The row's `id` changes with its status, so SwiftUI tears the cell down and rebuilds it.\n\nKeying on the pid alone keeps the identity stable:\n\n```swift\nForEach(rows, id: \\.pid)\n```", images: nil,
                      sender: nil, turnId: "t1", streaming: false, createdAt: at(30)),
                .init(id: "u2", role: .user, text: "Do it, and check the CLI still builds.", images: nil,
                      sender: nil, turnId: "t2", streaming: false, createdAt: at(60)),
            ] + (running ? [] : [
                .init(id: "a2", role: .assistant, text: "Done — the list keys on the pid and `infinitusctl` builds clean.", images: nil,
                      sender: nil, turnId: "t2", streaming: false, createdAt: at(90)),
            ]),
            activities: activities)
        let facts = SessionFacts(status: running ? .running : .ready, hasPendingApprovals: prompt != nil,
                                 hasPendingUserInput: false, hasPlan: false, latestTurn: timeline.turns.last,
                                 planProgress: nil, latestUserMessageAt: at(60), settledOverride: nil, settledAt: nil,
                                 unsettledAt: nil, snoozedUntil: nil, snoozedAt: nil, pinnedAt: nil)
        return .init(timeline: timeline, facts: facts, epoch: "e", sequence: 9, synchronized: true)
    }

    /// The parity fixture (spec §3.6, tools/t3ref/fixture.sh): one thread
    /// "Hi" in `limitless`, the "Hi" pair at 3:42 PM, nothing pending —
    /// what `refs/ios-thread.png` and `refs/ios-home.png` show.
    static let parityAt: Date = {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = 15; c.minute = 42
        return Calendar.current.date(from: c)!
    }()

    static func parityThread() -> TimelineFollower.State {
        let timeline = SessionTimeline(
            turns: [.init(id: "t1", state: .completed, requestedAt: parityAt, startedAt: parityAt, completedAt: parityAt,
                          userMessageId: "u1", assistantMessageId: "a1")],
            messages: [
                .init(id: "u1", role: .user, text: "Hi", images: nil, sender: nil, turnId: "t1", streaming: false, createdAt: parityAt),
                .init(id: "a1", role: .assistant, text: "Hi. Ready when you are — what's the task?", images: nil,
                      sender: nil, turnId: "t1", streaming: false, createdAt: parityAt),
            ],
            activities: [])
        let facts = SessionFacts(status: .ready, hasPendingApprovals: false, hasPendingUserInput: false, hasPlan: false,
                                 latestTurn: timeline.turns.last, planProgress: nil, latestUserMessageAt: parityAt,
                                 settledOverride: nil, settledAt: nil, unsettledAt: nil, snoozedUntil: nil, snoozedAt: nil, pinnedAt: nil)
        return .init(timeline: timeline, facts: facts, epoch: "e", sequence: 1, synchronized: true)
    }

    /// The tree in `refs/ios-files.png` (child counts included).
    static let parityListing: T3ProjectFiles.Listing = {
        func dir(_ p: String) -> T3ProjectFiles.Entry { .init(path: p, kind: .directory, size: nil) }
        func file(_ p: String) -> T3ProjectFiles.Entry { .init(path: p, kind: .file, size: 100) }
        var e: [T3ProjectFiles.Entry] = [
            dir(".claude"), dir(".claude/agents"), file(".claude/agents/coder.md"), dir(".claude/session-logs"),
            file(".claude/settings.json"),
            dir(".claude-plugin"), file(".claude-plugin/marketplace.json"),
            dir(".github"), dir(".github/instructions"), file(".github/instructions/swift.md"),
            dir(".github/ISSUE_TEMPLATE"), file(".github/ISSUE_TEMPLATE/bug.md"), file(".github/ISSUE_TEMPLATE/feature.md"),
            dir(".github/workflows"), file(".github/copilot-instructions.md"), file(".github/pull_request_template.md"),
            file(".github/VOUCHED.td"),
            dir(".impeccable"), dir(".impeccable/critique"),
        ]
        e += (1...6).map { file(".claude/session-logs/\($0).jsonl") }
        e += (1...7).map { file(".github/workflows/\($0).yml") }
        e += (1...4).map { file(".impeccable/critique/\($0).md") }
        return .init(cwd: "/tmp/t3fix/proj/limitless", entries: e, truncated: false)
    }()

    /// A 320×200 PNG, the top half one colour and the bottom another.
    static let fixturePNG: Data = {
        let size = CGSize(width: 320, height: 200)
        let renderer = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        return renderer.pngData { ctx in
            UIColor(red: 0.26, green: 0.42, blue: 0.86, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 100))
            UIColor(red: 0.95, green: 0.62, blue: 0.24, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 100, width: 320, height: 100))
        }
    }()

    /// Every block MarkdownText draws, for the markdown-* shots.
    static func richMarkdown() -> TimelineFollower.State {
        var state = conversation(running: false)
        let text = """
        ## What changed

        The row's `id` changed with its status, so SwiftUI **tore the cell down** and rebuilt it — see [the diff](https://example.com/pr/352).

        ```swift
        ForEach(rows, id: \\.pid) { row in
            T3HomeRow(entry: row)
        }
        ```

        - Keyed on the pid alone
        - Kept the swipe actions on the row
        1. Build
        2. Test on the simulator
        - [x] `infinitusctl` still builds
        - [ ] Phone install

        > Keying on identity, not state, is the whole fix.

        | PR | State |
        |---|---|
        | #360 | open |
        | #362 | queued |

        ---

        ### Next
        Nothing pending.
        """
        var messages = state.timeline.messages
        messages[3] = .init(id: "a2", role: .assistant, text: text, images: nil, sender: nil, turnId: "t2", streaming: false, createdAt: at(90))
        messages[2] = .init(id: "u2", role: .user, text: "Do it — run `swift build` and **check** the CLI:\n\n```sh\nswift build --product infinitusctl\n```", images: nil, sender: nil, turnId: "t2", streaming: false, createdAt: at(60))
        state.timeline = SessionTimeline(turns: state.timeline.turns, messages: messages, activities: state.timeline.activities)
        return state
    }

    static let parityHome: [T3HomeEntry] = [
        homeEntry(4243, "Hi", "limitless", nil, .ready, ago: 21 * 3600 + 60, macLabel: nil),
    ]

    /// A Home entry from the facts a leased session would carry.
    nonisolated static func homeEntry(_ pid: Int, _ title: String, _ repo: String, _ branch: String?, _ status: T3ThreadStatus,
                          ago: Double, pinned: Bool = false, snoozed: Bool = false, settled: Bool = false,
                          macLabel: String? = "Studio") -> T3HomeEntry {
        let last = Date().addingTimeInterval(-ago)
        let facts = SessionFacts(status: status == .working ? .running : status == .failed ? .error : .ready,
                                 hasPendingApprovals: status == .approval, hasPendingUserInput: status == .input, hasPlan: false,
                                 latestTurn: nil, planProgress: nil, latestUserMessageAt: last,
                                 settledOverride: settled ? .settled : nil, settledAt: nil, unsettledAt: nil,
                                 snoozedUntil: snoozed ? Date().addingTimeInterval(3600) : nil, snoozedAt: snoozed ? last : nil,
                                 pinnedAt: pinned ? Date().addingTimeInterval(-ago) : nil)
        let session = SessionDetail(pid: pid, cwd: "/Users/dev/" + repo, status: "busy", kind: "claude",
                                    startedAt: (Date().timeIntervalSince1970 - ago - 600) * 1000)
        return T3HomeEntry(session: session, macId: nil,
                           thread: T3Thread(session: session, facts: facts, progress: SessionProgress(lastActivityAt: last, name: title),
                                            environmentId: T3HomeThreads.environmentId(nil), now: Date()),
                           repo: repo, branch: branch, macLabel: macLabel, lastActivity: last)
    }

    static let homeEntries: [T3HomeEntry] = {
        func e(_ pid: Int, _ title: String, _ repo: String, _ branch: String?, _ status: T3ThreadStatus,
               ago: Double, pinned: Bool = false, snoozed: Bool = false, settled: Bool = false) -> T3HomeEntry {
            homeEntry(pid, title, repo, branch, status, ago: ago, pinned: pinned, snoozed: snoozed, settled: settled)
        }
        return [
            e(1, "Why does the sessions list flicker when a row settles?", "limitless", "t3-c6", .working, ago: 120),
            e(2, "Allow the deploy script to run", "banyan", "main", .approval, ago: 600, pinned: true),
            e(3, "Which fix do you want?", "limitless", "t3-c5", .input, ago: 3_900),
            e(4, "Rename the accounts pane fields", "limitless", "accounts-click-latency", .ready, ago: 75_600),
            e(5, "Hi", "limitless", nil, .ready, ago: 172_800, settled: true),
            e(6, "Investigate the AWS login banner", "banyan", "main", .ready, ago: 7_200, snoozed: true),
        ]
    }()

    static let approval = SessionTimeline.Activity(
        id: "perm:x2", tone: .approval, kind: "approval.requested", summary: "swift build", detail: nil,
        payload: ["requestId": .string("perm:x2"), "toolName": .string("Bash"), "requestType": .string("command"),
                  "input": .object(["command": .string("swift build --product infinitusctl")])],
        turnId: "t2", sequence: 2, createdAt: at(63))

    static let question = SessionTimeline.Activity(
        id: "3", tone: .approval, kind: "user-input.requested", summary: "Which fix?", detail: nil,
        payload: ["requestId": .string("3"), "questions": .array([
            .object(["id": .string("Which fix?"), "question": .string("Which fix do you want?"), "header": .string("Approach"),
                     "multiSelect": .bool(false),
                     "options": .array([
                        .object(["label": .string("Key on pid"), "description": .string("Smallest change; rows keep identity across status flips.")]),
                        .object(["label": .string("Diffable list"), "description": .string("Rewrite the list on a UICollectionView diffable source.")]),
                     ])]),
            .object(["id": .string("Also run e2e?"), "question": .string("Also run the e2e gate?"), "header": .string("Checks"),
                     "multiSelect": .bool(false),
                     "options": .array([.object(["label": .string("Yes"), "description": .string("")]),
                                        .object(["label": .string("No"), "description": .string("")])])]),
        ])],
        turnId: "t2", sequence: 2, createdAt: at(63))

    func testRendersTheThreadScreens() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("t3-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = MirrorModel(defaults: UserDefaults(suiteName: "t3-render")!)
        let session = SessionDetail(pid: 4242, cwd: "/Users/dev/death/limitless", status: "busy", kind: "claude", startedAt: 0)
        let shots: [(String, TimelineFollower.State, ColorScheme)] = [
            ("thread-working-light", Self.conversation(running: true), .light),
            ("thread-settled-dark", Self.conversation(running: false), .dark),
            ("thread-approval-light", Self.conversation(prompt: Self.approval, running: true), .light),
            ("thread-question-dark", Self.conversation(prompt: Self.question, running: true), .dark),
            ("markdown-light", Self.richMarkdown(), .light),
            ("markdown-dark", Self.richMarkdown(), .dark),
        ]
        for scheme in [ColorScheme.light, .dark] {
            let draft = NavigationStack {
                T3NewTaskDraft(model: model, cwd: "/Users/dev/death/limitless", macId: .constant(nil), changeProject: {})
            }
            .t3(platform: .mobile, scheme: scheme)
            .preferredColorScheme(scheme)
            let png = try Self.render(draft)
            let name = "new-task-\(scheme == .dark ? "dark" : "light")"
            try png.write(to: dir.appendingPathComponent(name + ".png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for scheme in [ColorScheme.light, .dark] {
            let home = NavigationStack {
                T3HomeBody(entries: Self.homeEntries, connection: .connected("Studio"), open: { _ in }, compose: {}, settings: {},
                           decorate: { _, _, row in AnyView(row.swipeActions { Button("Settle") {} }) })
            }
            .t3(platform: .mobile, scheme: scheme).preferredColorScheme(scheme)
            try Self.attach(name: "home-\(scheme == .dark ? "dark" : "light")", png: Self.render(home), dir: dir, test: self)
        }
        // The composer's `/` popover on its own, over the screen colour.
        let commands = [SlashCommand(name: "review", description: "Review the current PR", source: .projectCommand),
                        SlashCommand(name: "commit", description: "Commit staged changes with a message", source: .userCommand),
                        SlashCommand(name: "ship", description: "", source: .projectSkill)]
        for scheme in [ColorScheme.light, .dark] {
            let popover = ZStack {
                Color.clear
                VStack {
                    Spacer()
                    T3CommandPopover(items: commands, loading: false) { _ in }.padding(.horizontal, 12)
                    T3CommandPopover(items: [], loading: true) { _ in }.padding(.horizontal, 12)
                    T3CommandPopover(items: [], loading: false) { _ in }.padding(.horizontal, 12).padding(.bottom, 120)
                }
            }
            .background(T3ThemeBackground())
            .t3(platform: .mobile, scheme: scheme).preferredColorScheme(scheme)
            try Self.attach(name: "commands-\(scheme == .dark ? "dark" : "light")", png: Self.render(popover), dir: dir, test: self)
        }
        for scheme in [ColorScheme.light, .dark] {
            let sheet = T3SettingsSheet(model: model).t3(platform: .mobile, scheme: scheme).preferredColorScheme(scheme)
            try Self.attach(name: "settings-\(scheme == .dark ? "dark" : "light")", png: Self.render(sheet), dir: dir, test: self)
        }
        // Parity captures against tools/t3ref/refs (compare with
        // tools/t3ref/compare-harness.sh, status bar masked).
        let paritySession = SessionDetail(pid: 4243, cwd: "/tmp/t3fix/proj/limitless", status: "waiting", kind: "claude", startedAt: 0)
        model.sessionProgress.apply([4243: SessionProgress(name: "Hi")], tokenRate: nil)
        let parityThread = NavigationStack {
            T3ThreadScreen(model: model, session: paritySession, fixture: Self.parityThread())
        }
        .t3(platform: .mobile, scheme: .light).preferredColorScheme(.light)
        try Self.attach(name: "parity-thread", png: Self.render(parityThread), dir: dir, test: self)
        let parityHome = NavigationStack {
            T3HomeBody(entries: Self.parityHome, connection: .reconnecting(""), open: { _ in }, compose: {}, settings: {})
        }
        .t3(platform: .mobile, scheme: .light).preferredColorScheme(.light)
        try Self.attach(name: "parity-home", png: Self.render(parityHome), dir: dir, test: self)
        let macsPage = T3SettingsSheet(model: model, path: NavigationPath([SettingsForm.Part.macs])).t3(platform: .mobile, scheme: .light).preferredColorScheme(.light)
        try Self.attach(name: "settings-macs-light", png: Self.render(macsPage), dir: dir, test: self)
        let usagePage = T3SettingsSheet(model: model, path: NavigationPath([SettingsForm.Part.usage])).t3(platform: .mobile, scheme: .dark).preferredColorScheme(.dark)
        try Self.attach(name: "settings-usage-dark", png: Self.render(usagePage), dir: dir, test: self)
        // The cost tab needs the Mac's engine report, which no fixture
        // snapshot carries — rendered over a merged report of its own.
        let costTab = ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                T3UsageCostTab(merged: Self.usageCost, seriesColors: [T3UsageColors.bar(.claude, dark: true), Color(white: 0.6)])
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
        .background(Color.black.ignoresSafeArea())
        .t3(platform: .mobile, scheme: .dark).preferredColorScheme(.dark)
        try Self.attach(name: "usage-cost-dark", png: Self.render(costTab), dir: dir, test: self)
        let settings = T3ThreadSettingsSheet(model: model, session: session, macId: nil,
                                             facts: Self.conversation(running: true).facts)
            .t3(platform: .mobile, scheme: .light).preferredColorScheme(.light)
        try Self.attach(name: "thread-settings-light", png: Self.render(settings), dir: dir, test: self)
        let limitsNow = ISO8601DateFormatter().date(from: "2026-09-03T11:00:00Z")!
        let limits = T3ComposerLimits.Report(provider: .claude, members: [
            .init(number: 2, name: "Work", email: "work@x.com", plan: "Max", disabled: false, windows: [
                .init(kind: .session, id: "session", label: "Session", usedPct: 62, resetsAt: limitsNow.addingTimeInterval(2 * 3600),
                      length: T3UsageLimits.sessionSeconds, expectedPct: nil),
                .init(kind: .weekly, id: "weekly", label: "Weekly", usedPct: 88, resetsAt: limitsNow.addingTimeInterval(3 * 86400 + 3 * 3600),
                      length: T3UsageLimits.weekSeconds, expectedPct: nil),
            ]),
        ], notices: ["Work: cooling down after a rate limit"])
        let limitsCard = VStack { Spacer(); T3ComposerLimitsCard(report: limits, now: limitsNow) {}.padding(.horizontal, 12).padding(.bottom, 80) }
            .background(T3ThemeBackground())
            .t3(platform: .mobile, scheme: .dark).preferredColorScheme(.dark)
        try Self.attach(name: "composer-limits-dark", png: Self.render(limitsCard), dir: dir, test: self)
        // Appearance → Text at 20 pt: every T3 mobile font follows the scale.
        T3Font.mobileScale = 20.0 / 16.0
        let large = NavigationStack {
            T3ThreadScreen(model: model, session: paritySession, fixture: Self.parityThread())
        }
        .t3(platform: .mobile, scheme: .dark).preferredColorScheme(.dark)
        try Self.attach(name: "thread-text-20-dark", png: Self.render(large), dir: dir, test: self)
        T3Font.mobileScale = 1
        let filesListing = T3ProjectFiles.Listing(cwd: "/tmp/t3fix/proj/limitless", entries: [
            .init(path: "README.md", kind: .file, size: 2048), .init(path: "Package.swift", kind: .file, size: 900),
            .init(path: "Sources", kind: .directory), .init(path: "Sources/Infinitus", kind: .directory),
            .init(path: "Sources/Infinitus/InfinitusApp.swift", kind: .file, size: 5200),
            .init(path: "Sources/InfinitusCore", kind: .directory), .init(path: "Sources/InfinitusCore/Models.swift", kind: .file, size: 14000),
            .init(path: "ios", kind: .directory), .init(path: "ios/project.yml", kind: .file, size: 9500),
            .init(path: "tools", kind: .directory), .init(path: "tools/e2e.sh", kind: .file, size: 41000),
        ], truncated: false)
        let files = NavigationStack { T3FilesScreen(model: model, session: session, fixture: filesListing) }
            .t3(platform: .mobile, scheme: .dark).preferredColorScheme(.dark)
        try Self.attach(name: "files-dark", png: Self.render(files), dir: dir, test: self)
        let source = T3ProjectFiles.FileRead(path: "Sources/Infinitus/InfinitusApp.swift",
                                         contents: (1...40).map { "let line\($0) = \"value \($0)\"  // a comment that runs a little long" }.joined(separator: "\n"),
                                         byteLength: 5200, truncated: false, mime: "text/x-swift")
        let sourcePage = NavigationStack { T3SourceFileScreen(model: model, session: session, path: source.path, fixture: .text(source)) }
            .t3(platform: .mobile, scheme: .dark).preferredColorScheme(.dark)
        try Self.attach(name: "source-file-dark", png: Self.render(sourcePage), dir: dir, test: self)
        // An image answered as bytes (B-26): a 320×200 two-tone PNG.
        let imagePage = NavigationStack {
            T3SourceFileScreen(model: model, session: session, path: "docs/site/hero.png", fixture: .image(Self.fixturePNG))
        }
        .t3(platform: .mobile, scheme: .dark).preferredColorScheme(.dark)
        try Self.attach(name: "image-file-dark", png: Self.render(imagePage), dir: dir, test: self)
        let git = T3GitSheet(branch: "t3-c5", session: session).t3(platform: .mobile, scheme: .dark).preferredColorScheme(.dark)
        try Self.attach(name: "git-sheet-dark", png: Self.render(git), dir: dir, test: self)
        // refs/ios-files.png: the fixture project's dotfolders, top level open.
        let parityFiles = NavigationStack {
            T3FilesScreen(model: model, session: paritySession, fixture: Self.parityListing)
        }
        .t3(platform: .mobile, scheme: .light).preferredColorScheme(.light)
        try Self.attach(name: "parity-files", png: Self.render(parityFiles), dir: dir, test: self)
        for (name, state, scheme) in shots {
            let root = NavigationStack {
                T3ThreadScreen(model: model, session: session, fixture: state)
            }
            .t3(platform: .mobile, scheme: scheme)
            .preferredColorScheme(scheme)
            let png = try Self.render(root)
            try png.write(to: dir.appendingPathComponent(name + ".png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// Hosts the view in a key window the size of the simulator's screen,
    /// lets two run-loop turns lay it out, and snapshots the hierarchy —
    /// UIKit-backed views (the editor) included.
    /// Two Macs' cswap reports over three days, as `T3UsageCost.merge` folds them.
    static var usageCost: T3UsageCost.Merged {
        func bucket(_ n: Int, _ alias: String, _ usd: Double, _ model: String) -> UsageReport.UsageBucket {
            .init(number: n, email: "\(alias.lowercased())@x.com", alias: alias, estimatedUSD: usd, messages: 40,
                  input: 12_000, output: 3_400, cacheRead: 480_000, cacheWrite: 22_000,
                  models: [.init(model: model, estimatedUSD: usd, messages: 40)])
        }
        let studio = UsageReport(days: 3, estimatedTotalUSD: 18.4, priceTable: .init(source: "test", date: "2026-09-01"),
                                 accounts: [bucket(1, "Work", 18.4, "claude-opus-4-1")], unpricedTokens: nil,
                                 caveats: ["Cache reads priced at the listed discount."],
                                 daily: [.init(date: "2026-09-07", account: 1, estimatedUSD: 4.1, messages: 10),
                                         .init(date: "2026-09-08", account: 1, estimatedUSD: 8.3, messages: 20),
                                         .init(date: "2026-09-09", account: 1, estimatedUSD: 6.0, messages: 10)])
        let air = UsageReport(days: 3, estimatedTotalUSD: 5.2, priceTable: .init(source: "test", date: "2026-09-01"),
                              accounts: [bucket(1, "Home", 5.2, "claude-sonnet-4")], unpricedTokens: 900, caveats: [],
                              daily: [.init(date: "2026-09-08", account: 1, estimatedUSD: 5.2, messages: 40)])
        let today = ISO8601DateFormatter().date(from: "2026-09-09T15:00:00Z")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return T3UsageCost.merge([.init(macId: nil, macName: "Studio", provider: .claude, report: studio),
                                  .init(macId: "m2", macName: "Air", provider: .claude, report: air)], today: today, calendar: cal)!
    }

    static func attach(name: String, png: Data, dir: URL, test: XCTestCase) throws {
        try png.write(to: dir.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    private static var sharedWindow: UIWindow?

    static func render<V: View>(_ view: V) throws -> Data {
        // A window with no scene never reaches the screen and draws blank;
        // it rides the test host's scene.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)
        let bounds = scene.screen.bounds
        // One window for every shot: a second window on the scene drew
        // blank for the rest of the run.
        let window = try sharedWindow ?? {
            let w = UIWindow(windowScene: scene)
            w.frame = bounds
            sharedWindow = w
            return w
        }()
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        // The first frames after a window appears can draw blank (the run
        // that follows other tests saw it); keep drawing until the image
        // has content, up to a few seconds.
        var png = Data()
        for _ in 0..<12 {
            let deadline = Date().addingTimeInterval(0.4)
            while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            // 8-bit sRGB: the default extended range writes 16-bit PNGs,
            // which tools/t3ref/compare.py (stdlib-only) can't decode.
            let format = UIGraphicsImageRendererFormat.default()
            format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                window.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            png = try XCTUnwrap(image.pngData())
            if !isBlank(image) { break }
        }
        return png
    }

    /// True when the corners and the center are one color — nothing drew.
    private static func isBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return true }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        func px(_ x: Int, _ y: Int) -> [UInt8] {
            let o = y * bpr + x * bpp
            return Array(UnsafeBufferPointer(start: bytes + o, count: bpp))
        }
        let w = cg.width, h = cg.height
        let samples = [px(2, 2), px(w - 3, 2), px(w / 2, h / 2), px(w / 2, h / 3), px(w / 3, h - 3)]
        return Set(samples).count == 1
    }
}

/// The screen colour from the installed palette, for standalone component shots.
private struct T3ThemeBackground: View {
    @Environment(\.t3) private var t3
    var body: some View { t3.mobile.screen.color.ignoresSafeArea() }
}
