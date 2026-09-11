import Foundation
import InfinitusCore

/// Where `infinitus-tray serve`/`pair` keep the phone-companion pairing
/// token (#9 parity, Linux side) — the mac equivalent lives in the app's
/// Keychain-backed Sync pane; the tray has no daemon to hold one in
/// memory, so it's a 0600 file instead, generated once on first use.
enum PairingStore {
    static var defaultPath: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? NSHomeDirectory() + "/.config"
        return URL(fileURLWithPath: base).appendingPathComponent("infinitus/pair-token")
    }

    static func loadOrCreate(path: URL = defaultPath) -> String {
        if let existing = try? String(contentsOf: path, encoding: .utf8) {
            let trimmed = MirrorPairing.normalize(existing)
            if !trimmed.isEmpty { return trimmed }
        }
        let token = MirrorPairing.generateToken()
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path.path, contents: Data(token.utf8),
                                       attributes: [.posixPermissions: 0o600])
        return token
    }
}
