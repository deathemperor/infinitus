import Foundation

/// Where every preference lives. `INFINITUS_DEFAULTS_SUITE=<name>` moves
/// the whole store to that suite, so a dev or e2e instance never shares
/// the real app's domain (#690: every unbundled debug binary wrote the
/// one `Infinitus` domain, and a peer's leftover fork_server_port failed
/// another session's e2e). Unset (the bundle, a plain debug run) it is
/// `UserDefaults.standard`, unchanged.
enum AppDefaults {
    static let suite: String? = {
        let s = ProcessInfo.processInfo.environment["INFINITUS_DEFAULTS_SUITE"] ?? ""
        return s.isEmpty ? nil : s
    }()
    static let standard: UserDefaults = suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
}
