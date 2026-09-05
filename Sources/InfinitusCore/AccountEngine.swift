import Foundation

// MARK: - Multi-engine seam (#8)
//
// One protocol every account engine speaks — cswap (subprocess),
// CLIProxyAPI (HTTP), later Codex. The popup renders `EngineFleet`s and
// gates its affordances on `capabilities`, never on which engine it is.
// Portable: no AppKit, no Process — an HTTP engine can run on iOS.

/// Whose accounts a fleet holds.
public enum Provider: String, Codable, Sendable, CaseIterable {
    case claude, codex, gemini, kiro, other

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .kiro: return "Kiro"
        case .other: return "Other"
        }
    }
}

/// What an engine can do; the UI hides what it can't.
public struct EngineCapabilities: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let `switch`    = EngineCapabilities(rawValue: 1 << 0)
    public static let rotate      = EngineCapabilities(rawValue: 1 << 1)
    public static let reorder     = EngineCapabilities(rawValue: 1 << 2)
    public static let hold        = EngineCapabilities(rawValue: 1 << 3)
    public static let rename      = EngineCapabilities(rawValue: 1 << 4)
    public static let remove      = EngineCapabilities(rawValue: 1 << 5)
    public static let addCurrent  = EngineCapabilities(rawValue: 1 << 6)
    public static let addToken    = EngineCapabilities(rawValue: 1 << 7)
    public static let addOAuth    = EngineCapabilities(rawValue: 1 << 8)
    public static let autoSwitch  = EngineCapabilities(rawValue: 1 << 9)
    public static let costReport  = EngineCapabilities(rawValue: 1 << 10)
    public static let history     = EngineCapabilities(rawValue: 1 << 11)
    public static let settings    = EngineCapabilities(rawValue: 1 << 12)
    public static let notify      = EngineCapabilities(rawValue: 1 << 13)
    /// Pick-first is the ENGINE's knob (user 2026-09-03: no second policy
    /// app-side): cswap `autoswitch.preferred`, the proxy's priority tier.
    public static let prefer      = EngineCapabilities(rawValue: 1 << 14)
    /// Start an account's 5h clock with one tiny request, without
    /// switching the fleet (#7 igniter). cswap: `cswap run`. The proxy
    /// has no "one request as credential X" verb yet — its cloaking
    /// lives in its executor, so nothing app-side can imitate it safely.
    public static let ignite      = EngineCapabilities(rawValue: 1 << 15)
    /// Write every managed account to one file and read it back — cswap
    /// `export` / `import`. Gated separately from `.remove` because an
    /// export is a CREDENTIAL file and an import overwrites slots: an
    /// engine may manage accounts without being able to hand them over
    /// (the proxy holds keys it never reveals).
    public static let backup      = EngineCapabilities(rawValue: 1 << 16)

    public static let all: EngineCapabilities = [
        .switch, .rotate, .reorder, .hold, .rename, .remove, .addCurrent,
        .addToken, .addOAuth, .autoSwitch, .costReport, .history,
        .settings, .notify, .prefer, .ignite, .backup,
    ]
}

/// One provider's accounts as one engine sees them — the unit the popup
/// renders and the launch cache stores.
public struct EngineFleet: Codable, Sendable {
    public let engineID: String
    public let provider: Provider
    public let accounts: [Account]
    public let activeNumber: Int?
    public let nextCandidate: Int?
    public let nextRecovery: NextRecovery?
    public let liveSessions: LiveSessions?
    /// Verbatim engine bytes when the engine has a native JSON form
    /// (cswap: `list --json`) — the mirror exporter forwards them so the
    /// phone keeps decoding `AccountList` untouched.
    public let raw: Data?

    public init(engineID: String, provider: Provider, accounts: [Account],
                activeNumber: Int? = nil, nextCandidate: Int? = nil,
                nextRecovery: NextRecovery? = nil,
                liveSessions: LiveSessions? = nil, raw: Data? = nil) {
        self.engineID = engineID
        self.provider = provider
        self.accounts = accounts
        self.activeNumber = activeNumber
        self.nextCandidate = nextCandidate
        self.nextRecovery = nextRecovery
        self.liveSessions = liveSessions
        self.raw = raw
    }

    /// Registry key: one FleetState per (engine, provider).
    public var key: String { "\(engineID)/\(provider.rawValue)" }
}

public enum EngineError: Error, Sendable, Equatable {
    case unsupported(String)
    case unreachable(String)
    /// The management API refused us — wrong key, or no key configured.
    case unauthorized
    case remote(status: Int, body: String)
}

extension EngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupported(let what): return "\(what) is not supported by this engine"
        case .unreachable(let why): return "engine unreachable: \(why)"
        case .unauthorized: return "management API refused the key (401/404)"
        case .remote(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "engine answered \(status)" + (trimmed.isEmpty ? "" : ": \(trimmed.prefix(200))")
        }
    }
}

public protocol AccountEngine: Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: EngineCapabilities { get }

    /// One fleet per provider the engine holds (the proxy pools several).
    func snapshot() async throws -> [EngineFleet]
    /// Usage other engines fetched this refresh, by email (see SharedUsage).
    func offerSharedUsage(_ byEmail: [String: SharedUsage]) async

    func switchTo(fleet: Provider, number: Int) async throws
    func rotate(fleet: Provider) async throws
    func reorder(fleet: Provider, _ numbers: [Int]) async throws
    func setHold(fleet: Provider, number: Int, held: Bool) async throws
    /// Star/unstar: the engine lands on starred accounts first when it
    /// switches. Reported back per account as `Account.preferred`.
    func setPreferred(fleet: Provider, number: Int, _ on: Bool) async throws
    /// One tiny request as account n so its 5h window starts now; the
    /// fleet's active account is untouched. Returns when the request is
    /// done (seconds).
    func ignite(fleet: Provider, number: Int) async throws
    func rename(fleet: Provider, number: Int, _ name: String) async throws
    func remove(fleet: Provider, number: Int) async throws
    func addCurrent() async throws
    func addToken(_ token: String) async throws
    /// OAuth add: returns the URL to open; `awaitOAuthAdd` polls to completion.
    func beginOAuthAdd(fleet: Provider) async throws -> URL
    func awaitOAuthAdd() async throws
    func usageReport(days: Int) async throws -> UsageReport
    /// Write every managed account to `path`. The result is a CREDENTIAL
    /// file — treat it like a private key. `full` includes the whole
    /// `~/.claude.json` rather than just the OAuth account.
    func exportAccounts(to path: URL, account: Int?, full: Bool) async throws
    /// Read accounts back from `path`. `force` overwrites accounts that
    /// already exist — destructive, so a caller must confirm it. Without
    /// it the engine may still replace slots whose token is dead (cswap
    /// does), which is the repair case, not a clobber.
    func importAccounts(from path: URL, force: Bool) async throws
}

/// Every action is opt-in: the defaults throw so a UI that ignored
/// `capabilities` fails loudly instead of silently doing nothing.
/// Usage another engine already fetched for an account, keyed by email
/// when offered — so an engine holding the same account does not poll
/// Anthropic's usage endpoint again (two fleets, one 429 budget).
public struct SharedUsage: Sendable {
    public let usage: Usage
    public let at: Date
    public init(usage: Usage, at: Date) {
        self.usage = usage
        self.at = at
    }
}

public extension AccountEngine {
    /// Default: engines that read usage from their own store ignore it.
    func offerSharedUsage(_ byEmail: [String: SharedUsage]) async {}
    func switchTo(fleet: Provider, number: Int) async throws { throw EngineError.unsupported("switch") }
    func rotate(fleet: Provider) async throws { throw EngineError.unsupported("rotate") }
    func reorder(fleet: Provider, _ numbers: [Int]) async throws { throw EngineError.unsupported("reorder") }
    func setHold(fleet: Provider, number: Int, held: Bool) async throws { throw EngineError.unsupported("hold") }
    func setPreferred(fleet: Provider, number: Int, _ on: Bool) async throws { throw EngineError.unsupported("prefer") }
    func ignite(fleet: Provider, number: Int) async throws { throw EngineError.unsupported("ignite") }
    func rename(fleet: Provider, number: Int, _ name: String) async throws { throw EngineError.unsupported("rename") }
    func remove(fleet: Provider, number: Int) async throws { throw EngineError.unsupported("remove") }
    func addCurrent() async throws { throw EngineError.unsupported("addCurrent") }
    func addToken(_ token: String) async throws { throw EngineError.unsupported("addToken") }
    func beginOAuthAdd(fleet: Provider) async throws -> URL { throw EngineError.unsupported("addOAuth") }
    func awaitOAuthAdd() async throws { throw EngineError.unsupported("addOAuth") }
    func usageReport(days: Int) async throws -> UsageReport { throw EngineError.unsupported("costReport") }
    func exportAccounts(to path: URL, account: Int?, full: Bool) async throws {
        throw EngineError.unsupported("backup")
    }
    func importAccounts(from path: URL, force: Bool) async throws {
        throw EngineError.unsupported("backup")
    }
}
