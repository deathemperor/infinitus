import Foundation

/// Where the app keeps its state: `~/Library/Application Support/Infinitus`,
/// or `$INFINITUS_APP_SUPPORT` when set (#506) — a dev or fixture
/// instance then keeps everything it writes (stats caches, births, the
/// owned ledger, events, attention, crash reports, themes) beside its
/// own, never the running bundle's. `tools/e2e.sh` and the fixtures
/// set it next to `INFINITUS_CONTROL_SOCKET` and `CLAUDE_CONFIG_DIR`.
public enum AppSupport {
    public static let environmentKey = "INFINITUS_APP_SUPPORT"

    public static func root(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment[environmentKey], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Infinitus", isDirectory: true)
    }
}
