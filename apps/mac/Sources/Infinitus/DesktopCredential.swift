import Foundation
import InfinitusCore

/// The bearer session Infinitus desktop mints for `infinitusctl` (#822):
/// pushed over the control socket as `desktop-credential` when the desktop
/// publishes its port, kept in the keychain, handed to the CLI by
/// `desktop-token`. The origin and expiry are not secrets and sit in
/// defaults so `desktop status` answers without touching the keychain.
@MainActor
final class DesktopCredential {
    /// One keychain slot per Mac; a dev or e2e instance (its own defaults
    /// suite, #690) gets its own, so a fixture's token never shadows the
    /// user's and its forget never deletes it.
    static let service: String = {
        let base = "run.infinitus.desktop"
        if let suite = ProcessInfo.processInfo.environment["INFINITUS_DEFAULTS_SUITE"], !suite.isEmpty {
            return base + "." + suite
        }
        return base
    }()
    static let account = "infinitusctl"
    static let originKey = "desktop_origin"
    static let expiresKey = "desktop_expires_at"

    /// Set by AppModel so a store or forget lands in the Activity log (kind only, never the value).
    var log: ((String) -> Void)?
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    var origin: String? { defaults.string(forKey: Self.originKey) }
    var expiresAt: String? { defaults.string(forKey: Self.expiresKey) }
    var stored: Bool { Keychain.exists(account: Self.account, service: Self.service) }
    /// The masked tail for `desktop status`; nil when nothing is stored.
    var masked: String? { Keychain.read(account: Self.account, service: Self.service).map(DesktopRows.masked) }
    /// The token itself — only ever handed to the CLI over the local socket, never printed.
    func token() -> String? { Keychain.read(account: Self.account, service: Self.service) }

    /// Empty forgets. Returns the refusal, nil when stored.
    @discardableResult
    func store(origin: String, expiresAt: String?, token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { forget(); return nil }
        guard let url = URL(string: origin), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
            return "the origin must be an http(s) URL"
        }
        guard Keychain.write(account: Self.account, value: trimmed, service: Self.service) else {
            return "the keychain refused the credential"
        }
        defaults.set(origin, forKey: Self.originKey)
        if let expiresAt, !expiresAt.isEmpty { defaults.set(expiresAt, forKey: Self.expiresKey) } else { defaults.removeObject(forKey: Self.expiresKey) }
        log?("desktop credential stored for \(origin)")
        return nil
    }

    func forget() {
        let had = stored
        Keychain.delete(account: Self.account, service: Self.service)
        defaults.removeObject(forKey: Self.originKey)
        defaults.removeObject(forKey: Self.expiresKey)
        if had { log?("desktop credential forgotten") }
    }
}
