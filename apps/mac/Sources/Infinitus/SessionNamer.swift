import Foundation
import InfinitusCore

/// Names for sessions that have none (user 2026-09-04: "sessions without
/// names Infinitus will use Claude Haiku to summarize the work in
/// progress, much like T3 Code or Conductor"). One `claude -p --model
/// haiku` per unnamed session, re-asked when its work moves on (goal,
/// todo count, phase) and at most every `minInterval`; titles persist in
/// `Infinitus/session-names.json` keyed by session id so a relaunch
/// re-asks nothing.
///
/// Claude Code, not the engine: the CLI rides whichever account is
/// active. It runs in `Infinitus/namer/` with user settings off
/// (`--setting-sources ""` — no hooks, no plugins, no MCP) so a name
/// costs one short Haiku turn and ~7 s; the prompt is prefixed
/// "[Infinitus]" and the Stats scanner skips that project dir, so naming
/// never counts as your work.
@MainActor
final class SessionNamer: ObservableObject {
    struct Entry: Codable, Equatable {
        var title: String
        var fingerprint: String
        var at: Date
    }

    @Published private(set) var names: [String: Entry] = [:]
    var enabled = true
    var onChange: (() -> Void)?

    static let minInterval: TimeInterval = 10 * 60
    private let storeURL: URL
    private let workDir: URL
    private var inFlight: Set<String> = []
    private var queue: [(id: String, fingerprint: String, prompt: String)] = []
    private var running = false

    init(appSupport: URL) {
        storeURL = appSupport.appendingPathComponent("session-names.json")
        workDir = appSupport.appendingPathComponent("namer", isDirectory: true)
        if let data = try? Data(contentsOf: storeURL),
           let loaded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            names = loaded
        }
    }

    func title(for sessionId: String) -> String? { names[sessionId]?.title }

    /// Called after every progress refresh with the unnamed sessions.
    func consider(_ sessions: [(id: String, cwd: String, progress: SessionProgress)], now: Date = Date()) {
        guard enabled, Self.claudePath() != nil else { return }
        for (id, cwd, p) in sessions {
            guard SessionNaming.isPlaceholder(p.name, cwd: cwd), let goal = p.goal, !goal.isEmpty else { continue }
            let fp = SessionNaming.fingerprint(p)
            if let have = names[id], have.fingerprint == fp || now.timeIntervalSince(have.at) < Self.minInterval { continue }
            if inFlight.contains(id) || queue.contains(where: { $0.id == id }) { continue }
            queue.append((id, fp, SessionNaming.prompt(p)))
        }
        pump()
    }

    /// One ask at a time — a burst of new sessions must not fan out
    /// into a burst of Haiku turns on the active account.
    private func pump() {
        guard !running, let next = queue.first else { return }
        queue.removeFirst()
        running = true
        inFlight.insert(next.id)
        let prompt = next.prompt, dir = workDir
        Task.detached(priority: .utility) { [weak self] in
            let raw = try? await Self.ask(prompt, cwd: dir)
            await self?.finish(id: next.id, fingerprint: next.fingerprint, title: raw.flatMap(SessionNaming.clean))
        }
    }

    private func finish(id: String, fingerprint: String, title: String?) {
        inFlight.remove(id)
        running = false
        if let title {
            names[id] = Entry(title: title, fingerprint: fingerprint, at: Date())
            save()
            onChange?()
        } else if var have = names[id] {
            have.at = Date()   // a failed ask waits the full interval too
            names[id] = have
        } else {
            names[id] = Entry(title: "", fingerprint: fingerprint, at: Date())
        }
        pump()
    }

    private func save() {
        let live = names.filter { !$0.value.title.isEmpty }
        guard let data = try? JSONEncoder().encode(live) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    /// Forget sessions that are gone (called with the ids still listed).
    func prune(keeping ids: Set<String>) {
        let before = names.count
        names = names.filter { ids.contains($0.key) }
        if names.count != before { save() }
    }

    static func claudePath() -> String? {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private struct Failed: Error {}

    /// CswapCLI.run's shape (Process on a GCD thread, bridged). Stdin
    /// carries the prompt so no session text lands on argv.
    private static func ask(_ prompt: String, cwd: URL, timeout: TimeInterval = 60) async throws -> String {
        guard let claude = claudePath() else { throw Failed() }
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: claude)
                p.arguments = ["-p", "--model", "haiku", "--max-turns", "1", "--output-format", "text",
                               "--setting-sources", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
                p.currentDirectoryURL = cwd
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:"
                    + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
                p.environment = env
                let input = Pipe(), out = Pipe()
                p.standardInput = input
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(throwing: error); return }
                // A CLI that quit before reading (#637): the non-throwing
                // `write(_:)` would raise an uncaught exception on the
                // broken pipe; the throwing one just leaves no name.
                try? input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
                try? input.fileHandleForWriting.close()
                let timeoutItem = DispatchWorkItem { p.terminate() }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timeoutItem.cancel()
                guard p.terminationStatus == 0 else { cont.resume(throwing: Failed()); return }
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}
