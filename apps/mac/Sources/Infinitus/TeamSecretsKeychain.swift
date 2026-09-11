import Foundation
import InfinitusCore

/// The Mac app's `TeamSecrets` (spec §2.1): identity secret + store
/// tokens in the login keychain under `Keychain.teamService`. Reads skip
/// the access-prompt UI (a dev build's ACL prompt must never block the
/// app): no grant = no identity = "pending" until the user re-signs in —
/// `write` refuses to replace an item that exists but couldn't be read,
/// so a denied grant can never be mistaken for "no identity yet" and
/// clobbered with a freshly minted one.
struct KeychainTeamSecrets: TeamSecrets, Sendable {
    enum SecretsError: Error { case writeFailed, unreadableItemExists }

    func read(_ name: String) -> Data? { Keychain.readData(account: name, service: Keychain.teamService) }

    func write(_ name: String, _ data: Data) throws {
        if read(name) == nil, Keychain.exists(account: name, service: Keychain.teamService) {
            throw SecretsError.unreadableItemExists
        }
        guard Keychain.writeData(account: name, value: data, service: Keychain.teamService) else { throw SecretsError.writeFailed }
    }

    func delete(_ name: String) { Keychain.delete(account: name, service: Keychain.teamService) }
}

/// Which secrets store an instance uses: files when `INFINITUS_TEAM_DIR`
/// redirects the team dir (the e2e gate, a second dev instance — CI has
/// no keychain to answer), the keychain otherwise. Returned as a factory
/// so background work builds its own value and captures nothing shared.
enum TeamSecretsFactory {
    static func make(paths: TeamPaths,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> @Sendable () -> TeamSecrets {
        if let dir = environment["INFINITUS_TEAM_DIR"], !dir.isEmpty {
            let secretsDir = paths.secretsDir
            return { FileSecrets(dir: secretsDir) }
        }
        return { KeychainTeamSecrets() }
    }
}
