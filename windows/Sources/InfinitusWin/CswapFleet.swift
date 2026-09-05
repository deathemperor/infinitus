import Foundation
import InfinitusCore

/// The account half of the snapshot, when this box runs the swap engine.
///
/// claude-swap ships a Windows wheel (`uv tool install claude-swap` →
/// `~/.local/bin/cswap.exe`), and CLAUDE.md's rule holds here exactly as
/// on the Mac: the engine is a `cswap … --json` subprocess and nothing
/// else — never a read of `~/.claude-swap-backup`, never a second policy
/// on top. Account policy (auto-swap, ordering, thresholds) stays the
/// engine's; this only reads what it reports.
///
/// Absent engine is the normal case, not an error: the daemon then serves
/// the account-less synthetic fleet and the phone hides that section.
enum CswapFleet {
    /// Matches the Mac's fleet key so the phone treats a Windows host's
    /// cswap fleet as the same engine, not a second one.
    static let engineID = "cswap"

    /// How long a list is reused. The engine polls Anthropic on its own
    /// schedule; re-shelling per phone poll would add nothing but load.
    static let cacheSeconds: TimeInterval = 30

    /// Longer than a cold `cswap list` (it may refresh a token), short
    /// enough that a wedged engine can't hold the phone's snapshot.
    static let timeout: TimeInterval = 20

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: (list: AccountList?, at: Date)?

    /// `cswap list --json`, or nil when the engine isn't installed, times
    /// out, or answers something this build can't decode. Every failure is
    /// nil, never a throw — an engine hiccup must not take the session
    /// feed down with it.
    static func list(now: Date = Date()) -> AccountList? {
        lock.lock()
        defer { lock.unlock() }
        if let cached, now.timeIntervalSince(cached.at) < cacheSeconds {
            return cached.list
        }
        let fresh = read()
        cached = (fresh, now)
        return fresh
    }

    /// Drops the cache so the next snapshot re-shells — for a caller that
    /// just changed account state and wants the change visible now.
    static func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }

    private static func read() -> AccountList? {
        guard let result = run(["list", "--json"]), result.status == 0 else { return nil }
        return try? JSONDecoder().decode(AccountList.self, from: result.output)
    }

    // MARK: - switching

    /// What a switch attempt did, for a caller that has to report it.
    enum SwitchOutcome {
        case switched(to: Int)
        case noEngine
        /// The engine ran and refused (unknown number, disabled account,
        /// nothing to rotate to). `detail` is its own stderr, trimmed.
        case failed(detail: String)

        var message: String {
            switch self {
            case .switched(let number): return "switched to account \(number)"
            case .noEngine: return "no swap engine installed"
            case .failed(let detail):
                return detail.isEmpty ? "engine refused the switch" : detail
            }
        }
    }

    /// `cswap switch <n> --json`, or `cswap switch --json` to rotate.
    ///
    /// CLAUDE.md: account policy lives in the ENGINE. This asks the engine
    /// to switch and reports what it says — it never picks the target
    /// itself, never writes account state, and never second-guesses a
    /// refusal. `nil` number means "engine, you choose", which is the
    /// engine's own rotation order and not a policy of ours.
    static func switchTo(_ number: Int?) -> SwitchOutcome {
        guard CswapLocator.locate() != nil else { return .noEngine }
        let args = number.map { ["switch", String($0), "--json"] } ?? ["switch", "--json"]
        guard let result = run(args) else {
            return .failed(detail: "engine did not run")
        }
        guard result.status == 0 else {
            return .failed(detail: Self.failureDetail(result))
        }
        let object = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any]
        // A `--json` tool can carry a refusal in the body while still
        // exiting 0. Reporting "switched" then would be a lie the caller
        // has no way to catch.
        if let object, object["error"] != nil {
            return .failed(detail: Self.failureDetail(result))
        }
        // The active account just changed, so the cached list is a lie —
        // drop it rather than show the old one for up to 30 s.
        invalidate()
        // Trust the engine's own answer for which account is now active;
        // a rotation's target is only knowable from its reply.
        if let object,
           let active = (object["activeAccountNumber"] as? NSNumber)?.intValue
                     ?? (object["active"] as? NSNumber)?.intValue {
            return .switched(to: active)
        }
        if let number { return .switched(to: number) }
        // Rotated, but the reply didn't name the target: re-read rather
        // than invent a number.
        return .switched(to: list()?.activeAccountNumber ?? 0)
    }

    // MARK: - backup

    /// What an export or import did.
    enum BackupOutcome {
        case ok(detail: String)
        case noEngine
        case failed(detail: String)

        var message: String {
            switch self {
            case .ok(let detail): return detail
            case .noEngine: return "no swap engine installed"
            case .failed(let detail):
                return detail.isEmpty ? "the engine refused" : detail
            }
        }
        var succeeded: Bool {
            if case .ok = self { return true }
            return false
        }
    }

    /// `cswap export <path>` — every managed account in one file.
    ///
    /// The file holds CREDENTIALS (each account's `oauthAccount`; with
    /// `full`, all of `~/.claude.json`). The caller says so out loud —
    /// this only writes where it was told to.
    static func exportAccounts(to path: String, account: Int? = nil,
                               full: Bool = false) -> BackupOutcome {
        guard CswapLocator.locate() != nil else { return .noEngine }
        var arguments = ["export", path]
        if let account { arguments += ["--account", String(account)] }
        if full { arguments.append("--full") }
        guard let result = run(arguments) else {
            return .failed(detail: "engine did not run")
        }
        guard result.status == 0 else { return .failed(detail: failureDetail(result)) }
        // Report the file's real size rather than trusting exit 0: an
        // export the user can't find is the failure that matters here.
        let size = (try? FileManager.default
            .attributesOfItem(atPath: path)[.size] as? Int) ?? nil
        let bytes = size.map { " (\($0) bytes)" } ?? ""
        return .ok(detail: "exported to \(path)\(bytes)")
    }

    /// `cswap import <path>` — read accounts back.
    ///
    /// `force` overwrites accounts that already exist and so needs the
    /// caller's confirmation. Without it cswap still repairs slots whose
    /// refresh token is dead, which is why plain import is not itself
    /// destructive.
    static func importAccounts(from path: String, force: Bool = false) -> BackupOutcome {
        guard CswapLocator.locate() != nil else { return .noEngine }
        var arguments = ["import", path]
        if force { arguments.append("--force") }
        guard let result = run(arguments) else {
            return .failed(detail: "engine did not run")
        }
        guard result.status == 0 else { return .failed(detail: failureDetail(result)) }
        // Accounts just changed — a cached list would show the old fleet.
        invalidate()
        let text = String(decoding: result.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .ok(detail: text.isEmpty ? "imported from \(path)" : text)
    }

    // MARK: - subprocess

    private struct Result {
        let status: Int32
        let output: Data
        let errors: Data
        /// The subcommand that ran, for a message when neither stream
        /// said anything ("`cswap import` exited 1", not "switch").
        let verb: String
    }

    /// Why a `--json` run failed, in the engine's own words.
    ///
    /// cswap reports failures as JSON on STDOUT and leaves stderr empty
    /// (`{"error":{"type":"ConfigError","message":"No accounts are
    /// managed yet"}}`, exit 1 — verified 2026-09-04). Reading stderr
    /// first therefore threw the reason away and left a bare exit code.
    private static func failureDetail(_ result: Result) -> String {
        if let object = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            // Older/other shapes: a plain string under the same key.
            if let message = object["error"] as? String, !message.isEmpty {
                return message
            }
        }
        // export/import are the other way round: plain text on STDERR,
        // stdout empty, and each line already prefixed "Error: " — which
        // would read twice once the caller labels it.
        let text = String(decoding: result.errors, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let line = text.split(separator: "\n").last.map(String.init) ?? text
            return line.hasPrefix("Error: ")
                ? String(line.dropFirst("Error: ".count))
                : line
        }
        return "`cswap \(result.verb)` exited \(result.status)"
    }

    /// One `cswap …` run under `timeout`. nil only when the process never
    /// started or had to be killed; a non-zero exit still returns, so a
    /// caller can show the engine's own complaint.
    private static func run(_ arguments: [String]) -> Result? {
        guard let binary = CswapLocator.locate() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        guard (try? process.run()) != nil else { return nil }

        // Read before waiting: a full pipe buffer would deadlock the child.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        return Result(status: process.terminationStatus, output: data, errors: errorData,
                      verb: arguments.first ?? "cswap")
    }
}
